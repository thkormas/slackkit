#!/bin/bash
# setup_slackware_mirror_JBs.sh v1.0.0
#
# Slackware: ρύθμιση πακέτων/mirrors του slackpkg σε ΕΛΛΗΝΙΚΟ mirror, με
# ΜΙΑ ΕΡΩΤΗΣΗ στην αρχή: stable (15.0) ή current (development).
#
# Ελληνικά mirrors (επίσημη λίστα mirrors.slackware.com):
#   uoc   ΦΠΑ Κρήτης  https://ftp.cc.uoc.gr/mirrors/linux/slackware/  (https)
#   ntua  ΕΜΠ        http://ftp.ntua.gr/pub/linux/slackware/          (http)
#
# Τι κάνει:
#   1. ΕΡΩΤΗΣΗ στην αρχή (μία φορά): s=stable 15.0 / c=current
#      (ή χωρίς ερώτηση με --stable / --current)
#   2. Backup του /etc/slackpkg/mirrors (.bak.<timestamp>)
#   3. Σχολιάζει τυχόν ενεργό mirror και βάζει το δικό μας (μία ενεργή γραμμή)
#   4. slackpkg update για επιβεβαίωση (παράλειψη με --no-update)
#
# Ασφάλεια:
#   * -n / --dry-run: δείχνει plan χωρίς αλλαγές
#   * χωρίς -y ρωτάει επιβεβαίωση πριν την εγγραφή
#   * δεν αγγίζει καμία άλλη ρύθμιση slackpkg (εκτός mirrors)
#   * αν η επιλογή current είναι σε σταθερή εγκατάσταση, προειδοποιεί
#
# Χρήση:
#   sudo ./setup_slackware_mirror_JBs.sh            # ρωτάει stable/current
#   sudo ./setup_slackware_mirror_JBs.sh --stable   # χωρίς ερώτηση
#   sudo ./setup_slackware_mirror_JBs.sh --current --mirror ntua
#   ./setup_slackware_mirror_JBs.sh -n --stable     # dry-run
#
# (env για δοκιμές: MIRRORS_FILE)

set -uo pipefail

PROG=$(basename "$0")

MIRRORS_FILE=${MIRRORS_FILE:-/etc/slackpkg/mirrors}

CHOICE=""          # stable | current
MIRROR=uoc         # uoc | ntua | official
ARCH=x86_64        # x86_64 | i586
DRY_RUN=0
ASSUME_YES=0
DO_UPDATE=1

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

usage() {
	cat <<EOF
$PROG - ελληνικό mirror για slackpkg (μία ερώτηση: stable ή current)

Χρήση:
  $PROG [επιλογές]

Επιλογές:
  --stable        Slackware 15.0 (χωρίς ερώτηση)
  --current       Slackware-current (χωρίς ερώτηση)
  --mirror M      uoc (default) | ntua | official
  --arch A        x86_64 (default) | i586
  --no-update     Μην τρέχεις slackkg update μετά την αλλαγή
  -n, --dry-run   Δείχνει το plan χωρίς αλλαγές
  -y, --yes       Χωρίς ερώτηση επιβεβαίωσης
  -h, --help      Αυτό το κείμενο
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--stable)   CHOICE=stable ;;
	--current)  CHOICE=current ;;
	--mirror)
		[ $# -ge 2 ] || die "η επιλογή --mirror χρειάζεται τιμή (uoc|ntua|official)"
		MIRROR=$2; shift ;;
	--mirror=*) MIRROR=${1#--mirror=} ;;
	--arch)
		[ $# -ge 2 ] || die "η επιλογή --arch χρειάζεται τιμή (x86_64|i586)"
		ARCH=$2; shift ;;
	--arch=*)   ARCH=${1#--arch=} ;;
	--no-update) DO_UPDATE=0 ;;
	-n|--dry-run) DRY_RUN=1 ;;
	-y|--yes)   ASSUME_YES=1 ;;
	-h|--help)  usage; exit 0 ;;
	-*)         die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)          die "μη αναμενόμενο όνομα: $1 (δες '$PROG --help')" ;;
	esac
	shift
done

case "$MIRROR" in
uoc|ntua|official) ;;
*) die "--mirror: uoc | ntua | official" ;;
esac
case "$ARCH" in
x86_64) ARCH_DIR=slackware64 ;;
i586)   ARCH_DIR=slackware ;;
*) die "--arch: x86_64 | i586" ;;
esac

# --- ΕΡΩΤΗΣΗ στην αρχή (μία φορά) --------------------------------------------

if [ -z "$CHOICE" ] && [ "$DRY_RUN" -eq 0 ]; then
	while :; do
		printf 'Slackware πακέτα: [s]table 15.0 ή [c]urrent (development); s/c: '
		read -r ans
		case "$ans" in
		s|S|stable)  CHOICE=stable;  break ;;
		c|C|current) CHOICE=current; break ;;
		*) printf 'Πάτα s ή c\n' ;;
		esac
	done
elif [ -z "$CHOICE" ]; then
	CHOICE=stable   # dry-run χωρίς επιλογή: δείχνει plan για stable
fi

case "$CHOICE" in
stable)  REL=slackware-15.0 ; URL_REL="${ARCH_DIR}-15.0" ;;
current) REL=slackware-current; URL_REL="${ARCH_DIR}-current" ;;
esac

case "$MIRROR" in
uoc)      BASE="https://ftp.cc.uoc.gr/mirrors/linux/slackware" ;;
ntua)     BASE="http://ftp.ntua.gr/pub/linux/slackware" ;;
official) BASE="http://mirrors.slackware.com" ;;
esac

NEW_URL="$BASE/$URL_REL/"

# --- plan ---------------------------------------------------------------------

active=$(grep -E '^(https?|ftp|rsync)://' "$MIRRORS_FILE" 2>/dev/null | head -1)

info "== Ρύθμιση slackpkg mirrors =="
info "τρέχον ενεργό : ${active:-'(καμία ενεργή γραμμή ή αρχείο)'}"
info "επιλογή       : $CHOICE ($REL)"
info "mirror        : $MIRROR ($ARCH)"
info "νέο URL       : $NEW_URL"

if [ "$CHOICE" = current ]; then
	info "πΡΟΕΙΔΟΠΟΙΗΣΗ  : το current είναι development έκδοση - αν τρέχεις"
	info "                σταθερή 15.0, θα αναβαθμιστείς σε testing περιβάλλον!"
fi

if [ "$DRY_RUN" -eq 1 ]; then
	info "(dry-run: δεν έγινε καμία αλλαγή)"
	exit 0
fi

# --- εκτέλεση -----------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"
[ -f "$MIRRORS_FILE" ] ||
	die "δεν βρέθηκε $MIRRORS_FILE - εγκατέστησε το slackpkg πρώτα"

if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Αλλαγή mirrors σε %s; συνέχεια; [y/N] ' "$NEW_URL"
	read -r ans
	case "$ans" in
	y|Y|yes|YES) ;;
	*) info "ακυρώθηκε"; exit 0 ;;
	esac
fi

ts=$(date +%Y%m%d-%H%M%S)
cp -a "$MIRRORS_FILE" "$MIRRORS_FILE.bak.$ts" || fail "αποτυχία backup: $MIRRORS_FILE"
info "backup: $MIRRORS_FILE.bak.$ts"

# σχολιασμός όλων των ενεργών URL (διατηρώντας το περιεχόμενο)
sed -i -E 's~^(https?|ftp|rsync)://~#\1://~' "$MIRRORS_FILE" ||
	fail "αποτυχία σχολιασμού παλιών mirrors"

# καθαρισμός προηγούμενων δικών μας γραμμών + προσθήκη της νέας
sed -i '/^# slackkit setup_slackware_mirror_JBs.sh$/,+1d' "$MIRRORS_FILE" 2>/dev/null
printf '\n# slackkit setup_slackware_mirror_JBs.sh\n%s\n' "$NEW_URL" >>"$MIRRORS_FILE" ||
	fail "αποτυχία εγγραφής: $MIRRORS_FILE"

if grep -qxF "$NEW_URL" "$MIRRORS_FILE"; then
	info "ενεργό mirror: $NEW_URL"
else
	fail "το URL δεν γράφτηκε σωστά στο $MIRRORS_FILE"
fi

if [ "$DO_UPDATE" -eq 1 ]; then
	if command -v slackpkg >/dev/null 2>&1; then
		info "slackpkg update (ανανέωση βάσεων από το νέο mirror)..."
		if slackpkg -batch=on update; then
			info "ok: slackpkg update"
		else
			fail "το slackpkg update απέτυχε - ίσως το mirror μη διαθέσιμο"
		fi
	else
		fail "δεν βρέθηκε slackpkg - παράλειψη ανανέωσης"
	fi
fi

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	info "ολοκληρώθηκε: slackpkg → $NEW_URL ($CHOICE)"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -i network-wired "Slackware mirrors" \
			"slackpkg → ελληνικό mirror ($CHOICE)" 2>/dev/null || true
	fi
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
exit 1
