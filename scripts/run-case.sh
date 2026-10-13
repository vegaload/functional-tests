#!/bin/sh
# Run one case file and print one line.
#
# Exit 0 on pass, 1 on fail, 2 on a bad case file.
set -eu

usage() {
	echo "Usage: run-case.sh --case FILE --env FILE --out DIR --vegaload PATH" >&2
	exit 2
}

case_file=""
env_file=""
out_dir=""
vegaload=""

while [ $# -gt 0 ]; do
	case "$1" in
	--case)
		case_file=${2:?}; shift 2 ;;
	--env)
		env_file=${2:?}; shift 2 ;;
	--out)
		out_dir=${2:?}; shift 2 ;;
	--vegaload)
		vegaload=${2:?}; shift 2 ;;
	-h|--help)
		usage ;;
	*)
		echo "unknown argument: $1" >&2
		usage ;;
	esac
done

if [ -z "$case_file" ] || [ -z "$env_file" ] || [ -z "$out_dir" ] || [ -z "$vegaload" ]; then
	usage
fi

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
parser=$root/scripts/caseparse.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

if ! python3 "$parser" plan --case "$case_file" --env "$env_file" --out "$out_dir" --work "$work"; then
	exit 2
fi

meta=$work/meta.json
field() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$meta" "$1"
}

id=$(field id)
mode=$(field mode)
want_exit=$(field want_exit)
json_path=$(field json_path)
stdout_path=$(field stdout_path)
log_path=$(field log_path)
exit_path=$(field exit_path)
no_report=$(field no_report)
protocols_json=$(field protocols_json)
has_setup=$(field has_setup)
has_argv=$(field has_argv)
total_min=$(field total_min)
require_checks=$(field require_checks)
data_file=$(field data_file)
secret_env=$(field secret_env)

mkdir -p "$out_dir"
# shellcheck disable=SC1091
. "$work/export.sh"

while IFS= read -r need; do
	[ -n "$need" ] || continue
	if [ ! -f "$need" ]; then
		printf 'SKIP %s: needs %s\n' "$id" "$need"
		exit 1
	fi
done < "$work/needs"

run_vegaload() {
	# Arguments are already in "$@".
	out=$1
	err=$2
	shift 2
	code=0
	"$vegaload" "$@" >"$out" 2>"$err" || code=$?
	printf '%s\n' "$code"
}

if [ "$has_setup" = "True" ]; then
	# shellcheck disable=SC1091
	. "$work/setup.sh"
	setup_code=$(run_vegaload "$work/setup.out" "$work/setup.err" "$@")
	if [ "$setup_code" -ne 0 ]; then
		printf 'FAIL %s: setup exited %s\n' "$id" "$setup_code"
		exit 1
	fi
fi

code=0
if [ "$has_argv" = "True" ]; then
	# shellcheck disable=SC1091
	. "$work/argv.sh"
	code=$(run_vegaload "$stdout_path" "$work/cmd.err" "$@")
	cat "$stdout_path" "$work/cmd.err" > "$log_path"
	printf '%s\n' "$code" > "$exit_path"
fi

if [ "$mode" = "output" ]; then
	set -- "$root/scripts/validate-output.sh" \
		--id "$id" \
		--exit "$code" \
		--want-exit "$want_exit" \
		--stdout "$stdout_path"
	if [ "$protocols_json" = "True" ]; then
		set -- "$@" --protocols-json
	fi
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		text=$(printf '%s\n' "$line" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin))')
		set -- "$@" --contains "$text"
	done < "$work/contains"
	if "$@" >"$work/judge.out" 2>"$work/judge.err"; then
		printf 'PASS %s\n' "$id"
		exit 0
	fi
else
	set -- "$root/scripts/validate-report.sh" \
		--id "$id" \
		--json "$json_path" \
		--exit "$code" \
		--log "$log_path"
	if [ "$no_report" = "True" ]; then
		set -- "$@" --no-report
	fi
	if [ -n "$total_min" ]; then
		set -- "$@" --total-min "$total_min"
	fi
	if [ "$require_checks" = "True" ]; then
		set -- "$@" --require-checks
	fi
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		set -- "$@" --require-protocol "$name"
	done < "$work/protocols"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		set -- "$@" --require-measure "$name"
	done < "$work/measures"
	if [ -n "$data_file" ]; then
		set -- "$@" --require-data-file "$data_file"
	fi
	if [ -n "$secret_env" ]; then
		eval "secret_value=\${$secret_env}"
		set -- "$@" --secret "$secret_value"
	fi
	if "$@" >"$work/judge.out" 2>"$work/judge.err"; then
		printf 'PASS %s\n' "$id"
		exit 0
	fi
fi

msg=$(python3 -c '
import sys
lines = [line.strip() for line in sys.stdin if line.strip()]
ident = sys.argv[1] + ": "
cleaned = []
for line in lines:
    if line.startswith(ident):
        line = line[len(ident):]
    cleaned.append(line)
print("; ".join(cleaned))
' "$id" < "$work/judge.out")
printf 'FAIL %s: %s\n' "$id" "$msg"
exit 1
