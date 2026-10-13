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
#
# The HTML report is out/<id>.html, next to the JSON summary, unless
# --no-report is set. The runner must pass -report out/<id>.html.
# VegaLoad's default name is vegaload-report-<timestamp>.html.
#
# thresholds is a list of entries with name and passed.
# --require-threshold NAME requires that exact name and passed true.
# --require-thresholds-passed requires thresholds_passed true.
# A threshold that fails the run also makes vegaload exit non-zero, and
# --exit 0 catches that.
set -eu

usage() {
	echo "Usage: validate-report.sh --id ID (--json FILE | --diagnose FILE) --exit N [--html FILE] [--log FILE] [--secret VALUE] [--no-report] [--total-min N] [--require-checks] [--require-protocol NAME] [--require-measure NAME] [--require-data-file NAME:ROWS] [--require-threshold NAME] [--require-thresholds-passed]" >&2
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
protocols=$(mktemp)
measures=$(mktemp)
data_files=$(mktemp)
thresholds=$(mktemp)
thresholds_passed=0
trap 'rm -f "$secrets" "$outfiles" "$protocols" "$measures" "$data_files" "$thresholds"' EXIT INT TERM

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
	--require-protocol)
		printf '%s\n' "${2:?}" >> "$protocols"
		shift 2 ;;
	--require-measure)
		printf '%s\n' "${2:?}" >> "$measures"
		shift 2 ;;
	--require-data-file)
		printf '%s\n' "${2:?}" >> "$data_files"
		shift 2 ;;
	--require-threshold)
		printf '%s\n' "${2:?}" >> "$thresholds"
		shift 2 ;;
	--require-thresholds-passed)
		thresholds_passed=1; shift ;;
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
		python3 - "$json" "$total_min" "$require_checks" "$id" "$protocols" "$measures" "$data_files" "$thresholds" "$thresholds_passed" <<'PY' || fail=1
import json, sys
path, total_min, require, ident = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", sys.argv[4]
protocols_path, measures_path, data_files_path = sys.argv[5], sys.argv[6], sys.argv[7]
thresholds_path, require_passed = sys.argv[8], sys.argv[9] == "1"
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

def read_lines(path):
    with open(path, encoding="utf-8") as fh:
        return [line.strip() for line in fh if line.strip()]

want_protocols = read_lines(protocols_path)
want_measures = read_lines(measures_path)
want_files = read_lines(data_files_path)
want_thresholds = read_lines(thresholds_path)

def protocol_entries():
    value = data.get("protocols")
    if not isinstance(value, list):
        return None
    return value

if want_protocols or want_measures:
    plist = protocol_entries()
    if plist is None:
        errors.append("%s: JSON summary has no protocols" % ident)
        plist = []
    by_name = {}
    found_measures = {}
    for item in plist:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            continue
        by_name[item["name"]] = item
        for measure in item.get("measures") or []:
            if isinstance(measure, dict) and isinstance(measure.get("name"), str):
                found_measures[measure["name"]] = measure.get("count")
    for name in want_protocols:
        item = by_name.get(name)
        if item is None:
            errors.append("%s: protocols has no %s" % (ident, name))
            continue
        total_p = item.get("total")
        if not as_int(total_p) or total_p <= 0:
            errors.append("%s: %s total is %s" % (ident, name, total_p))
    for name in want_measures:
        if name not in found_measures:
            errors.append("%s: measures has no %s" % (ident, name))
            continue
        count = found_measures[name]
        if not as_int(count) or count <= 0:
            errors.append("%s: %s count is %s" % (ident, name, count))

for spec in want_files:
    if spec.count(":") != 1:
        errors.append("%s: data file requirement is not NAME:ROWS" % ident)
        continue
    name, rows_s = spec.split(":", 1)
    if not name or not rows_s.isdigit():
        errors.append("%s: data file requirement is not NAME:ROWS" % ident)
        continue
    want_rows = int(rows_s)
    files = data.get("data_files")
    if not isinstance(files, list):
        errors.append("%s: JSON summary has no data_files" % ident)
        continue
    match = None
    for item in files:
        if isinstance(item, dict) and item.get("name") == name:
            match = item
            break
    if match is None:
        errors.append("%s: data_files has no %s" % (ident, name))
        continue
    got = match.get("rows")
    if not as_int(got) or got != want_rows:
        errors.append("%s: %s has %s rows, want %s" % (ident, name, got, want_rows))

if want_thresholds:
    entries = data.get("thresholds")
    if not isinstance(entries, list):
        errors.append("%s: JSON summary has no thresholds" % ident)
        entries = []
    by_threshold = {}
    for item in entries:
        if isinstance(item, dict) and isinstance(item.get("name"), str):
            by_threshold[item["name"]] = item
    for name in want_thresholds:
        item = by_threshold.get(name)
        if item is None:
            errors.append("%s: thresholds has no %s" % (ident, name))
            continue
        if item.get("passed") is not True:
            errors.append("%s: threshold %s passed is not true" % (ident, name))

if require_passed and data.get("thresholds_passed") is not True:
    if "thresholds_passed" not in data:
        errors.append("%s: JSON summary has no thresholds_passed" % ident)
    else:
        errors.append("%s: thresholds_passed is %s" % (ident, json.dumps(data.get("thresholds_passed"))))

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
