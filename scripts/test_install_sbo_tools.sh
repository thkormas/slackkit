#!/bin/bash
# Τεστ harness για το install_sbo_tools_JBs.sh με mock περιβάλλον.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/install_sbo_tools_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/stub.log"
PKGS="$TMP/packages"
CONF="$TMP/sbopkg.conf"
PROFD="$TMP/profile.d"
mkdir -p "$BIN" "$PKGS" "$PROFD"

pass=0; fail=0
check() {
	if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
	else fail=$((fail+1)); echo "FAIL - $1"; fi
}

# stubs
cat >"$BIN/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo "${STUB_UID:-0}"; exit 0; }
exit 0
EOF
cat >"$BIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
[ "${STUB_CURL_RC:-0}" -ne 0 ] && exit "$STUB_CURL_RC"
# -o file
out=""
prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
[ -n "$out" ] && echo "fake-txz" >"$out"
exit 0
EOF
cat >"$BIN/installpkg" <<'EOF'
#!/bin/bash
echo "installpkg $*" >>"$STUB_LOG"
exit "${STUB_INSTPKGS_RC:-0}"
EOF
cat >"$BIN/sbopkg" <<'EOF'
#!/bin/bash
echo "sbopkg $*" >>"$STUB_LOG"
exit "${STUB_SBOPKG_RC:-0}"
EOF
cat >"$BIN/slackpkg" <<'EOF'
#!/bin/bash
echo "slackpkg $*" >>"$STUB_LOG"
exit 0
EOF
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
:
EOF
chmod +x "$BIN"/*

setup() {
	rm -f "$PKGS"/* 2>/dev/null
	rm -rf "$PROFD"
	mkdir -p "$PROFD"
	printf 'BRANCH="15.0"\nOTHER=x\n' >"$CONF"
	: >"$LOG"
}

setup_installed() { # όλα ήδη εγκατεστημένα
	setup
	: >"$PKGS/sbopkg-0.38.3-noarch-1_wsr"
	: >"$PKGS/sbotools-4.13-noarch-1_SBo"
	: >"$PKGS/slpkg-6.1.7-noarch-1_SBo"
}

run() {
	PATH="$BIN:$PATH" STUB_LOG="$LOG" STUB_UID="${STUB_UID:-0}" \
	STUB_CURL_RC="${STUB_CURL_RC:-0}" STUB_SBOPKG_RC="${STUB_SBOPKG_RC:-0}" \
	STUB_INSTPKGS_RC="${STUB_INSTPKGS_RC:-0}" \
	PACKAGES_DIR="$PKGS" SBOPKG_CONF="$CONF" PROFILE_D="$PROFD" \
	CCACHE_BIN="${CCACHE_BIN:-ccache}" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: dry-run --stable χωρίς αλλαγές =="
setup
out=$(run -n --stable 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "SBo branch  : 15.0"
check "δείχνει branch 15.0" $?
echo "$out" | grep -q "MAKEFLAGS"
check "δείχνει compile plan" $?
grep -q "curl\|sbopkg\|installpkg" "$LOG"; [ $? -ne 0 ]; check "dry-run: καμία εντολή" $?
[ ! -f "$PROFD/slackkit-makeflags.sh" ]; check "dry-run: χωρίς profile.d" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: πλήρης εγκατάσταση (ερώτηση s + y) =="
setup
printf 's\ny\n' | run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^curl " "$LOG"
check "λήψη sbopkg" $?
grep -q "^installpkg " "$LOG"
check "installpkg sbopkg" $?
grep -q "^sbopkg -r$" "$LOG"
check "sync sbopkg -r" $?
grep -q "^sbopkg -i sbotools$" "$LOG"
check "sbopkg -i sbotools" $?
grep -q "^sbopkg -i slpkg$" "$LOG"
check "sbopkg -i slpkg" $?
grep -q 'BRANCH="15.0"' "$CONF"
check "BRANCH=15.0 στο conf" $?
ls "$CONF".bak.* >/dev/null 2>&1; [ $? -ne 0 ]
check "idempotent: χωρίς backup όταν το branch είναι ήδη σωστό" $?
grep -q 'MAKEFLAGS="-j$(nproc)"' "$PROFD/slackkit-makeflags.sh"
check "profile.d με MAKEFLAGS -j" $?
grep -q 'NUMJOBS="-j$(nproc)"' "$PROFD/slackkit-makeflags.sh"
check "profile.d με NUMJOBS -j" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: --current -y -> BRANCH=current =="
setup
run -y --current </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q 'BRANCH="current"' "$CONF"
check "BRANCH=current στο conf" $?
ls "$CONF".bak.* >/dev/null 2>&1
check "backup πριν την αλλαγή branch" $?

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: ήδη εγκατεστημένα όλα -> τίποτα να κάνει =="
setup_installed
run -y --stable </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^curl " "$LOG"; [ $? -ne 0 ]; check "καμία λήψη" $?
grep -q "^installpkg " "$LOG"; [ $? -ne 0 ]; check "κανένα installpkg" $?
grep -q "^sbopkg -i " "$LOG"; [ $? -ne 0 ]; check "κανένα sbopkg -i" $?
grep -q 'BRANCH="15.0"' "$CONF"
check "conf αμετάβλητο (ήδη 15.0)" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: --no-sync =="
setup
run -y --stable --no-sync </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^sbopkg -r$" "$LOG"; [ $? -ne 0 ]; check "κανένα sbopkg -r" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: αποτυχία λήψης sbopkg -> exit 1 αλλά συνέχεια στα υπόλοιπα =="
setup
STUB_CURL_RC=1 run -y --stable </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0" $?
[ -f "$PROFD/slackkit-makeflags.sh" ]; check "το profile.d γράφτηκε παρόλη την αποτυχία" $?

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: non-root -> άρνηση =="
setup
STUB_UID=1000 run -y --stable </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 ως non-root" $?
grep -q "curl" "$LOG"; [ $? -ne 0 ]; check "καμία εντολή ως non-root" $?

# ---------------------------------------------------------------- TEST 8 -----
echo "== TEST 8: --ccache τρέχει slackpkg install =="
setup_installed
# Θέλουμε ξεκάθαρο PATH-απόντα ccache binary (υπάρχει σε ορισμένα περιβάλλοντα,
# π.χ. slackware live) - γι' αυτό δίνουμε ρητά ανύπαρκτο όνομα:
CCACHE_BIN=ccache-not-installed run -y --stable --ccache </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^slackpkg .*install ccache$" "$LOG"
check "slackpkg install ccache" $?

# ---------------------------------------------------------------- TEST 9 -----
echo "== TEST 9: σύγχρονο sbopkg.conf με REPO_BRANCH= (0.38.x) =="
setup
printf 'REPO_BRANCH=${REPO_BRANCH:-15.0}\nOTHER=x\n' >"$CONF"
run -y --current --no-sync </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q '^REPO_BRANCH="current"$' "$CONF"
check "REPO_BRANCH → current" $?
ls "$CONF".bak.* >/dev/null 2>&1
check "υπάρχει backup του conf" $?

# ---------------------------------------------------------------- TEST 10 ----
echo "== TEST 10: conf χωρίς γνωστή μεταβλητή -> προσθήκη REPO_BRANCH =="
setup
printf 'OTHER=x\n' >"$CONF"
run -y --stable --no-sync </dev/null >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q '^REPO_BRANCH="15.0"$' "$CONF"
check "REPO_BRANCH προστέθηκε" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
