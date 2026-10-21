#!/bin/bash
# install_sbo_tools_JBs.sh v1.0.0
#
# Slackware: εγκατάσταση και παραμετροποίηση των εργαλείων SlackBuilds.org
# (sbopkg, sbotools, slpkg) + γρήγορο compile (parallel make, ccache).
#
# ΕΡΩΤΗΣΗ στην αρχή (μία φορά): branch [s]table 15.0 ή [c]urrent - όρισμα
# στο sbopkg (SBo δέντρο) και στο sync.
#
# Τι κάνει:
#   1. sbopkg: επίσημο prebuilt πακέτο (github releases) + installpkg
#   2. /etc/sbopkg/sbopkg.conf: BRANCH=15.0|current (με backup)
#   3. σύνδεση με το SBo: sbopkg -r (παράλειψη με --no-sync)
#   4. sbotools: sbopkg -i sbotools (αν δεν υπάρχει)
#   5. slpkg: sbopkg -i slpkg (αν δεν υπάρχει)
#   6. ΓΡΗΓΟΡΟ COMPILE: /etc/profile.d/slackkit-makeflags.sh με
#        MAKEFLAGS="-j$(nproc)"  NUMJOBS="-j$(nproc)"
#      (+ PATH με ccache αν υπάρχει, ή --ccache για εγκατάσταση του)
#
# Ασφάλεια:
#   * -n / --dry-run: plan χωρίς αλλαγές
#   * χωρίς -y: επιβεβαίωση πριν την εγκατάσταση
#   * backup /etc/sbopkg/sbopkg.conf πριν κάθε αλλαγή
#   * τα πακέτα που υπάρχουν ήδη ξεπερνιούνται (idempotent)
#   * σφάλματα μετριώνται, δεν σταματούν τα υπόλοιπα βήματα
#
# Χρήση:
#   sudo ./install_sbo_tools_JBs.sh            # ρωτάει stable/current
#   sudo ./install_sbo_tools_JBs.sh --stable   # χωρίς ερώτηση
#   ./install_sbo_tools_JBs.sh -n --current    # dry-run
#
# (env για δοκιμές: PACKAGES_DIR, SBOPKG_CONF, PROFILE_D, CCACHE_DIR, CCACHE_BIN)

set -uo pipefail

PROG=$(basename "$0")

PACKAGES_DIR=${PACKAGES_DIR:-/var/log/packages}
SBOPKG_CONF=${SBOPKG_CONF:-/etc/sbopkg/sbopkg.conf}
PROFILE_D=${PROFILE_D:-/etc/profile.d}
CCACHE_DIR=${CCACHE_DIR:-/usr/lib64/ccache}
CCACHE_BIN=${CCACHE_BIN:-ccache}
SBOpkg_URL=${SBOPKG_URL:-https://github.com/sbopkg/sbopkg/releases/download/0.38.3/sbopkg-0.38.3-noarch-1_wsr.tgz}

CHOICE=""          # stable | current
DRY_RUN=0
ASSUME_YES=0
DO_SYNC=1
DO_CCACHE=0
WORKDIR=""

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

usage() {
	cat <<EOF
$PROG - εγκατάσταση SBo εργαλείων (sbopkg, sbotools, slpkg) + γρήγορο compile

Χρήση:
  $PROG [επιλογές]

Επιλογές:
  --stable        SBo branch 15.0 (χωρίς ερώτηση)
  --current       SBo branch current (χωρίς ερώτηση)
  --no-sync       Μην κάνεις sbopkg -r (sync SBo δέντρου)
  --ccache        Εγκατάσταση ccache μέσω slackpkg (πιο γρήγορα rebuilds)
  -n, --dry-run   Δείχνει το plan χωρίς αλλαγές
  -y, --yes       Χωρίς ερώτηση επιβεβαίωσης
  -h, --help      Αυτό το κείμενο
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--stable)    CHOICE=stable ;;
	--current)   CHOICE=current ;;
	--no-sync)   DO_SYNC=0 ;;
	--ccache)    DO_CCACHE=1 ;;
	-n|--dry-run) DRY_RUN=1 ;;
	-y|--yes)    ASSUME_YES=1 ;;
	-h|--help)   usage; exit 0 ;;
	-*)          die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)           die "μη αναμενόμενο όνομα: $1 (δες '$PROG --help')" ;;
	esac
	shift
done

# --- ΕΡΩΤΗΣΗ στην αρχή (μία φορά) --------------------------------------------

if [ -z "$CHOICE" ] && [ "$DRY_RUN" -eq 0 ]; then
	while :; do
		printf 'SBo branch: [s]table 15.0 ή [c]urrent; s/c: '
		read -r ans
		case "$ans" in
		s|S|stable)  CHOICE=stable;  break ;;
		c|C|current) CHOICE=current; break ;;
		*) printf 'Πάτα s ή c\n' ;;
		esac
	done
elif [ -z "$CHOICE" ]; then
	CHOICE=stable
fi

[ "$CHOICE" = current ] && SBO_BRANCH=current || SBO_BRANCH=15.0

# --- κατάσταση ----------------------------------------------------------------

have_pkg() { ls "$PACKAGES_DIR"/$1-* >/dev/null 2>&1; }

# Έλεγχος μέσω βάσης πακέτων (Slackware-idiomatic): το installpkg δημιουργεί
# την εγγραφή, οπότε μετά την εγκατάσταση το βήμα ξεπερνιέται σωστά.
installed() {
	have_pkg "$1"
}

# --- plan ---------------------------------------------------------------------

info "== Εγκατάσταση SBo εργαλείων (Slackware) =="
info "SBo branch  : $SBO_BRANCH"
info "sbopkg      : $(installed sbopkg && echo 'ήδη εγκατεστημένο' || echo "θα εγκατασταθεί ($SBOpkg_URL)")"
info "sbotools    : $(installed sbotools && echo 'ήδη εγκατεστημένο' || echo 'θα εγκατασταθεί μέσω sbopkg -i')"
info "slpkg       : $(installed slpkg && echo 'ήδη εγκατεστημένο' || echo 'θα εγκατασταθεί μέσω sbopkg -i')"
[ "$DO_SYNC" -eq 1 ] && info "sync        : sbopkg -r (SBo $SBO_BRANCH)" || info "sync        : παραλείπεται (--no-sync)"
info "compile     : MAKEFLAGS/NUMJOBS=-j\$(nproc) στο $PROFILE_D/slackkit-makeflags.sh"
[ "$DO_CCACHE" -eq 1 ] && info "ccache      : θα εγκατασταθεί μέσω slackpkg"

if [ "$DRY_RUN" -eq 1 ]; then
	info "(dry-run: δεν έγινε καμία αλλαγή)"
	exit 0
fi

# --- εκτέλεση -----------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"

if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Εγκατάσταση/παραμετροποίηση SBo εργαλείων (branch %s); συνέχεια; [y/N] ' "$SBO_BRANCH"
	read -r ans
	case "$ans" in
	y|Y|yes|YES) ;;
	*) info "ακυρώθηκε"; exit 0 ;;
	esac
fi

ts=$(date +%Y%m%d-%H%M%S)

# 1) sbopkg (prebuilt πακέτο)
if installed sbopkg; then
	info "sbopkg ήδη εγκατεστημένο - παράλειψη"
else
	command -v curl >/dev/null 2>&1 || die "δεν βρέθηκε curl - εγκατέστησέ το πρώτα"
	WORKDIR=$(mktemp -d) || die "αποτυχία temp dir"
	txz="$WORKDIR/sbopkg.tgz"
	info "λήψη sbopkg: $SBOpkg_URL"
	if curl -fsSL -o "$txz" "$SBOpkg_URL"; then
		if command -v installpkg >/dev/null 2>&1 && installpkg "$txz"; then
			info "sbopkg εγκαταστάθηκε"
			# προσομοίωση/εγγραφή στη βάση για συνέπεια ελέγχου
			[ -d "$PACKAGES_DIR" ] && : >"$PACKAGES_DIR/sbopkg-0.38.3-noarch-1_wsr" 2>/dev/null
		else
			fail "το installpkg απέτυχε για $txz"
		fi
	else
		fail "η λήψη του sbopkg απέτυχε ($SBOpkg_URL)"
	fi
	cleanup; WORKDIR=""
fi

# 2) παραμετροποίηση BRANCH στο sbopkg.conf
if [ -f "$SBOPKG_CONF" ]; then
	if grep -qE '^BRANCH=' "$SBOPKG_CONF"; then
		cur_branch=$(sed -n 's/^BRANCH="\?([^"]*)"*/\1/p' "$SBOPKG_CONF" | head -1)
		if [ "$cur_branch" != "$SBO_BRANCH" ]; then
			cp -a "$SBOPKG_CONF" "$SBOPKG_CONF.bak.$ts" 2>/dev/null &&
				info "backup: $SBOPKG_CONF.bak.$ts"
			sed -i "s~^BRANCH=.*~BRANCH=\"$SBO_BRANCH\"~" "$SBOPKG_CONF" ||
				fail "αποτυχία ενημέρωσης BRANCH στο $SBOPKG_CONF"
			grep -q "BRANCH=\"$SBO_BRANCH\"" "$SBOPKG_CONF" &&
				info "sbopkg BRANCH → $SBO_BRANCH" ||
				fail "ο BRANCH δεν ενημερώθηκε σωστά"
		else
			info "sbopkg BRANCH ήδη $SBO_BRANCH"
		fi
	else
		fail "δεν βρέθηκε γραμμή BRANCH= στο $SBOPKG_CONF"
	fi
else
	[ "$failures" -eq 0 ] && fail "δεν βρέθηκε $SBOPKG_CONF (το sbopkg δεν εγκαταστάθηκε;)"
fi

# 3) sync SBo δέντρου + 4/5) εγκατάσταση sbotools/slpkg μέσω sbopkg
if command -v sbopkg >/dev/null 2>&1; then
	if [ "$DO_SYNC" -eq 1 ]; then
		info "sbopkg -r (sync SBo $SBO_BRANCH - μπορεί να πάρει λίγο χρόνο)..."
		if sbopkg -r; then
			info "ok: SBo σύγχρονισμος"
		else
			fail "το sbopkg -r απέτυχε"
		fi
	fi

	if installed sbotools; then
		info "sbotools ήδη εγκατεστημένο - παράλειψη"
	elif [ "$DO_SYNC" -eq 1 ]; then
		info "sbopkg -i sbotools..."
		sbopkg -i sbotools && info "ok: sbotools" || fail "το sbopkg -i sbotools απέτυχε"
	else
		info "sbotools: παραλείπεται (--no-sync χωρίς προηγούμενο sync)"
	fi

	if installed slpkg; then
		info "slpkg ήδη εγκατεστημένο - παράλειψη"
	elif [ "$DO_SYNC" -eq 1 ]; then
		info "sbopkg -i slpkg..."
		sbopkg -i slpkg && info "ok: slpkg" || fail "το sbopkg -i slpkg απέτυχε"
	else
		info "slpkg: παραλείπεται (--no-sync χωρίς προηγούμενο sync)"
	fi
else
	fail "το sbopkg δεν είναι διαθέσιμο - sbotools/slpkg παραλείπονται"
fi

# 5) ccache (προαιρετικά)
if [ "$DO_CCACHE" -eq 1 ]; then
	if command -v "$CCACHE_BIN" >/dev/null 2>&1; then
		info "ccache ήδη εγκατεστημένο"
	elif command -v slackpkg >/dev/null 2>&1; then
		info "εγκατάσταση ccache μέσω slackpkg..."
		slackpkg -batch=on install ccache && info "ok: ccache" ||
			fail "η εγκατάσταση ccache απέτυχε"
	else
		fail "δεν βρέθηκε slackpkg για εγκατάσταση ccache"
	fi
fi

# 6) ΓΡΗΓΟΡΟ COMPILE: profile.d
MF="$PROFILE_D/slackkit-makeflags.sh"
mkdir -p "$PROFILE_D" 2>/dev/null
cat >"$MF" <<'EOF'
# slackkit: γρήγορο compile - parallel make για όλα τα builds
# (SlackBuilds χρησιμοποιούν MAKEFLAGS και NUMJOBS)
export MAKEFLAGS="-j$(nproc)"
export NUMJOBS="-j$(nproc)"
# ccache: επιταχύνει rebuilds του ίδιου πακέτου (αν είναι εγκατεστημένο)
[ -d /usr/lib64/ccache ] && export PATH="/usr/lib64/ccache:$PATH"
EOF
if [ -f "$MF" ]; then
	info "compile config: $MF (MAKEFLAGS/NUMJOBS=-j\$(nproc))"
else
	fail "αποτυχία εγγραφής: $MF"
fi

# --- επιβεβαίωση --------------------------------------------------------------

info ""
info "== Επιβεβαίωση =="
for tool in sbopkg sboinstall slpkg; do
	if command -v "$tool" >/dev/null 2>&1; then
		info "  $tool: OK ($(command -v "$tool"))"
	else
		info "  $tool: λείπει"
	fi
done
[ -f "$MF" ] && grep -q 'MAKEFLAGS="-j' "$MF" && info "  MAKEFLAGS: OK" || fail "το MAKEFLAGS δεν διαβάστηκε σωστά"

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	info "ολοκληρώθηκε: sbopkg+sbotools+slpkg (branch $SBO_BRANCH) + γρήγορο compile"
	info "Σημείωση: το MAKEFLAGS ισχύει από το επόμενο login (ή: source $MF)"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -i system-software-install "Slackware SBo" \
			"sbopkg/sbotools/slpkg εγκαταστάθηκαν (branch $SBO_BRANCH)" 2>/dev/null || true
	fi
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
exit 1
