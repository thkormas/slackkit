#!/bin/bash
# Τεστ harness για το enable_sbo... enable_sudo_JBs.sh με mock περιβάλλον.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/enable_sudo_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/stub.log"
SUDOERS="$TMP/sudoers"
SUDOERS_D="$TMP/sudoers.d"
mkdir -p "$BIN" "$SUDOERS_D"

pass=0; fail=0
check() {
	if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
	else fail=$((fail+1)); echo "FAIL - $1"; fi
}

# stubs
cat >"$BIN/id" <<'EOF'
#!/bin/bash
echo "id $*" >>"$STUB_LOG"
# id -u / id χρήστη / id -nG χρήστης
case "$1" in
-u) echo "${STUB_UID:-0}"; exit 0 ;;
-nG) echo "users"; exit 0 ;;
*) [ "$1" = "den_yparxei" ] && exit 1; exit 0 ;;
esac
EOF
cat >"$BIN/visudo" <<'EOF'
#!/bin/bash
echo "visudo $*" >>"$STUB_LOG"
exit "${STUB_VISUDO_RC:-0}"
EOF
cat >"$BIN/usermod" <<'EOF'
#!/bin/bash
echo "usermod $*" >>"$STUB_LOG"
exit 0
EOF
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
:
EOF
chmod +x "$BIN"/*

setup() {
	cat >"$SUDOERS" <<'EOF'
root ALL=(ALL) ALL
# %wheel ALL=(ALL) ALL
EOF
	rm -f "$SUDOERS_D"/slackkit "$SUDOERS".bak.* 2>/dev/null
	: >"$LOG"
}

run() {
	PATH="$BIN:$PATH" STUB_LOG="$LOG" STUB_UID="${STUB_UID:-0}" \
	STUB_VISUDO_RC="${STUB_VISUDO_RC:-0}" STUB_USER="${STUB_USER:-tkor}" \
	SUDOERS_FILE="$SUDOERS" SUDOERS_D="$SUDOERS_D" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: dry-run με χρήστη =="
setup
out=$(run -n tkor 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "χρήστης     : tkor"
check "δείχνει στόχο χρήστη" $?
grep -q "usermod" "$LOG"; [ $? -ne 0 ]; check "dry-run: καμία αλλαγή" $?
grep -qE "^%wheel" "$SUDOERS"; [ $? -ne 0 ]; check "dry-run: sudoers αμετάβλητο (χωρίς ενεργό %wheel)" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: ενεργοποίηση sudo για tkor (-y) =="
setup
run -y tkor >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qE "^%wheel ALL=\(ALL\) ALL$" "$SUDOERS"
check "%wheel ενεργοποιήθηκε (uncomment)" $?
grep -qE "^tkor[[:space:]]+ALL=\(ALL\) ALL$" "$SUDOERS_D/slackkit"
check "sudoers.d γραμμή για tkor" $?
[ -f "$SUDOERS".bak.* ] 2>/dev/null || ls "$SUDOERS".bak.* >/dev/null 2>&1
check "backup sudoers" $?
grep -q "usermod -aG wheel tkor" "$LOG"
check "προστέθηκε στην ομάδα wheel" $?
grep -q "^visudo -c" "$LOG"
check "έγινε visudo -c επιβεβαίωση" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: ερώτηση στην αρχή =="
setup
printf 'maria\ny\n' | run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qE "^maria[[:space:]]+ALL" "$SUDOERS_D/slackkit"
check "ενεργοποιήθηκε ο χρήστης από την ερώτηση" $?

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: visudo αποτυχία μετά την αλλαγή -> rollback =="
setup
STUB_VISUDO_RC=1 run -y tkor >/dev/null 2>&1; rc=$?
# το αρχικό sudoers ήταν άκυρο ήδη -> πρέπει να σταματήσει πριν αλλάξει κάτι
[ "$rc" -ne 0 ]; check "exit != 0 όταν το visudo -c αποτυχάνει αρχικά" $?
grep -qE "^%wheel ALL" "$SUDOERS"; [ $? -ne 0 ]; check "καμία αλλαγή στο sudoers" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: non-root -> άρνηση =="
setup
STUB_UID=1000 run -y tkor >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 ως non-root" $?
grep -q "usermod" "$LOG"; [ $? -ne 0 ]; check "καμία εντολή ως non-root" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: άγνωστος χρήστης -> ξεκάθαρο σφάλμα =="
setup
run -y den_yparxei >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 για άγνωστο χρήστη" $?

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: idempotent - δεύτερη εκτέλεση χωρίς διπλότυπα =="
setup
run -y tkor >/dev/null 2>&1
run -y tkor >/dev/null 2>&1; rc=$?
check "exit 0 στη δεύτερη" "$rc"
n=$(grep -c "^tkor[[:space:]]" "$SUDOERS_D/slackkit")
[ "$n" = "1" ]; check "μία μόνο γραμμή tkor στο sudoers.d" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
