#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD
suite=$root/scripts/run-suite.sh
fake=$root/scripts/testdata/fake-vegaload
pass=0
fail=0

expect_suite() {
	name=$1
	want_code=$2
	want_text=$3
	shift 3
	set +e
	got=$("$@" 2>/tmp/vl-run-suite.err)
	code=$?
	set -e
	if [ "$code" -eq "$want_code" ] && printf '%s\n' "$got" | grep -F -q -- "$want_text"; then
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		echo "want code $want_code and: $want_text"
		echo "got code $code"
		printf '%s\n' "$got"
		cat /tmp/vl-run-suite.err
		fail=$((fail + 1))
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
cd "$tmp"

cat > env <<'EOF'
FTP_USER=labuser
FTP_PASSWORD=secret-ftp
SFTP_USER=labuser
SFTP_PASSWORD=secret-sftp
SFTP_HOST_KEY=SHA256:not-a-real-key
PG_USER=labuser
PGPASSWORD=secret-pg
EOF

expect_suite p0 0 "6 passed, 0 failed, 0 skipped" \
	"$suite" --env "$tmp/env" --out "$tmp/p0" --vegaload "$fake"

python3 - "$tmp/p0/results.tsv" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
if lines[0] != "id\tpriority\tresult\texit\tseconds":
    sys.exit("bad header: " + lines[0])
ids = [line.split("\t")[0] for line in lines[1:]]
want = ["HP-PROTO-01", "HP-PROTO-02", "HP-FTP-01", "HP-SFTP-01", "HP-DATA-02", "HP-THR-02"]
if ids != want:
    sys.exit("order %s" % ids)
# PROTO-02 is a usage error and exits 2.
row = lines[2].split("\t")
if row[0] != "HP-PROTO-02" or row[2] != "PASS" or row[3] != "2":
    sys.exit("proto-02 row %s" % row)
PY
pass=$((pass + 1))

if ! grep -F -q 'testcase name="HP-FTP-01"' "$tmp/p0/suite.junit.xml"; then
	echo "FAIL junit"
	fail=$((fail + 1))
else
	pass=$((pass + 1))
fi

if grep -R -F -q -- "secret-ftp" "$tmp/p0"; then
	echo "FAIL secret leaked"
	fail=$((fail + 1))
else
	pass=$((pass + 1))
fi

expect_suite all-priority 0 "6 passed, 0 failed, 2 skipped" \
	"$suite" --env "$tmp/env" --out "$tmp/all" --vegaload "$fake" --priority all

if ! grep -F -q "needs out/HP-HTTP-01.json" "$tmp/all/suite.junit.xml"; then
	echo "FAIL skip message"
	fail=$((fail + 1))
else
	pass=$((pass + 1))
fi

expect_suite p0-fail 1 "2 passed, 4 failed, 0 skipped" \
	env VEGALOAD_FAKE_EXIT=1 \
	"$suite" --env "$tmp/env" --out "$tmp/bad" --vegaload "$fake"

mkdir -p "$tmp/p1/out"
cp "$root/scripts/testdata/all-failed.json" "$tmp/p1/out/HP-HTTP-01.json"
printf '%s\n' "<html></html>" > "$tmp/p1/out/HP-HTTP-01.html"
cd "$tmp/p1"
expect_suite p1-fail 0 "0 passed, 1 failed, 0 skipped" \
	"$suite" --env "$tmp/env" --out "$tmp/p1/out" --vegaload "$fake" --case HP-RES-01

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
