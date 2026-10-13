#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
runner=scripts/run-case.sh
fake=$PWD/scripts/testdata/fake-vegaload
pass=0
fail=0

expect_line() {
	name=$1
	want_code=$2
	want_text=$3
	shift 3
	set +e
	got=$("$@" 2>/tmp/vl-run-case.err)
	code=$?
	set -e
	if [ "$code" -eq "$want_code" ] && printf '%s\n' "$got" | grep -F -q -- "$want_text"; then
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		echo "want code $want_code and: $want_text"
		echo "got code $code"
		printf '%s\n' "$got"
		cat /tmp/vl-run-case.err
		fail=$((fail + 1))
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

cat > "$tmp/env" <<'EOF'
SAMPLE_HTTP=127.0.0.1:8080
FTP_USER=labuser
FTP_PASSWORD=secret-ftp
EOF

cat > "$tmp/HP-OK.yaml" <<'EOF'
id: HP-OK
area: http
priority: P0
doc: "a passing run"
argv:
  - run
  - -target
  - http://${SAMPLE_HTTP}/health
  - -protocol
  - http1
  - -vus
  - "5"
  - -duration
  - 10s
expect:
  exit: 0
  total_min: 1
  failed: 0
EOF

cat > "$tmp/HP-MISS.yaml" <<'EOF'
id: HP-MISS
area: http
priority: P0
doc: "missing env"
argv:
  - run
  - -target
  - ${NOT_A_VARIABLE}
expect:
  exit: 0
EOF

printf '%s\n' 'this is not: [yaml' > "$tmp/bad.yaml"

cat > "$tmp/HP-SETUP.yaml" <<'EOF'
id: HP-SETUP
area: http
priority: P0
doc: "setup fails"
setup:
  - run
  - FAILSETUP
argv:
  - run
  - -target
  - http://127.0.0.1/health
expect:
  exit: 0
EOF

expect_line pass 0 "PASS HP-OK" \
	"$runner" --case "$tmp/HP-OK.yaml" --env "$tmp/env" --out "$tmp/out-ok" --vegaload "$fake"

expect_line validator 1 "FAIL HP-OK: failed is 19506" \
	env VEGALOAD_FAKE_SUMMARY="$PWD/scripts/testdata/all-failed.json" \
	"$runner" --case "$tmp/HP-OK.yaml" --env "$tmp/env" --out "$tmp/out-bad" --vegaload "$fake"

expect_line missing-env 2 "HP-MISS: missing variable NOT_A_VARIABLE" \
	"$runner" --case "$tmp/HP-MISS.yaml" --env "$tmp/env" --out "$tmp/out-miss" --vegaload "$fake"

expect_line bad-yaml 2 "bad YAML" \
	"$runner" --case "$tmp/bad.yaml" --env "$tmp/env" --out "$tmp/out-yaml" --vegaload "$fake"

expect_line setup 1 "FAIL HP-SETUP: setup exited 7" \
	"$runner" --case "$tmp/HP-SETUP.yaml" --env "$tmp/env" --out "$tmp/out-setup" --vegaload "$fake"

expect_line wrong-exit 1 "FAIL HP-OK: exit code is 1" \
	env VEGALOAD_FAKE_EXIT=1 \
	"$runner" --case "$tmp/HP-OK.yaml" --env "$tmp/env" --out "$tmp/out-exit" --vegaload "$fake"

expect_line proto-list 0 "PASS HP-PROTO-01" \
	"$runner" --case cases/HP-PROTO-01.yaml --env "$tmp/env" --out "$tmp/out-proto" --vegaload "$fake"

expect_line proto-stderr 0 "PASS HP-PROTO-02" \
	"$runner" --case cases/HP-PROTO-02.yaml --env "$tmp/env" --out "$tmp/out-proto2" --vegaload "$fake"

if [ -s "$tmp/out-proto2/HP-PROTO-02.stdout" ]; then
	echo "FAIL proto-stderr stdout should be empty"
	fail=$((fail + 1))
elif ! grep -F -q 'unknown -protocol "bogus"' "$tmp/out-proto2/HP-PROTO-02.log"; then
	echo "FAIL proto-stderr log is missing the protocol list"
	fail=$((fail + 1))
else
	pass=$((pass + 1))
fi

expect_line ftp 0 "PASS HP-FTP-01" \
	"$runner" --case cases/HP-FTP-01.yaml --env "$tmp/env" --out "$tmp/out-ftp" --vegaload "$fake"

cat > "$tmp/HP-THR.yaml" <<'EOF'
id: HP-THR-CHK
area: reports
priority: P0
doc: "a threshold is in the summary"
argv:
  - run
  - -target
  - http://127.0.0.1/health
  - -protocol
  - http1
expect:
  exit: 0
  threshold: 'p95{protocol="http1"} < 5s'
  thresholds_passed: true
EOF

expect_line threshold-pass 0 "PASS HP-THR-CHK" \
	env VEGALOAD_FAKE_SUMMARY="$PWD/scripts/testdata/threshold-ok.json" \
	"$runner" --case "$tmp/HP-THR.yaml" --env "$tmp/env" --out "$tmp/out-thr" --vegaload "$fake"

expect_line threshold-miss 1 'FAIL HP-THR-CHK: thresholds has no p95{protocol="http1"} < 5s' \
	env VEGALOAD_FAKE_SUMMARY="$PWD/scripts/testdata/threshold-other.json" \
	"$runner" --case "$tmp/HP-THR.yaml" --env "$tmp/env" --out "$tmp/out-thr-miss" --vegaload "$fake"

python3 - <<'PY'
import glob, sys
sys.path.insert(0, "scripts")
import caseparse
for path in sorted(glob.glob("cases/*.yaml")):
    caseparse.load_case(path)
case = caseparse.load_case("cases/HP-THR-02.yaml")
if case["expect"]["threshold"] != 'p95{protocol="http1"} < 5s':
    sys.exit("threshold did not round-trip")
case = caseparse.load_case("cases/HP-DATA-02.yaml")
if "select $1::int as id" not in case["argv"]:
    sys.exit("body did not round-trip")
PY
pass=$((pass + 1))

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
