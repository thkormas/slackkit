#!/bin/bash
# Τεστ harness για το setup_gui_JBs.sh με mock περιβάλλον.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/setup_gui_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/stub.log"
INITTAB="$TMP/inittab"
DEBIN="$TMP/debin"
HOME_U="$TMP/home"
mkdir -p "$BIN" "$DEBIN" "$HOME_U"

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
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
:
EOF
chmod +x "$BIN"/*

setup() { # $1 = uefi... όχι: $1 = "2des" ή "1de" ή "node"
	rm -f "$HOME_U"/.xinitrc* 2>/dev/null
	printf 'sh:/bin/sh\n# Minimal runlevels\nid:3:initdefault:\n' >"$INITTAB"
	rm -f "$INITTAB".bak.* 2>/dev/null
	rm -f "$DEBIN"/*
	case "${1:-2des}" in
	2des) : >"$DEBIN/xfce4-session"; : >"$DEBIN/openbox-session" ;;
	1de)  : >"$DEBIN/xfce4-session" ;;
	node) : >"$DEBIN/somejunk" ;;
	esac
	: >"$LOG"
}

run() {
	PATH="$BIN:$PATH" STUB_LOG="$LOG" STUB_UID="${STUB_UID:-0}" \
	INITTAB_FILE="$INITTAB" GUI_USER_HOME="$HOME_U" \
	GUI_DETECTED_PATH="$DEBIN:$BIN" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: dry-run --boot --de xfce =="
setup 1de
out=$(run -n --boot --de xfce 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "θα γραφότανε: id:3 → id:4"
check "δείχνει planned inittab αλλαγή" $?
grep -q "^id:3" "$INITTAB"
check "inittab αμετάβλητο" $?
[ ! -f "$HOME_U/.xinitrc" ]; check "χωρίς xinitrc σε dry-run" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: --boot -y --de xfce =="
setup 1de
run -y --boot --de xfce >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^id:4:initdefault:" "$INITTAB"
check "inittab → runlevel 4" $?
ls "$INITTAB".bak.* >/dev/null 2>&1
check "backup inittab" $?
grep -q "^exec xfce4-session$" "$HOME_U/.xinitrc"
check ".xinitrc με exec xfce4-session" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: --console -y --de xfce -> inittab όπως ήταν =="
setup 1de
run -y --console --de xfce >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^id:3:initdefault:" "$INITTAB"
check "inittab μένει id:3" $?
[ -f "$HOME_U/.xinitrc" ]; check "xinitrc γράφτηκε" $?

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: ερώτηση b + επιλογή DE 2 με αριθμό =="
setup 2des
printf 'b\n2\ny\n' | run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^id:4" "$INITTAB"
check "επιλογή b → runlevel 4" $?
grep -q "^exec openbox-session$" "$HOME_U/.xinitrc"
check "2ο DE (openbox) στο .xinitrc" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: ακύρωση με n -> τίποτα =="
setup 1de
printf 'c\nn\n' | run >/dev/null 2>&1; rc=$?
check "exit 0 σε ακύρωση" "$rc"
grep -q "^id:3" "$INITTAB"; check "inittab αμετάβλητο" $?
[ ! -f "$HOME_U/.xinitrc" ]; check "χωρίς xinitrc" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: κανένα DE/WM -> ξεκάθαρο σφάλμα =="
setup node
run -y --boot </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 χωρίς γραφικό περιβάλλον" $?
grep -q "^id:3" "$INITTAB"; check "inittab αμετάβλητο" $?

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: non-root -> άρνηση =="
setup 1de
STUB_UID=1000 run -y --boot --de xfce >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 ως non-root" $?
grep -q "^id:3" "$INITTAB"; check "inittab αμετάβλητο ως non-root" $?

# ---------------------------------------------------------------- TEST 8 -----
echo "== TEST 8: ήδη id:4 -> ειρηνικό (χωρίς δεύτερο backup) =="
setup 1de
run -y --boot --de xfce >/dev/null 2>&1
n=$(ls "$INITTAB".bak.* 2>/dev/null | wc -l)
run -y --boot --de xfce >/dev/null 2>&1; rc=$?
check "exit 0 στη δεύτερη" "$rc"
n2=$(ls "$INITTAB".bak.* 2>/dev/null | wc -l)
[ "$n" = "$n2" ] || [ "$n2" -eq 1 ]; check "όχι νέο backup όταν ήδη id:4" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
