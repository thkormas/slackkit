#!/bin/bash
# speedup_swappiness_JBs.sh v1.0.0
#
# Slackware: ορίζει vm.swappiness = 6 (ή ό,τι θέλεις με --value) και κάνει την
# αλλαγή να επιβιώνει στο reboot.
#
# Τι κάνει:
#   1. persistent : γραμμή `vm.swappiness = N` στο /etc/sysctl.conf - αυτό
#      διαβάζει το /etc/rc.d/rc.sysctl στο boot του Slackware (sysvinit), οπότε
#      η τιμή μένει μόνιμα χωρίς systemd
#   2. runtime    : sysctl -w vm.swappiness=N (ισχύει αμέσως, χωρίς reboot)
#   3. επιβεβαίωση και στα δύο επίπεδα (read-back)
#
# Ασφάλεια:
#   * -n / --dry-run δείχνει τι θα έγινε χωρίς να αλλάξει τίποτα
#   * -s / --show δείχνει μόνο την τρέχουσα κατάσταση
#   * backup του /etc/sysctl.conf (.bak.<timestamp>) πριν κάθε αλλαγή
#   * ΠΟΤΕ δεν αγγίζει άλλες sysctl ρυθμίσεις - μόνο τη γραμμή vm.swappiness
#   * έλεγχος root μόνο όταν πρόκειται πραγματικά να αλλάξει κάτι
#
# Χρήση:
#   sudo ./speedup_swappiness_JBs.sh            # ορίζει vm.swappiness=6
#   sudo ./speedup_swappiness_JBs.sh --value 10 # άλλη τιμή
#   ./speedup_swappiness_JBs.sh -n              # δες τι θα έγινε
#   ./speedup_swappiness_JBs.sh -s              # τρέχουσα κατάσταση
#
# (τα paths είναι παραμετροποιήσιμα μέσω env: SYSCTL_CONF - χρήσιμο για δοκιμές)

set -uo pipefail

PROG=$(basename "$0")

SYSCTL_CONF=${SYSCTL_CONF:-/etc/sysctl.conf}
VALUE=6
DRY_RUN=0
SHOW=0

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

usage() {
	cat <<EOF
$PROG - vm.swappiness για Slackware (runtime + persistent στο /etc/sysctl.conf)

Χρήση:
  $PROG [επιλογές]

Επιλογές:
  --value N    Η τιμή swappiness (default: 6, εύρος 0-200)
  -n, --dry-run  Δείχνει τι θα έγινε χωρίς να αλλάξει τίποτα
  -s, --show     Δείχνει μόνο την τρέχουσα κατάσταση
  -h, --help     Αυτό το κείμενο

Παράδειγμα:
  sudo $PROG --value 6
EOF
}

# --- ανάλυση επιλογών ---------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
	--value)
		[ $# -ge 2 ] || die "η επιλογή --value χρειάζεται αριθμό"
		VALUE=$2; shift ;;
	--value=*)  VALUE=${1#--value=} ;;
	-n|--dry-run) DRY_RUN=1 ;;
	-s|--show)    SHOW=1 ;;
	-h|--help)    usage; exit 0 ;;
	-*)           die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)            die "μη αναμενόμενο όνομα: $1 (δες '$PROG --help')" ;;
	esac
	shift
done

case "$VALUE" in ''|*[!0-9]*) die "--value πρέπει να είναι ακέραιος 0-200 (π.χ. --value 6)" ;; esac
[ "$VALUE" -le 200 ] || die "--value πρέπει να είναι <= 200 (π.χ. --value 6)"

# --- τρέχουσα κατάσταση -------------------------------------------------------

# runtime τιμή (κενό αν το sysctl δεν απαντά)
runtime_swappiness() {
	sysctl -n vm.swappiness 2>/dev/null | tr -dc '0-9'
}

# τιμή στο αρχείο persistent (τελευταία γραμμή vm.swappiness, αν υπάρχει)
conf_swappiness() {
	sed -n 's/^[[:space:]]*vm\.swappiness[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' \
		"$SYSCTL_CONF" 2>/dev/null | tail -1
}

cur=$(runtime_swappiness)
conf=$(conf_swappiness)

if [ "$SHOW" -eq 1 ]; then
	info "runtime   (sysctl)        : ${cur:-n/a}"
	info "persistent ($SYSCTL_CONF): ${conf:-καμία γραμμή vm.swappiness}"
	exit 0
fi

info "στόχος vm.swappiness       : $VALUE"
info "τρέχον runtime             : ${cur:-n/a}"
info "τρέχον persistent          : ${conf:-καμία γραμμή} ($SYSCTL_CONF)"

need_change=0
[ "$cur" = "$VALUE" ] || need_change=1
[ "$conf" = "$VALUE" ] || need_change=1

if [ "$need_change" -eq 0 ]; then
	info "τα πάντα είναι ήδη στο $VALUE - τίποτα να κάνει"
	exit 0
fi

# --- dry-run ------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	[ "$conf" = "$VALUE" ] || info "θα γραφότανε: vm.swappiness = $VALUE στο $SYSCTL_CONF (με backup .bak.<ts>)"
	[ "$cur" = "$VALUE" ] || info "θα εκτελούτανε: sysctl -w vm.swappiness=$VALUE"
	info "(dry-run: δεν έγινε καμία αλλαγή)"
	exit 0
fi

# --- εκτέλεση -----------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"

ts=$(date +%Y%m%d-%H%M%S)

# 1) persistent: /etc/sysctl.conf (διαβάζεται από το rc.sysctl στο boot)
if [ "$conf" != "$VALUE" ]; then
	if [ -f "$SYSCTL_CONF" ]; then
		cp -a "$SYSCTL_CONF" "$SYSCTL_CONF.bak.$ts" || fail "αποτυχία backup: $SYSCTL_CONF"
		info "backup: $SYSCTL_CONF.bak.$ts"

		if grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' "$SYSCTL_CONF"; then
			# υπάρχουσα(ες) γραμμή(ες) vm.swappiness -> αντικατάσταση με τη δική μας
			sed -i "s/^[[:space:]]*vm\.swappiness[[:space:]]*=.*/vm.swappiness = $VALUE/" "$SYSCTL_CONF" ||
				fail "αποτυχία ενημέρωσης $SYSCTL_CONF"
		else
			printf '\n# slackkit speedup_swappiness_JBs.sh\nvm.swappiness = %s\n' "$VALUE" \
				>>"$SYSCTL_CONF" || fail "αποτυχία εγγραφής: $SYSCTL_CONF"
		fi
	else
		printf '# slackkit speedup_swappiness_JBs.sh\nvm.swappiness = %s\n' "$VALUE" \
			>"$SYSCTL_CONF" || fail "αποτυχία δημιουργίας: $SYSCTL_CONF"
	fi
	info "persistent: vm.swappiness = $VALUE -> $SYSCTL_CONF"
fi

# 2) runtime: ισχύει αμέσως χωρίς reboot
if [ "$cur" != "$VALUE" ]; then
	if sysctl -w "vm.swappiness=$VALUE" >/dev/null 2>&1; then
		info "runtime: sysctl -w vm.swappiness=$VALUE"
	else
		fail "το sysctl -w απέτυχε (άδεια δικαιωμάτων;)"
	fi
fi

# 3) επιβεβαίωση και στα δύο επίπεδα
cur2=$(runtime_swappiness)
conf2=$(conf_swappiness)
[ "$cur2" = "$VALUE" ] || fail "το runtime δεν έγινε $VALUE (διαβάστηκε: ${cur2:-n/a})"
[ "$conf2" = "$VALUE" ] || fail "το persistent δεν έγινε $VALUE (διαβάστηκε: ${conf2:-n/a})"

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	info "ολοκληρώθηκε: vm.swappiness = $VALUE (runtime + persistent)"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -i preferences-system "Slackware speedup" \
			"vm.swappiness = $VALUE ορίστηκε (runtime + persistent)" 2>/dev/null || true
	fi
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
exit 1
