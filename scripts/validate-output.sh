#!/bin/sh
# Check a command that does not write a run summary.
#
# --exit is the command's exit code. Any number is allowed, including 2.
# --contains is a fixed string that must appear in --stdout. Repeat it for
# each string. --protocols-json requires one JSON object with schema_version
# 1 and the 14 protocol names, in order.
#
# A failure is one line that starts with the case id.
set -eu

usage() {
	echo "Usage: validate-output.sh --id ID --exit N --stdout FILE [--contains TEXT]... [--protocols-json]" >&2
	exit 2
}

id=""
exit_code=""
stdout=""
protocols_json=0
contains=$(mktemp)
trap 'rm -f "$contains"' EXIT INT TERM

while [ $# -gt 0 ]; do
	case "$1" in
	--id)
		id=${2:?}; shift 2 ;;
	--exit)
		exit_code=${2:?}; shift 2 ;;
	--stdout)
		stdout=${2:?}; shift 2 ;;
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

if [ -z "$id" ] || [ -z "$exit_code" ] || [ -z "$stdout" ]; then
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
esac

if [ ! -f "$stdout" ]; then
	say "stdout is missing ($stdout)"
else
	while IFS= read -r text; do
		[ -n "$text" ] || continue
		if ! grep -F -q -- "$text" "$stdout"; then
			say "stdout does not contain $text"
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
