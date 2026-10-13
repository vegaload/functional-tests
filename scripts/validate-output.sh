#!/bin/sh
# Check a command that does not write a run summary.
#
# --exit is the command's exit code. --want-exit is the code the case
# expects. They must be the same number.
# --contains is a fixed string that must appear in --stdout. Repeat it for
# each string. When --log is set, --contains searches that file instead.
# The runner writes stdout and stderr together there.
# --protocols-json still reads --stdout, which must stay one JSON object
# with schema_version 1 and the 14 protocol names, in order.
#
# A failure is one line that starts with the case id.
set -eu

usage() {
	echo "Usage: validate-output.sh --id ID --exit N --want-exit N --stdout FILE [--log FILE] [--contains TEXT]... [--protocols-json]" >&2
	exit 2
}

id=""
exit_code=""
want_exit=""
stdout=""
log=""
protocols_json=0
contains=$(mktemp)
trap 'rm -f "$contains"' EXIT INT TERM

while [ $# -gt 0 ]; do
	case "$1" in
	--id)
		id=${2:?}; shift 2 ;;
	--exit)
		exit_code=${2:?}; shift 2 ;;
	--want-exit)
		want_exit=${2:?}; shift 2 ;;
	--stdout)
		stdout=${2:?}; shift 2 ;;
	--log)
		log=${2:?}; shift 2 ;;
	--contains)
		printf '%s\n' "${2:?}" >> "$contains"
		shift 2 ;;
	--protocols-json)
		protocols_json=1; shift ;;
	-h|--help)
		usage ;;
	*)
		echo "unknown argument: $1" >&2
		usage ;;
	esac
done

if [ -z "$id" ] || [ -z "$exit_code" ] || [ -z "$want_exit" ] || [ -z "$stdout" ]; then
	usage
fi

fail=0
say() {
	printf '%s: %s\n' "$id" "$1"
	fail=1
}

exit_ok=0
want_ok=0
case "$exit_code" in
''|*[!0-9]*)
	say "exit code is not a number"
	;;
*)
	exit_ok=1
	;;
esac
case "$want_exit" in
''|*[!0-9]*)
	say "want exit code is not a number"
	;;
*)
	want_ok=1
	;;
esac
if [ "$exit_ok" -eq 1 ] && [ "$want_ok" -eq 1 ] && [ "$exit_code" -ne "$want_exit" ]; then
	say "exit code is $exit_code, want $want_exit"
fi

if [ ! -f "$stdout" ]; then
	say "stdout is missing ($stdout)"
elif [ -n "$log" ] && [ ! -f "$log" ]; then
	say "log is missing ($log)"
else
	search=$stdout
	where=stdout
	if [ -n "$log" ]; then
		search=$log
		where=log
	fi
	while IFS= read -r text; do
		[ -n "$text" ] || continue
		if ! grep -F -q -- "$text" "$search"; then
			say "$where does not contain $text"
		fi
	done < "$contains"
	if [ "$protocols_json" -eq 1 ]; then
		python3 - "$stdout" "$id" <<'PY' || fail=1
import json, sys
path, ident = sys.argv[1], sys.argv[2]
want = ["http1", "http2", "grpc", "websocket", "mqtt", "kafka", "postgres", "mysql", "redis", "rabbitmq", "ftp", "sftp", "tcp", "udp"]
try:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    obj, end = json.JSONDecoder().raw_decode(text)
    if text[end:].strip():
        raise ValueError("extra data after the JSON object")
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print("%s: stdout is not one JSON object: %s" % (ident, exc))
    sys.exit(1)
if not isinstance(obj, dict):
    print("%s: stdout is not one JSON object" % ident)
    sys.exit(1)
if obj.get("schema_version") != 1:
    print("%s: schema_version is %s" % (ident, obj.get("schema_version")))
    sys.exit(1)
names = []
protocols = obj.get("protocols")
if isinstance(protocols, list):
    for item in protocols:
        if isinstance(item, dict) and isinstance(item.get("name"), str):
            names.append(item["name"])
if names != want:
    print("%s: protocols are %s" % (ident, " ".join(names)))
    sys.exit(1)
PY
	fi
fi

exit "$fail"
