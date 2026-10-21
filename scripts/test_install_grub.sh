#!/bin/bash
# Τεστ harness για το install_grub_JBs.sh με mock περιβάλλον (UEFI και BIOS).
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/install_grub_JBs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/stub.log"
EFI_SYSFS_DIR="$TMP/sys-firmware-efi"    # ύπαρξη = UEFI mode
BOOT_DIR_MNT="$TMP/boot"
EFI_DIR_MNT="$TMP/boot-efi"
GRUB_CFG="$BOOT_DIR_MNT/grub2/grub.cfg"
mkdir -p "$BIN" "$BOOT_DIR_MNT/grub2"

pass=0; fail=0
check() {
	if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "ok   - $1"
	else fail=$((fail+1)); echo "FAIL - $1"; fi
}

# stubs -----------------------------------------------------------------------
cat >"$BIN/findmnt" <<'EOF'
#!/bin/bash
echo "/dev/sda2"
EOF
cat >"$BIN/lsblk" <<'EOF'
#!/bin/bash
echo "sda"
EOF
cat >"$BIN/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
cat >"$BIN/grub2-install" <<'EOF'
#!/bin/bash
echo "grub2-install $*" >>"$STUB_LOG"
[ "${STUB_GI_RC:-0}" -ne 0 ] && exit "$STUB_GI_RC"
# σε UEFI δημιουργεί το efi binary όπου περιμένει το script
prev=""
for a in "$@"; do
	case "$prev" in
	--efi-directory=*)
		;;
	esac
	case "$a" in
	--efi-directory=*)
		d=${a#--efi-directory=}
		id=GRUB
		;;
	esac
	prev=$a
done
# προσπάθεια extraction του bootloader-id
id=$(printf '%s\n' "$@" | sed -n 's/^--bootloader-id=//p' | head -1)
[ -n "$id" ] || id=GRUB
d=$(printf '%s\n' "$@" | sed -n 's/^--efi-directory=//p' | head -1)
if [ -n "$d" ]; then
	mkdir -p "$d/EFI/$id"
	: >"$d/EFI/$id/grubx64.efi"
fi
exit 0
EOF
cat >"$BIN/grub2-mkconfig" <<'EOF'
#!/bin/bash
echo "grub2-mkconfig $*" >>"$STUB_LOG"
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && { : >"$out"; echo "menuentry 'Slackware' { }" >>"$out"; }
exit 0
EOF
cat >"$BIN/mountpoint" <<'EOF'
#!/bin/bash
exit 1
EOF
cat >"$BIN/mount" <<'EOF'
#!/bin/bash
echo "mount $*" >>"$STUB_LOG"
exit "${STUB_MOUNT_RC:-0}"
EOF
cat >"$BIN/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >>"$STUB_LOG"
EOF
chmod +x "$BIN"/*

setup() { # $1 = uefi|bios
	rm -rf "$EFI_SYSFS_DIR" "$EFI_DIR_MNT"
	rm -f "$GRUB_CFG" "$GRUB_CFG".bak.* 2>/dev/null
	mkdir -p "$BOOT_DIR_MNT/grub2"
	echo "# old config" >"$GRUB_CFG"
	[ "$1" = uefi ] && mkdir -p "$EFI_SYSFS_DIR"
	: >"$LOG"
}

run() {
	PATH="$BIN:$PATH" STUB_LOG="$LOG" STUB_UID="${STUB_UID:-0}" \
	STUB_GI_RC="${STUB_GI_RC:-0}" STUB_MOUNT_RC="${STUB_MOUNT_RC:-0}" \
	EFI_SYSFS="$EFI_SYSFS_DIR" BOOT_MOUNT="$BOOT_DIR_MNT" \
	EFI_MOUNT="$EFI_DIR_MNT" GRUB_CFG="$GRUB_CFG" \
	bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------- TEST 1 -----
echo "== TEST 1: UEFI ανίχνευση + dry-run χωρίς αλλαγές =="
setup uefi
out=$(run -n 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "boot mode : uefi"
check "ανιχνεύει UEFI" $?
echo "$out" | grep -q "x86_64-efi"
check "δείχνει UEFI εντολές" $?
grep -q . "$LOG"; [ $? -ne 0 ]; check "dry-run: καμία εντολή δεν τρέχηκε" $?

# ---------------------------------------------------------------- TEST 2 -----
echo "== TEST 2: BIOS ανίχνευση + ανίχνευση δίσκου =="
setup bios
out=$(run -n 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "boot mode : bios"
check "ανιχνεύει BIOS" $?
echo "$out" | grep -q "i386-pcbios --recheck /dev/sda"
check "δείχνει BIOS εντολές με /dev/sda (findmnt+lsblk)" $?

# ---------------------------------------------------------------- TEST 3 -----
echo "== TEST 3: UEFI πλήρης εγκατάσταση (-y) =="
setup uefi
run -y >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "grub2-install --target=x86_64-efi --efi-directory=$EFI_DIR_MNT --bootloader-id=GRUB --recheck" "$LOG"
check "grub2-install με σωστά UEFI arguments" $?
grep -q "mount $EFI_DIR_MNT" "$LOG"
check "mount του EFI partition" $?
grep -q "grub2-mkconfig -o $GRUB_CFG" "$LOG"
check "grub2-mkconfig τράπηκε" $?
[ -f "$EFI_DIR_MNT/EFI/GRUB/grubx64.efi" ]
check "δημιουργήθηκε το grubx64.efi" $?
grep -q "menuentry" "$GRUB_CFG"
check "grub.cfg περιέχει menuentry" $?
ls "$GRUB_CFG".bak.* >/dev/null 2>&1
check "backup του παλιού grub.cfg" $?

# ---------------------------------------------------------------- TEST 4 -----
echo "== TEST 4: BIOS πλήρης εγκατάσταση (-y) =="
setup bios
run -y >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "grub2-install --target=i386-pcbios --recheck /dev/sda" "$LOG"
check "grub2-install στο /dev/sda (BIOS)" $?
grep -q "grub2-mkconfig" "$LOG"
check "grub2-mkconfig τράπηκε" $?

# ---------------------------------------------------------------- TEST 5 -----
echo "== TEST 5: ερώτηση - ακύρωση με N =="
setup bios
out=$(printf 'n\n' | run 2>&1); rc=$?
check "exit 0 σε ακύρωση" "$rc"
echo "$out" | grep -q "ακυρώθηκε"
check "μήνυμα ακύρωσης" $?
grep -q "grub2-install\|grub2-mkconfig" "$LOG"
[ $? -ne 0 ]; check "καμία εντολή δεν τρέχηκε μετά την ακύρωση" $?

# ---------------------------------------------------------------- TEST 6 -----
echo "== TEST 6: ερώτηση - συνέχεια με y =="
setup bios
printf 'y\n' | run >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "grub2-install" "$LOG"
check "τρέχηκε μετά το y" $?

# ---------------------------------------------------------------- TEST 7 -----
echo "== TEST 7: αποτυχία grub2-install -> exit 1 =="
setup bios
STUB_GI_RC=1 run -y >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 όταν αποτυχάνει το grub2-install" $?

# ---------------------------------------------------------------- TEST 8 -----
echo "== TEST 8: --disk override =="
setup bios
run -y --disk /dev/nvme0n1 >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "grub2-install --target=i386-pcbios --recheck /dev/nvme0n1" "$LOG"
check "χρησιμοποιήθηκε το /dev/nvme0n1" $?

# ---------------------------------------------------------------- TEST 9 -----
echo "== TEST 9: --uefi εξαναγκασμός χωρίς EFI sysfs =="
setup bios
out=$(run -n --uefi 2>&1); rc=$?
check "exit 0" "$rc"
echo "$out" | grep -q "boot mode : uefi"
check "εξαναγκάστηκε UEFI" $?

# ---------------------------------------------------------------- TEST 10 ----
echo "== TEST 10: non-root χωρίς dry-run -> άρνηση =="
setup bios
STUB_UID=1000 run -y >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 ως non-root" $?
grep -q "grub2-install" "$LOG"
[ $? -ne 0 ]; check "καμία εντολή ως non-root" $?

# ---------------------------------------------------------------- TEST 11 ----
echo "== TEST 11: αποτυχία mount EFI -> exit 1 =="
setup uefi
STUB_MOUNT_RC=1 run -y >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exit != 0 όταν αποτυχάνει το mount" $?

# ---------------------------------------------------------------- TEST 12 ----
echo "== TEST 12: Slackware ονόματα grub-install/grub-mkconfig =="
# Το Slackware δεν έχει grub2-* binaries - το script πρέπει να τα βρίσκει
# από το PATH χωρίς να κάνει lookup σε /usr/sbin του host.
setup bios
BIN2="$TMP/bin-sw"
rm -rf "$BIN2"; mkdir -p "$BIN2"
# απομόνωση: PATH = ΜΟΝΟ τα stubs (το host μπορεί να έχει πραγματικό
# grub2-install στο /usr/bin που θα "έκλεβε" την ανίχνευση)
for f in findmnt lsblk id; do cp "$BIN/$f" "$BIN2/$f"; done
for f in basename cp date grep mount mountpoint; do cp "$(command -v "$f")" "$BIN2/$f"; done
cat >"$BIN2/grub-install" <<'EOF'
#!/bin/bash
echo "grub-install $*" >>"$STUB_LOG"
exit "${STUB_GI_RC:-0}"
EOF
cat >"$BIN2/grub-mkconfig" <<'EOF'
#!/bin/bash
echo "grub-mkconfig $*" >>"$STUB_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
[ -n "$out" ] && printf 'menuentry "Slackware"\n' >"$out"
exit 0
EOF
chmod +x "$BIN2"/*
PATH="$BIN2" STUB_LOG="$LOG" STUB_UID=0 STUB_GI_RC=0 STUB_MOUNT_RC=0 \
	EFI_SYSFS="$EFI_SYSFS_DIR" BOOT_MOUNT="$BOOT_DIR_MNT" \
	EFI_MOUNT="$EFI_DIR_MNT" GRUB_CFG="$GRUB_CFG" \
	/bin/bash "$SCRIPT" -y --bios >/dev/null 2>&1; rc=$?
check "exit 0" "$rc"
grep -q "^grub-install --target=i386-pcbios --recheck /dev/sda" "$LOG"
check "χρησιμοποίησε grub-install (Slackware όνομα)" $?
grep -q "^grub-mkconfig" "$LOG"
check "χρησιμοποίησε grub-mkconfig" $?
grep -q "menuentry" "$GRUB_CFG"
check "grub.cfg με menuentry" $?

echo
echo "== ΣΥΝΟΛΟ: $pass ok, $fail FAIL =="
[ "$fail" -eq 0 ]
