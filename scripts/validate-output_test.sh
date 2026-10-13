#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
v=scripts/validate-output.sh
pass=0
fail=0

expect_ok() {
	name=$1
	shift
	if "$v" "$@" >/tmp/vl-validate-out.out 2>/tmp/vl-validate-out.err; then
		pass=$((pass + 1))
	else
		echo "FAIL $name (expected pass)"
		cat /tmp/vl-validate-out.out /tmp/vl-validate-out.err
		fail=$((fail + 1))
	fi
}

expect_bad() {
	name=$1
	want=$2
	shift 2
	if "$v" "$@" >/tmp/vl-validate-out.out 2>/tmp/vl-validate-out.err; then
		echo "FAIL $name (expected a failure)"
		fail=$((fail + 1))
		return
	fi
	if grep -F -q -- "$want" /tmp/vl-validate-out.out; then
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		echo "want: $want"
		cat /tmp/vl-validate-out.out /tmp/vl-validate-out.err
		fail=$((fail + 1))
	fi
}

expect_ok exit-two \
	--id HP-PROTO-02 --exit 2 --want-exit 2 --stdout scripts/testdata/bogus-protocol.txt \
	--contains 'unknown -protocol "bogus"' --contains 'Supported protocols:'

expect_bad exit-word "exit code is not a number" \
	--id HP-PROTO-02 --exit no --want-exit 2 --stdout scripts/testdata/bogus-protocol.txt

expect_bad exit-mismatch "exit code is 1, want 2" \
	--id HP-PROTO-02 --exit 1 --want-exit 2 --stdout scripts/testdata/bogus-protocol.txt

expect_bad missing-text "stdout does not contain Supported protocols:" \
	--id HP-PROTO-02 --exit 2 --want-exit 2 --stdout scripts/testdata/protocols.json \
	--contains 'Supported protocols:'

: > /tmp/vl-empty-stdout.txt

expect_ok log-contains \
	--id HP-PROTO-02 --exit 2 --want-exit 2 --stdout /tmp/vl-empty-stdout.txt \
	--log scripts/testdata/bogus-protocol.txt \
	--contains 'unknown -protocol "bogus"' --contains 'Supported protocols:'

expect_bad log-missing "log does not contain Supported protocols:" \
	--id HP-PROTO-02 --exit 2 --want-exit 2 --stdout /tmp/vl-empty-stdout.txt \
	--log scripts/testdata/protocols.json \
	--contains 'Supported protocols:'

expect_ok protocols-json-ignores-log \
	--id HP-PROTO-01 --exit 0 --want-exit 0 \
	--stdout scripts/testdata/protocols.json \
	--log scripts/testdata/bogus-protocol.txt \
	--protocols-json

expect_ok protocols-json \
	--id HP-PROTO-01 --exit 0 --want-exit 0 --stdout scripts/testdata/protocols.json --protocols-json

expect_bad proto-exit "exit code is 1, want 0" \
	--id HP-PROTO-01 --exit 1 --want-exit 0 --stdout scripts/testdata/protocols.json --protocols-json

expect_bad protocols-json-version "schema_version is 2" \
	--id HP-PROTO-01 --exit 0 --want-exit 0 --stdout scripts/testdata/protocols-bad.json --protocols-json

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
