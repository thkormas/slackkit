#!/bin/bash
# install_grub_JBs.sh v1.0.0
#
# Slackware: αυτόματη εγκατάσταση/ανανέωση GRUB με υποστήριξη UEFI και BIOS
# (legacy), ΠΑΝΤΑ με ερώτηση επιβεβαίωσης πριν αλλάξει κάτι.
#
# Τι κάνει:
#   1. Ανίχνευση boot mode: UEFI (υπάρχει /sys/firmware/efi) ή BIOS/legacy
#      (μπορείς να το εξαναγκάσεις με --uefi / --bios)
#   2. Ανίχνευση σκληρού δίσκου: ο δίσκος γονέας του /boot (ή του /) μέσω
#      findmnt + lsblk (ή --disk /dev/XXX χειροκίνητα)
#   3. ΕΡΩΤΗΣΗ: δείχνει plan (mode, δίσκος, εντολές) και ρωτάει «Συνέχεια;»
#   4. Εγκατάσταση:
#        UEFI : mount /boot/efi (αν χρειάζεται) + grub-install
#               --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
#        BIOS : grub-install --target=i386-pcbios <disk>
#      (το όνομα ανιχνεύεται: Slackware → grub-install, άλλες → grub2-install)
#   5. Ανανέωση grub.cfg (με backup) και επιβεβαίωση ότι υπάρχει menuentry
#
# Ασφάλεια:
#   * -n / --dry-run δείχνει το plan χωρίς να αλλάξει τίποτα
#   * χωρίς -y ρωτάει πάντα πριν από κάθε αλλαγή («με ερώτηση»)
#   * σφάλματα μετριώνται και αναφέρονται (non-zero exit), δεν σταματούν
#   * δεν αγγίζει άλλα bootloaders ή partitions - μόνο GRUB
#
# Χρήση:
#   sudo ./install_grub_JBs.sh              # ανίχνευση + ερώτηση + εγκατάσταση
#   ./install_grub_JBs.sh -n                # δες τι θα έγινε
#   sudo ./install_grub_JBs.sh -y           # χωρίς ερώτηση (scripts/cron)
#   sudo ./install_grub_JBs.sh --disk /dev/nvme0n1
#
# (paths/env παραμετροποιήσιμα για δοκιμές: EFI_SYSFS, BOOT_MOUNT, EFI_MOUNT,
#  GRUB_CFG, GRUB_DIR, GRUB_EFI_ID)

set -uo pipefail

PROG=$(basename "$0")

EFI_SYSFS=${EFI_SYSFS:-/sys/firmware/efi}
BOOT_MOUNT=${BOOT_MOUNT:-/boot}
EFI_MOUNT=${EFI_MOUNT:-/boot/efi}
GRUB_CFG=${GRUB_CFG:-/boot/grub2/grub.cfg}
GRUB_DIR=${GRUB_DIR:-/boot/grub2}
GRUB_EFI_ID=${GRUB_EFI_ID:-GRUB}

FORCE_MODE=""    # uefi | bios | κενό (auto)
DISK=""          # --disk override
DRY_RUN=0
ASSUME_YES=0

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

usage() {
	cat <<EOF
$PROG - αυτόματη εγκατάσταση GRUB για Slackware (UEFI και BIOS, με ερώτηση)

Χρήση:
  $PROG [επιλογές]

Επιλογές:
  -n, --dry-run   Δείχνει το plan χωρίς να αλλάξει τίποτα
  -y, --yes       Χωρίς ερώτηση επιβεβαίωσης
  --uefi          Εξαναγκασμός UEFI mode
  --bios          Εξαναγκασμός BIOS/legacy mode
  --disk DEV      Στόχος δίσκος (π.χ. /dev/sda) - αλλιώς ανιχνεύεται
  -h, --help      Αυτό το κείμενο
EOF
}

# --- ανάλυση επιλογών ---------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
	-n|--dry-run) DRY_RUN=1 ;;
	-y|--yes)     ASSUME_YES=1 ;;
	--uefi)       FORCE_MODE=uefi ;;
	--bios)       FORCE_MODE=bios ;;
	--disk)
		[ $# -ge 2 ] || die "η επιλογή --disk χρειάζεται συσκευή"
		DISK=$2; shift ;;
	--disk=*)     DISK=${1#--disk=} ;;
	-h|--help)    usage; exit 0 ;;
	-*)           die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)            die "μη αναμενόμενο όνομα: $1 (δες '$PROG --help')" ;;
	esac
	shift
done

# --- ανίχνευση boot mode ------------------------------------------------------

detect_mode() {
	if [ -n "$FORCE_MODE" ]; then
		printf '%s\n' "$FORCE_MODE"
	elif [ -d "$EFI_SYSFS" ]; then
		echo uefi
	else
		echo bios
	fi
}

MODE=$(detect_mode)

# --- ανίχνευση δίσκου ---------------------------------------------------------

detect_disk() {
	# βρίσκει τον δίσκο-γονέα του /boot (ή του / αν το /boot είναι merged)
	local src pk name
	src=$(findmnt -n -o SOURCE "$BOOT_MOUNT" 2>/dev/null) ||
		src=$(findmnt -n -o SOURCE / 2>/dev/null) ||
		src=""
	if [ -n "$src" ]; then
		pk=$(lsblk -nno pkname "$src" 2>/dev/null | head -1)
		if [ -n "$pk" ]; then
			printf '/dev/%s\n' "$pk"
			return 0
		elif [ -b "$src" ]; then
			printf '%s\n' "$src"
			return 0
		fi
	fi
	# fallback: σάρωση /sys/block για πραγματικό δίσκο - καλύπτει live
	# συστήματα (overlay root) και virtio/nvme συσκευές που δεν "κρατά"
	# το lsblk pkname πάνω από ένα non-block SOURCE.
	for name in /sys/block/*; do
		name=$(basename "$name")
		case "$name" in
			loop*|ram*|zram*|fd*|sr*|dm-*|md*) continue ;;
			sd*|hd*|vd*|xvd*|nvme*|mmcblk*) ;;
			*) continue ;;
		esac
		[ -b "/dev/$name" ] || continue
		printf '/dev/%s\n' "$name"
		return 0
	done
	return 1
}

if [ -z "$DISK" ]; then
	DISK=$(detect_disk) || DISK=""
fi

# --- ανίχνευση ονομάτων grub binaries -------------------------------------------
# Το Slackware τα ονομάζει grub-install/grub-mkconfig, άλλες διανομές
# grub2-install/grub2-mkconfig - χρησιμοποιούμε όποιο υπάρχει.
GRUB_INSTALL=$(command -v grub2-install 2>/dev/null || command -v grub-install 2>/dev/null)
GRUB_MKCONFIG=$(command -v grub2-mkconfig 2>/dev/null || command -v grub-mkconfig 2>/dev/null)
GRUB_INSTALL_NAME=$(basename "${GRUB_INSTALL:-grub2-install}")
GRUB_MKCONFIG_NAME=$(basename "${GRUB_MKCONFIG:-grub2-mkconfig}")

# --- plan ---------------------------------------------------------------------

info "== Εγκατάσταση GRUB (Slackware) =="
info "boot mode : $MODE$( [ "$MODE" = uefi ] && [ -d "$EFI_SYSFS" ] && [ -z "$FORCE_MODE" ] && echo ' (ανιχνεύτηκε)' )"
info "δίσκος    : ${DISK:-'(δεν ανιχνεύτηκε)'}"

if [ "$MODE" = uefi ]; then
	info "εντολές   :"
	info "  mount $EFI_MOUNT (αν δεν είναι ήδη mounted)"
	info "  $GRUB_INSTALL_NAME --target=x86_64-efi --efi-directory=$EFI_MOUNT --bootloader-id=$GRUB_EFI_ID --recheck"
	info "  $GRUB_MKCONFIG_NAME -o $GRUB_CFG"
else
	if [ -z "$DISK" ]; then
		die "δεν ανιχνεύτηκε δίσκος - δώσε --disk /dev/XXX"
	fi
	info "εντολές   :"
	info "  $GRUB_INSTALL_NAME --target=i386-pcbios --recheck $DISK"
	info "  $GRUB_MKCONFIG_NAME -o $GRUB_CFG"
fi

# --- dry-run ------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	info "(dry-run: δεν έγινε καμία αλλαγή)"
	exit 0
fi

# --- εκτέλεση (με ερώτηση) ----------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"

if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Εγκατάσταση GRUB (%s) στο %s; συνέχεια; [y/N] ' \
		"$MODE" "${DISK:-$EFI_MOUNT}"
	read -r ans
	case "$ans" in
	y|Y|yes|YES) ;;
	*) info "ακυρώθηκε"; exit 0 ;;
	esac
fi

command -v "$GRUB_INSTALL_NAME" >/dev/null 2>&1 ||
	die "δεν βρέθηκε grub-install/grub2-install - εγκατέστησε το πακέτο grub"

ts=$(date +%Y%m%d-%H%M%S)

if [ "$MODE" = uefi ]; then
	# το /boot/efi πρέπει να είναι mounted (συνήθως στο fstab)
	if ! mountpoint -q "$EFI_MOUNT" 2>/dev/null; then
		info "mount $EFI_MOUNT..."
		if ! mount "$EFI_MOUNT" 2>/dev/null; then
			fail "αποτυχία mount $EFI_MOUNT (υπάρχει γραμμή στο /etc/fstab;)"
		fi
	fi

	if "$GRUB_INSTALL" --target=x86_64-efi \
		"--efi-directory=$EFI_MOUNT" \
		"--bootloader-id=$GRUB_EFI_ID" --recheck; then
		info "$GRUB_INSTALL_NAME (x86_64-efi) ολοκληρώθηκε"
	else
		fail "το $GRUB_INSTALL_NAME (x86_64-efi) απέτυχε"
	fi
else
	if "$GRUB_INSTALL" --target=i386-pcbios --recheck "$DISK"; then
		info "$GRUB_INSTALL_NAME (i386-pcbios σε $DISK) ολοκληρώθηκε"
	else
		fail "το $GRUB_INSTALL_NAME (i386-pcbios) απέτυχε"
	fi
fi

# ανανέωση grub.cfg με backup (στατικό config στο Slackware)
if [ -n "$GRUB_MKCONFIG" ] && [ -f "$GRUB_CFG" ]; then
	cp -a "$GRUB_CFG" "$GRUB_CFG.bak.$ts" 2>/dev/null &&
		info "backup: $GRUB_CFG.bak.$ts"
fi

if [ -n "$GRUB_MKCONFIG" ]; then
	if "$GRUB_MKCONFIG" -o "$GRUB_CFG" >/dev/null 2>&1; then
		info "$GRUB_MKCONFIG_NAME -> $GRUB_CFG"
	else
		fail "το $GRUB_MKCONFIG_NAME απέτυχε"
	fi
else
	fail "δεν βρέθηκε grub-mkconfig/grub2-mkconfig"
fi

# --- επιβεβαίωση --------------------------------------------------------------

if [ -f "$GRUB_CFG" ]; then
	grep -q "menuentry" "$GRUB_CFG" ||
		fail "το $GRUB_CFG δεν περιέχει menuentry"
else
	fail "δεν βρέθηκε το $GRUB_CFG μετά την εγκατάσταση"
fi

if [ "$MODE" = uefi ] && [ "$failures" -eq 0 ]; then
	efi_bin="$EFI_MOUNT/EFI/$GRUB_EFI_ID/grubx64.efi"
	[ -f "$efi_bin" ] ||
		fail "δεν βρέθηκε το $efi_bin μετά την εγκατάσταση"
fi

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	info "ολοκληρώθηκε: GRUB ($MODE) εγκαταστάθηκε και το grub.cfg ανανεώθηκε"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -i drive-harddisk "Slackware GRUB" \
			"GRUB ($MODE) εγκαταστάθηκε επιτυχώς" 2>/dev/null || true
	fi
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
exit 1
