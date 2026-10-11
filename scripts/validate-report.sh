#!/bin/sh
# Check one functional case against section 1 of docs/test-plan.md.
#
# A zero exit from vegaload is not a pass. vegaload run exits 0 when every
# request fails, so the JSON summary must show failed 0 and error_rate 0.
# The summary has no check_rate field. When checks are present, add passes
# and fails and require the ratio to be 1.
#
# --secret is grepped as a fixed string. Do not put the secret on the
# command line of a shared machine if that leaks it; the lab runner already
# has the value in the environment and passes it here.
#
# --diagnose requires the text "no failed requests". A healthy diagnosis
# also prints "failure rate:", and this script does not search for that word.
set -eu

usage() {
	echo "Usage: validate-report.sh --id ID (--json FILE | --diagnose FILE) --exit N [--html FILE] [--log FILE] [--secret VALUE] [--no-report] [--total-min N] [--require-checks]" >&2
	exit 2
}

id=""
json=""
diagnose=""
exit_code=""
html=""
log=""
no_report=0
total_min=1
require_checks=0
secrets=$(mktemp)
outfiles=$(mktemp)
trap 'rm -f "$secrets" "$outfiles"' EXIT INT TERM

while [ $# -gt 0 ]; do
	case "$1" in
	--id)
		id=${2:?}; shift 2 ;;
	--json)
		json=${2:?}; shift 2 ;;
	--diagnose)
		diagnose=${2:?}; shift 2 ;;
	--exit)
		exit_code=${2:?}; shift 2 ;;
	--html)
		html=${2:?}; shift 2 ;;
	--log)
		log=${2:?}; shift 2 ;;
	--secret)
		printf '%s\n' "${2:?}" >> "$secrets"
		shift 2 ;;
	--no-report)
		no_report=1; shift ;;
	--total-min)
		total_min=${2:?}; shift 2 ;;
	--require-checks)
		require_checks=1; shift ;;
	-h|--help)
		usage ;;
	*)
		echo "unknown argument: $1" >&2
		usage ;;
	esac
done

if [ -z "$id" ] || [ -z "$exit_code" ]; then
	usage
fi
if [ -z "$json" ] && [ -z "$diagnose" ]; then
	usage
fi

fail=0
say() {
	printf '%s: %s\n' "$id" "$1"
	fail=1
}

case "$exit_code" in
''|*[!0-9]*)
	say "exit code is not a number"
	;;
*)
	if [ "$exit_code" -ne 0 ]; then
		say "exit code is $exit_code"
	fi
	;;
esac

if [ -n "$json" ]; then
	if [ ! -f "$json" ]; then
		say "JSON summary is missing ($json)"
	else
		python3 - "$json" "$total_min" "$require_checks" "$id" <<'PY' || fail=1
import json, sys
path, total_min, require, ident = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", sys.argv[4]
errors = []
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print("%s: cannot read JSON summary: %s" % (ident, exc))
    sys.exit(1)
if not isinstance(data, dict):
    print("%s: JSON summary is not an object" % ident)
    sys.exit(1)

def num(key):
    if key not in data:
        errors.append("%s: JSON summary has no %s" % (ident, key))
        return None
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        errors.append("%s: %s is not a number" % (ident, key))
        return None
    return value

def as_int(value):
    return isinstance(value, int) and not isinstance(value, bool)

total = num("total")
failed = num("failed")
rate = num("error_rate")
if total is not None and total < total_min:
    errors.append("%s: total %s is below %s" % (ident, total, total_min))
if failed is not None and failed != 0:
    errors.append("%s: failed is %s" % (ident, failed))
if rate is not None and rate != 0:
    errors.append("%s: error_rate is %s" % (ident, rate))

checks = data.get("checks")
if checks is None:
    if require:
        errors.append("%s: JSON summary has no checks" % ident)
elif not isinstance(checks, list):
    errors.append("%s: checks is not a list" % ident)
else:
    passes = fails = 0
    bad = False
    for item in checks:
        if not isinstance(item, dict) or not as_int(item.get("passes")) or not as_int(item.get("fails")):
            errors.append("%s: a check is missing passes or fails" % ident)
            bad = True
            break
        passes += item["passes"]
        fails += item["fails"]
    if not bad:
        if require and passes + fails == 0:
            errors.append("%s: checks are empty" % ident)
        elif fails != 0:
            errors.append("%s: checks failed %s of %s" % (ident, fails, passes + fails))

if data.get("thresholds_passed") is False:
    errors.append("%s: a threshold failed" % ident)
for item in data.get("thresholds") or []:
    if isinstance(item, dict) and item.get("passed") is False:
        name = item.get("name") or item.get("metric") or "threshold"
        errors.append("%s: threshold %s failed" % (ident, name))
        break

for line in errors:
    print(line)
sys.exit(1 if errors else 0)
PY
	fi
fi

if [ -n "$diagnose" ]; then
	if [ ! -f "$diagnose" ]; then
		say "diagnosis is missing ($diagnose)"
	elif ! grep -F -q "no failed requests" "$diagnose"; then
		say "diagnosis does not say no failed requests"
	fi
fi

if [ -n "$json" ] && [ "$no_report" -eq 0 ]; then
	if [ -z "$html" ]; then
		html=${json%.json}.html
	fi
	if [ ! -f "$html" ]; then
		say "HTML report is missing ($html)"
	fi
fi

if [ -s "$secrets" ]; then
	if [ -n "$json" ] && [ -f "$json" ]; then
		printf '%s\n' "$json" >> "$outfiles"
	fi
	if [ -n "$html" ] && [ -f "$html" ]; then
		printf '%s\n' "$html" >> "$outfiles"
	fi
	if [ -n "$log" ] && [ -f "$log" ]; then
		printf '%s\n' "$log" >> "$outfiles"
	fi
	if [ ! -s "$outfiles" ]; then
		say "a secret was given but there is no output to search"
	fi
	while IFS= read -r secret; do
		[ -n "$secret" ] || continue
		while IFS= read -r f; do
			if grep -F -q -- "$secret" "$f"; then
				say "a secret value appears in $f"
			fi
		done < "$outfiles"
	done < "$secrets"
fi

exit "$fail"
