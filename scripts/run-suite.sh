#!/bin/sh
# Run every case in cases/, one after another.
#
# Without --priority, only P0 cases run. --priority all also runs P1.
# Exit 1 when a P0 case fails or is skipped. A P1 failure is printed and
# does not change the exit code.
set -eu

usage() {
	echo "Usage: run-suite.sh --env FILE --out DIR --vegaload PATH [--priority P0|all] [--area NAME] [--case ID]" >&2
	exit 2
}

env_file=""
out_dir=""
vegaload=""
priority=P0
only_area=""
only_case=""

while [ $# -gt 0 ]; do
	case "$1" in
	--env)
		env_file=${2:?}; shift 2 ;;
	--out)
		out_dir=${2:?}; shift 2 ;;
	--vegaload)
		vegaload=${2:?}; shift 2 ;;
	--priority)
		priority=${2:?}; shift 2 ;;
	--area)
		only_area=${2:?}; shift 2 ;;
	--case)
		only_case=${2:?}; shift 2 ;;
	-h|--help)
		usage ;;
	*)
		echo "unknown argument: $1" >&2
		usage ;;
	esac
done

if [ -z "$env_file" ] || [ -z "$out_dir" ] || [ -z "$vegaload" ]; then
	usage
fi
case "$priority" in
P0|all) ;;
*)
	echo "priority must be P0 or all" >&2
	usage ;;
esac

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mkdir -p "$out_dir"
rows=$(mktemp)
list=$(mktemp)
trap 'rm -f "$rows" "$list"' EXIT INT TERM

python3 "$root/scripts/caseparse.py" list --cases "$root/cases" > "$list"

while IFS=$(printf '\t') read -r id pri area path; do
	[ -n "$id" ] || continue
	if [ -n "$only_case" ] && [ "$id" != "$only_case" ]; then
		continue
	fi
	if [ -n "$only_area" ] && [ "$area" != "$only_area" ]; then
		continue
	fi
	if [ -z "$only_case" ] && [ "$priority" = "P0" ] && [ "$pri" != "P0" ]; then
		continue
	fi
	start=$(date +%s)
	rc=0
	line=$("$root/scripts/run-case.sh" --case "$path" --env "$env_file" --out "$out_dir" --vegaload "$vegaload") || rc=$?
	end=$(date +%s)
	secs=$((end - start))
	printf '%s\n' "$line"
	case "$line" in
	PASS\ *)
		result=PASS
		;;
	SKIP\ *)
		result=SKIP
		;;
	*)
		result=FAIL
		;;
	esac
	exit_code=$rc
	if [ -f "$out_dir/$id.exit" ]; then
		exit_code=$(cat "$out_dir/$id.exit")
	fi
	python3 -c 'import json,sys; json.dump({"id":sys.argv[1],"priority":sys.argv[2],"area":sys.argv[3],"result":sys.argv[4],"exit":sys.argv[5],"seconds":sys.argv[6],"line":sys.argv[7]}, sys.stdout); print()' \
		"$id" "$pri" "$area" "$result" "$exit_code" "$secs" "$line" >> "$rows"
done < "$list"

python3 - "$rows" "$out_dir/results.tsv" "$out_dir/suite.junit.xml" <<'PY'
import json, sys
rows_path, tsv_path, junit_path = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
with open(rows_path, encoding="utf-8") as fh:
    for line in fh:
        if line.strip():
            rows.append(json.loads(line))
passed = sum(1 for row in rows if row["result"] == "PASS")
failed = sum(1 for row in rows if row["result"] == "FAIL")
skipped = sum(1 for row in rows if row["result"] == "SKIP")
p0_bad = any(row["priority"] == "P0" and row["result"] != "PASS" for row in rows)

def xml(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))

with open(tsv_path, "w", encoding="utf-8") as fh:
    fh.write("id\tpriority\tresult\texit\tseconds\n")
    for row in rows:
        fh.write("%s\t%s\t%s\t%s\t%s\n" % (
            row["id"], row["priority"], row["result"], row["exit"], row["seconds"]))
with open(junit_path, "w", encoding="utf-8") as fh:
    fh.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    fh.write('<testsuite name="vegaload" tests="%d" failures="%d" skipped="%d">\n' % (
        len(rows), failed, skipped))
    for row in rows:
        fh.write('  <testcase name="%s" classname="%s" time="%s">' % (
            xml(row["id"]), xml(row["area"]), xml(str(row["seconds"]))))
        if row["result"] == "FAIL":
            fh.write('<failure message="%s"></failure>' % xml(row["line"]))
        elif row["result"] == "SKIP":
            fh.write('<skipped message="%s"></skipped>' % xml(row["line"]))
        fh.write('</testcase>\n')
    fh.write('</testsuite>\n')
print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
sys.exit(1 if p0_bad else 0)
PY
