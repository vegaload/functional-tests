#!/bin/sh
# Fixtures in testdata/ were produced by the released vegaload 0.7.0 binary.
set -eu
cd "$(dirname "$0")/.."
v=scripts/validate-report.sh
pass=0
fail=0

expect_ok() {
	name=$1
	shift
	if "$v" "$@" >/tmp/vl-validate.out 2>/tmp/vl-validate.err; then
		pass=$((pass + 1))
	else
		echo "FAIL $name (expected pass)"
		cat /tmp/vl-validate.out /tmp/vl-validate.err
		fail=$((fail + 1))
	fi
}

expect_bad() {
	name=$1
	want=$2
	shift 2
	if "$v" "$@" >/tmp/vl-validate.out 2>/tmp/vl-validate.err; then
		echo "FAIL $name (expected a failure)"
		fail=$((fail + 1))
		return
	fi
	if grep -F -q -- "$want" /tmp/vl-validate.out; then
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		echo "want: $want"
		cat /tmp/vl-validate.out /tmp/vl-validate.err
		fail=$((fail + 1))
	fi
}

expect_ok healthy \
	--id HP-HTTP-01 --json scripts/testdata/healthy.json --exit 0 --no-report --require-checks

expect_bad all-failed "failed is 19506" \
	--id HP-HTTP-01 --json scripts/testdata/all-failed.json --exit 0 --no-report

expect_bad bad-exit "exit code is 1" \
	--id HP-HTTP-01 --json scripts/testdata/healthy.json --exit 1 --no-report

expect_ok diagnose \
	--id HP-DIAG-01 --diagnose scripts/testdata/healthy-diagnose.txt --exit 0 --no-report

printf 'failure rate:    0.0%%\n' > /tmp/vl-validate-diag.txt
expect_bad diagnose-word "does not say no failed requests" \
	--id HP-DIAG-01 --diagnose /tmp/vl-validate-diag.txt --exit 0 --no-report

python3 - <<'PY'
import json
d = json.load(open("scripts/testdata/healthy.json"))
d["note"] = "s3cr3t-token-value"
json.dump(d, open("/tmp/vl-validate-secret.json", "w"))
PY
expect_bad secret "a secret value appears in /tmp/vl-validate-secret.json" \
	--id HP-PG-01 --json /tmp/vl-validate-secret.json --exit 0 --no-report --secret s3cr3t-token-value

expect_ok secret-absent \
	--id HP-PG-01 --json scripts/testdata/healthy.json --exit 0 --no-report --secret s3cr3t-token-value

python3 - <<'PY'
import json
d = json.load(open("scripts/testdata/healthy.json"))
d["checks"] = [{"name": "status is 200", "passes": 1, "fails": 1}]
json.dump(d, open("/tmp/vl-validate-checks.json", "w"))
d = json.load(open("scripts/testdata/all-failed.json"))
d["failed"] = 0
d["error_rate"] = 0
d.pop("checks", None)
json.dump(d, open("/tmp/vl-validate-nochecks.json", "w"))
PY

expect_bad checks "checks failed 1 of 2" \
	--id HP-SCN-01 --json /tmp/vl-validate-checks.json --exit 0 --no-report

expect_ok no-checks-skipped \
	--id HP-HTTP-01 --json /tmp/vl-validate-nochecks.json --exit 0 --no-report

expect_bad require-checks "has no checks" \
	--id HP-SCN-01 --json /tmp/vl-validate-nochecks.json --exit 0 --no-report --require-checks

# A failed threshold is a non-zero exit. The summary has no threshold fields.
expect_bad threshold "exit code is 3" \
	--id HP-THR-01 --json scripts/testdata/healthy.json --exit 3 --no-report

expect_bad html "HTML report is missing" \
	--id HP-HTTP-01 --json scripts/testdata/healthy.json --exit 0

expect_bad total "total 5636 is below 10000" \
	--id HP-SHAPE-03 --json scripts/testdata/healthy.json --exit 0 --no-report --total-min 10000

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
