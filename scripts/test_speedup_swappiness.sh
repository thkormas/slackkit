#!/bin/bash
# Τεστ harness για το speedup_swappiness_JBs.sh με mock περιβάλλον.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/speedup_swappiness_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
CONF="$TMP/sysctl.conf"
STATE="$TMP/runtime.state"    # η τιμή που "διαβάζει" το sysctl -n
LOG="$TMP/stub.log"
mkdir -p "$BIN"

pass=0; fail=0
check() { # $1=περιγραφή, $2=κωδικός (0=ok)
	if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
	else fail=$((fail+1)); echo "FAIL - $1"; fi
}

# stubs ---------------------------------------------------------------------
cat >"$BIN/sysctl" <<'EOF'
#!/bin/bash
echo "sysctl $*" >>"$STUB_LOG"
case "$1" in
-n)
	[ "$2" = "vm.swappiness" ] || exit 1
	cat "$STUB_STATE" 2>/dev/null || exit 1
	exit 0 ;;
-w)
	[ "${STUB_SYSCTL_W_RC:-0}" -ne 0 ] && exit "$STUB_SYSCTL_W_RC"
	# -w vm.swappiness=6
	v=${2#vm.swappiness=}
	[ "$v" = "$2" ] && exit 1
	printf '%s\n' "$v" >"$STUB_STATE"
	exit 0 ;;
esac
exit 1
EOF
cat >"$BIN/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >>"$STUB_LOG"
EOF
chmod +x "$BIN"/*

setup() { # $1=runtime τιμή, $2=περιεχόμενο conf ("|"/κενό για καμία γραμμή)
	printf '%s\n' "$1" >"$STATE"
	if [ -n "$2" ] && [ "$2" != "|" ]; then
		printf '%s\n' "$2" >"$CONF"
	else
		: >"$CONF"
	fi
	: >"$LOG"
}

run() { # $@ = επιλογές
	PATH="$BIN:$PATH" SYSCTL_CONF="$CONF" STUB_LOG="$LOG" STUB_STATE="$STATE" \
	STUB_UID="${STUB_UID:-0}" STUB_SYSCTL_W_RC="${STUB_SYSCTL_W_RC:-0}" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: ήδη στο 6 -> τίποτα να κάνει =="
setup 6 "vm.swappiness = 6"
out=$(run 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "τα πάντα είναι ήδη στο 6"
check "μήνυμα 'τα πάντα ήδη στο 6'" $?
grep -q "sysctl -w" "$LOG"
[ $? -ne 0 ]; check "ΔΕΝ τρέχει sysctl -w" $?
[ ! -e "$CONF.bak."* ] 2>/dev/null; check "ΔΕΝ δημιουργείται backup" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: αλλαγή σε 6 (runtime 10, κενό conf) =="
setup 10 "|"
run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "sysctl -w vm.swappiness=6" "$LOG"
check "τράχτηκε sysctl -w vm.swappiness=6" $?
grep -qE '^vm\.swappiness = 6$' "$CONF"
check "το conf περιέχει vm.swappiness = 6" $?
[ "$(cat "$STATE")" = "6" ]; check "το runtime state έγινε 6" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: dry-run δείχνει plan χωρίς αλλαγές =="
setup 10 "|"
out=$(run -n 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "θα εκτελούτανε: sysctl -w vm.swappiness=6"
check "αναφέρει το planned sysctl -w" $?
echo "$out" | grep -q "θα γραφότανε"
check "αναφέρει το planned persistent write" $?
grep -q "sysctl -w" "$LOG"
[ $? -ne 0 ]; check "dry-run ΔΕΝ εκτελεί sysctl -w" $?
grep -q "6" "$CONF"
[ $? -ne 0 ]; check "dry-run ΔΕΝ γράφει στο conf" $?
[ "$(cat "$STATE")" = "10" ]; check "dry-run ΔΕΝ αλλάζει runtime" $?

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: υπάρχουσα τιμή 30 -> αντικατάσταση + backup =="
setup 30 "vm.swappiness = 30"
run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qE '^vm\.swappiness = 6$' "$CONF"
check "η γραμμή έγινε vm.swappiness = 6" $?
grep -c "vm.swappiness" "$CONF" | grep -qx "1"
check "καμία διπλή γραμμή vm.swappiness" $?
ls "$CONF".bak.* >/dev/null 2>&1
check "δημιουργήθηκε backup πριν την αλλαγή" $?
grep -q "vm.swappiness = 30" "$CONF".bak.* 2>/dev/null
check "το backup κρατάει την παλιά τιμή 30" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: --value 10 (προσαρμοσμένη τιμή) =="
setup 6 "vm.swappiness = 6"
run --value 10 >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -qE '^vm\.swappiness = 10$' "$CONF"
check "conf -> vm.swappiness = 10" $?
[ "$(cat "$STATE")" = "10" ]; check "runtime -> 10" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: αποτυχία sysctl -w -> exit 1 =="
setup 10 "|"
STUB_SYSCTL_W_RC=1 run >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 όταν αποτυχάνει το sysctl -w" $?

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: non-root χωρίς dry-run -> αρνείται =="
setup 10 "|"
STUB_UID=1000 run >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 ως non-root" $?
grep -qE '^vm\.swappiness = 6$' "$CONF"
[ $? -ne 0 ]; check "ΔΕΝ γράφει στο conf ως non-root" $?

# ---------------------------------------------------------------- TEST 8 -----
echo "== TEST 8: μη αριθμητικό --value -> άμεσο σφάλμα =="
setup 10 "|"
run --value abc >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 για --value abc" $?
run --value 201 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 για --value 201 (>200)" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
