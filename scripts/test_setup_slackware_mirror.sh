#!/bin/bash
# Τεστ harness για το setup_slackware_mirror_JBs.sh με mock περιβάλλον.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/setup_slackware_mirror_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/stub.log"
MF="$TMP/mirrors"
mkdir -p "$BIN"

pass=0; fail=0
check() {
	if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
	else fail=$((fail+1)); echo "FAIL - $1"; fi
}

# stubs
cat >"$BIN/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
cat >"$BIN/slackpkg" <<'EOF'
#!/bin/bash
echo "slackpkg $*" >>"$STUB_LOG"
exit "${STUB_SLPKG_RC:-0}"
EOF
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >>"$STUB_LOG"
EOF
chmod +x "$BIN"/*

setup() { # επαναφορά stock mirrors file
	cat >"$MF" <<'MEOF'
# /etc/slackpkg/mirrors
#
# Each line below is a mirror of the Slackware packages tree.
#
#http://mirrors.slackware.com/slackware64-15.0/
#https://ftp.cc.uoc.gr/mirrors/linux/slackware/slackware64-15.0/
http://mirror.example.gr/slackware64-15.0/
MEOF
	: >"$LOG"
}

run() { # $@ ; STDIN από τον caller
	MIRRORS_FILE="$MF" PATH="$BIN:$PATH" STUB_LOG="$LOG" \
	STUB_UID="${STUB_UID:-0}" STUB_SLPKG_RC="${STUB_SLPKG_RC:-0}" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: ερώτηση s -> stable uoc =="
setup
out=$(printf 's\ny\n' | run 2>&1); rc=$?
check "exit 0" "$rc"
grep -qxF "https://ftp.cc.uoc.gr/mirrors/linux/slackware/slackware64-15.0/" "$MF"
check "γράφτηκε uoc stable URL" $?
grep -q "^slackpkg -batch=on update$" "$LOG"
check "τράπηκε slackpkg update" $?
ls "$MF".bak.* >/dev/null 2>&1
check "backup δημιουργήθηκε" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: ερώτηση c -> current =="
setup
printf 'c\ny\n' | run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qxF "https://ftp.cc.uoc.gr/mirrors/linux/slackware/slackware64-current/" "$MF"
check "γράφτηκε uoc current URL" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: --current χωρίς ερώτηση =="
setup
out=$(run --current -y </dev/null 2>&1); rc=$?
check "exit 0 χωρίς stdin" "$rc"
grep -qxF "https://ftp.cc.uoc.gr/mirrors/linux/slackware/slackware64-current/" "$MF"
check "current URL χωρίς interactivity" $?

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: dry-run χωρίς αλλαγές =="
setup
cp "$MF" "$TMP/mf.orig"
out=$(run --stable -n </dev/null 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "slackware64-15.0"
check "δείχνει stable URL στο plan" $?
diff -q "$MF" "$TMP/mf.orig" >/dev/null
check "το mirrors file αμετάβλητο" $?
grep -q "slackpkg" "$LOG"; [ $? -ne 0 ]; check "κανένα slackpkg σε dry-run" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: το παλιό ενεργό mirror σχολιάζεται =="
setup
run --stable -y </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^#http://mirror.example.gr/slackware64-15.0/" "$MF"
check "παλιό ενεργό mirror σχολιάστηκε" $?
active=$(grep -cE '^(https?|ftp|rsync)://' "$MF")
[ "$active" = "1" ]; check "μία και μόνο ενεργή γραμμή" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: --mirror ntua =="
setup
run --stable --mirror ntua -y </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qxF "http://ftp.ntua.gr/pub/linux/slackware/slackware64-15.0/" "$MF"
check "γράφτηκε ntua URL" $?

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: --arch i586 =="
setup
run --stable --arch i586 -y </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qxF "https://ftp.cc.uoc.gr/mirrors/linux/slackware/slackware-15.0/" "$MF"
check "i586 χρησιμοποιεί slackware-15.0 path" $?

# ---------------------------------------------------------------- TEST 8 -----
echo "== TEST 8: αποτυχία slackpkg update -> exit 1 =="
setup
STUB_SLPKG_RC=1 run --stable -y </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 όταν αποτυχάνει το slackpkg update" $?

# ---------------------------------------------------------------- TEST 9 -----
echo "== TEST 9: non-root -> άρνηση =="
setup
cp "$MF" "$TMP/mf.orig"
STUB_UID=1000 run --stable </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 ως non-root" $?
diff -q "$MF" "$TMP/mf.orig" >/dev/null
check "το mirrors file αμετάβλητο ως non-root" $?

# ---------------------------------------------------------------- TEST 10 ----
echo "== TEST 10: λείπει το mirrors file -> ξεκάθαρο σφάλμα =="
setup
rm -f "$MF"
run --stable </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 χωρίς mirrors file" $?

# ---------------------------------------------------------------- TEST 11 ----
echo "== TEST 11: ερώτηση επιβεβαίωσης n -> ακύρωση =="
setup
cp "$MF" "$TMP/mf.orig"
printf 's\nn\n' | run >/dev/null 2>&1; rc=$?
check "exit 0 σε ακύρωση" "$rc"
diff -q "$MF" "$TMP/mf.orig" >/dev/null
check "το mirrors file αμετάβλητο μετά το n" $?

# ---------------------------------------------------------------- TEST 12 ----
echo "== TEST 12: δεύτερη εκτέλεση χωρίς διπλότυπα =="
setup
run --stable -y </dev/null >/dev/null 2>&1
run --current -y </dev/null >/dev/null 2>&1
n=$(grep -cE '^https?://ftp\.cc\.uoc\.gr' "$MF")
[ "$n" = "1" ]; check "μία μόνο γραμμή uoc μετά δύο εκτελέσεις" $?
grep -qxF "https://ftp.cc.uoc.gr/mirrors/linux/slackware/slackware64-current/" "$MF"
check "μένει η νεότερη επιλογή (current)" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
