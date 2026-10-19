#!/bin/bash
# enable_sudo_JBs.sh v1.0.0
#
# Slackware: αυτόματη ενεργοποίηση sudo για έναν χρήστη (το "πάτημα" που κάναμε
# χειροκίνητα στο VM: uncomment %wheel + προσθήκη στην ομάδα wheel).
#
# ΕΡΩΤΗΣΗ στην αρχή (μία φορά): ποιον χρήστη να ενεργοποιήσουμε (αν δεν δοθεί
# ως όρισμα).
#
# Τι κάνει:
#   1. Uncomment της γραμμής %wheel στο /etc/sudoers (με backup)
#   2. Δημιουργία /etc/sudoers.d/slackkit με τον χρήστη (chmod 440)
#   3. Προσθήκη του χρήστη στην ομάδα wheel (usermod -aG)
#   4. Επιβεβαίωση με visudo -c (το validation δεν παρακάμπτεται ποτέ)
#
# Ασφάλεια:
#   * -n / --dry-run: plan χωρίς αλλαγές
#   * backup /etc/sudoers πριν κάθε αλλαγή + visudo -c πριν/μετά
#   * αν το visudo -c αποτύχει μετά την αλλαγή → αΥΤΟΜΑΤΗ αποκατάσταση backup
#   * δεν αγγίζει καμία άλλη ρύθμιση sudo
#
# Χρήση:
#   sudo ./enable_sudo_JBs.sh tkor
#   sudo ./enable_sudo_JBs.sh            # ρωτάει ποιον χρήστη
#   ./enable_sudo_JBs.sh -n tkor
#
# (env για δοκιμές: SUDOERS_FILE, SUDOERS_D)

set -uo pipefail

PROG=$(basename "$0")

SUDOERS_FILE=${SUDOERS_FILE:-/etc/sudoers}
SUDOERS_D=${SUDOERS_D:-/etc/sudoers.d}
TARGET_USER=""

DRY_RUN=0
ASSUME_YES=0

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

usage() {
	cat <<EOF
$PROG - αυτόματη ενεργοποίηση sudo για χρήστη (Slackware)

Χρήση:
  $PROG [επιλογές] [χρήστης]

Επιλογές:
  -n, --dry-run   Δείχνει το plan χωρίς αλλαγές
  -y, --yes       Χωρίς ερώτηση επιβεβαίωσης
  -h, --help      Αυτό το κείμενο
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	-n|--dry-run) DRY_RUN=1 ;;
	-y|--yes)     ASSUME_YES=1 ;;
	-h|--help)    usage; exit 0 ;;
	-*)           die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)            [ -z "$TARGET_USER" ] && TARGET_USER=$1 || die "περισσότεροι από ένας χρήστης: $1" ;;
	esac
	shift
done

# --- ΕΡΩΤΗΣΗ στην αρχή (μία φορά) --------------------------------------------

if [ -z "$TARGET_USER" ] && [ "$DRY_RUN" -eq 0 ]; then
	printf 'Ποιον χρήστη να ενεργοποιήσουμε για sudo; '
	read -r TARGET_USER
	[ -n "$TARGET_USER" ] || die "δεν δόθηκε χρήστης"
fi

# --- plan ---------------------------------------------------------------------

wheel_line="%wheel ALL=(ALL) ALL"
has_wheel_rule=0
grep -qE "^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL\)[[:space:]]+ALL" "$SUDOERS_FILE" 2>/dev/null && has_wheel_rule=1

info "== Ενεργοποίηση sudo =="
info "χρήστης     : ${TARGET_USER:-'(θα ρωτηθεί)'}"
info "sudoers     : $SUDOERS_FILE ($([ "$has_wheel_rule" -eq 1 ] && echo '%wheel ήδη ενεργό' || echo 'θα ενεργοποιηθεί το %wheel'))"
info "sudoers.d   : $SUDOERS_D/slackkit (γραμμή χρήστη)"
info "ομάδα       : wheel (usermod -aG)"
info "επιβεβαίωση : visudo -c (με αυτόματη αποκατάσταση αν αποτύχει)"

if [ "$DRY_RUN" -eq 1 ]; then
	info "(dry-run: δεν έγινε καμία αλλαγή)"
	exit 0
fi

# --- εκτέλεση -----------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"
[ -n "$TARGET_USER" ] || die "δεν δόθηκε χρήστης"
id "$TARGET_USER" >/dev/null 2>&1 || die "δεν υπάρχει ο χρήστης: $TARGET_USER"

if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Ενεργοποίηση sudo για %s; συνέχεια; [y/N] ' "$TARGET_USER"
	read -r ans
	case "$ans" in
	y|Y|yes|YES) ;;
	*) info "ακυρώθηκε"; exit 0 ;;
	esac
fi

ts=$(date +%Y%m%d-%H%M%S)

# 0) το αρχικό sudoers πρέπει να είναι ήδη έγκυρο
if command -v visudo >/dev/null 2>&1 && ! visudo -c >/dev/null 2>&1; then
	die "το υπάρχον $SUDOERS_FILE δεν περνάει visudo -c - διόρθωσέ το πρώτα"
fi

# 1) %wheel ενεργό στο sudoers (με backup + visudo safety)
if [ "$has_wheel_rule" -eq 0 ]; then
	cp -a "$SUDOERS_FILE" "$SUDOERS_FILE.bak.$ts" || fail "αποτυχία backup: $SUDOERS_FILE"
	info "backup: $SUDOERS_FILE.bak.$ts"
	if grep -qE '^[[:space:]]*#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL\)[[:space:]]+ALL' "$SUDOERS_FILE"; then
		sed -i -E 's~^[[:space:]]*#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL\)[[:space:]]+ALL)~\1~' "$SUDOERS_FILE" ||
			fail "αποτυχία ενεργοποίησης %wheel"
	elif ! grep -qE "^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL\)" "$SUDOERS_FILE"; then
		printf '\n# slackkit enable_sudo_JBs.sh\n%s\n' "$wheel_line" >>"$SUDOERS_FILE" ||
			fail "αποτυχία προσθήκης %wheel"
	fi

	if command -v visudo >/dev/null 2>&1 && ! visudo -c >/dev/null 2>&1; then
		warn "το visudo -c απέτυχε μετά την αλλαγή - αποκατάσταση backup"
		cp -a "$SUDOERS_FILE.bak.$ts" "$SUDOERS_FILE"
		fail "η αλλαγή %wheel ακυρώθηκε (αποκαταστάθηκε το αρχικό sudoers)"
	else
		info "%wheel ενεργοποιήθηκε στο $SUDOERS_FILE"
	fi
else
	info "%wheel ήδη ενεργό"
fi

# 2) sudoers.d γραμμή για τον χρήστη (idempotent)
mkdir -p "$SUDOERS_D" 2>/dev/null
sd_file="$SUDOERS_D/slackkit"
if [ -f "$sd_file" ] && grep -qE "^${TARGET_USER}[[:space:]]" "$sd_file" 2>/dev/null; then
	info "$sd_file ήδη περιέχει τον $TARGET_USER"
else
	printf '%s ALL=(ALL) ALL\n' "$TARGET_USER" >"$sd_file" || fail "αποτυχία εγγραφής: $sd_file"
	chmod 440 "$sd_file" 2>/dev/null
	if command -v visudo >/dev/null 2>&1 && ! visudo -c >/dev/null 2>&1; then
		rm -f "$sd_file"
		fail "το visudo -c απέτυχε με $sd_file - αρχείο αφαιρέθηκε"
	else
		info "γράφτηκε: $sd_file ($TARGET_USER ALL=(ALL) ALL)"
	fi
fi

# 3) ομάδα wheel
if command -v usermod >/dev/null 2>&1; then
	if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx wheel; then
		info "ο $TARGET_USER ήδη στην ομάδα wheel"
	elif usermod -aG wheel "$TARGET_USER"; then
		info "ο $TARGET_USER προστέθηκε στην ομάδα wheel"
	else
		fail "το usermod -aG wheel απέτυχε"
	fi
else
	fail "δεν βρέθηκε usermod"
fi

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	info "ολοκληρώθηκε: ο $TARGET_USER μπορεί να χρησιμοποιεί sudo (ΑΠΟΤΟΜΑ στο επόμενο login)"
	info "Σημείωση: αν ήδη συνδέθηκε, κάνε logout/login ή: newgrp wheel"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -i dialog-password "Slackware sudo" \
			"Το sudo ενεργοποιήθηκε για τον $TARGET_USER" 2>/dev/null || true
	fi
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
exit 1
