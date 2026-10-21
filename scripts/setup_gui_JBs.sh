#!/bin/bash
# setup_gui_JBs.sh v1.0.0
#
# Slackware: ενεργοποίηση γραφικού περιβάλλοντος ΜΕΤΑ την εγκατάσταση
# (το Slackware βγαίνει σε console - αυτό το script σε φέρνει σε GUI).
#
# ΕΡΩΤΗΣΗ στην αρχή (μία φορά):
#   [b]oot σε GUI κατευθείαν (inittab id:3 → id:4, DM αν υπάρχει αλλιώς startx)
#   [c]onsole (μένεις σε tty, γράφεις startx όταν θες)
# και, αν υπάρχουν πολλά DE/WM, ποιο να βάλει στο .xinitrc.
#
# Τι κάνει:
#   1. Ανίχνευση εγκατεστημένων γραφικών περιβαλλόντων (KDE/Plasma, Xfce,
#      MATE, Cinnamon, Openbox, i3, dwm, fluxbox, startx)
#   2. Γράφει ~/.xinitrc (του SUDO_USER ή root) με exec του επιλεγμένου
#   3. Αν [b]: /etc/inittab id:3 → id:4 (με backup) - boot σε GUI
#   4. Επιβεβαίωση: inittab/xinitrc + μήνυμα τι να κάνει μετά
#
# Ασφάλεια:
#   * -n / --dry-run: plan χωρίς αλλαγές
#   * backup /etc/inittab πριν κάθε αλλαγή
#   * αν κανένα DE/WM δεν είναι εγκατεστημένο, το script το λέει και σταματά
#     (δεν εγκαθιστά πακέτα μόνο του)
#
# Χρήση:
#   sudo ./setup_gui_JBs.sh            # ρωτάει boot-GUI ή console + DE
#   sudo ./setup_gui_JBs.sh -y --boot  # χωρίς ερώτηση, boot σε GUI
#   ./setup_gui_JBs.sh -n              # δες τι θα έγινε
#
# (env για δοκιμές: INITTAB_FILE, XINITRC, GUI_USER_HOME, GUI_DETECTED_PATH)

set -uo pipefail

PROG=$(basename "$0")

INITTAB_FILE=${INITTAB_FILE:-/etc/inittab}
XINITRC=${XINITRC:-}
GUI_USER_HOME=${GUI_USER_HOME:-}
GUI_DETECTED_PATH=${GUI_DETECTED_PATH:-}

BOOT_GUI=""       # yes | no
PICKED_DE=""

DRY_RUN=0
ASSUME_YES=0

failures=0

info() { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { warn "$*"; exit 1; }
fail() { warn "$*"; failures=$((failures + 1)); }

usage() {
	cat <<EOF
$PROG - γραφικό περιβάλλον μετά την εγκατάσταση (Slackware)

Χρήση:
  $PROG [επιλογές]

Επιλογές:
  --boot          Boot απευθείαν σε GUI (inittab id:4)
  --console       Μένεις σε console (startx χειροκίνητα)
  --de NAME       Επιλογή DE/WM για το .xinitrc (χωρίς ερώτηση)
  -n, --dry-run   Δείχνει το plan χωρίς αλλαγές
  -y, --yes       Χωρίς ερώτηση επιβεβαίωσης
  -h, --help      Αυτό το κείμενο
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--boot)     BOOT_GUI=yes ;;
	--console)  BOOT_GUI=no ;;
	--de)
		[ $# -ge 2 ] || die "η επιλογή --de χρειάζεται όνομα"
		PICKED_DE=$2; shift ;;
	--de=*)     PICKED_DE=${1#--de=} ;;
	-n|--dry-run) DRY_RUN=1 ;;
	-y|--yes)   ASSUME_YES=1 ;;
	-h|--help)  usage; exit 0 ;;
	-*)         die "άγνωστη επιλογή: $1 (δες '$PROG --help')" ;;
	*)          die "μη αναμενόμενο όνομα: $1 (δες '$PROG --help')" ;;
	esac
	shift
done

# --- ανίχνευση DE/WM ----------------------------------------------------------

# "όνομα|εντολή εκκίνησης|binary"
DE_CANDIDATES=(
	"plasma|startplasma-x11|startplasma-x11"
	"kde|startkde|startkde"
	"xfce|xfce4-session|xfce4-session"
	"mate|mate-session|mate-session"
	"cinnamon|cinnamon-session|cinnamon-session"
	"openbox|openbox-session|openbox-session"
	"i3|i3|i3"
	"dwm|dwm|dwm"
	"fluxbox|startfluxbox|startfluxbox"
)

detect_des() {
	local line name cmd bin
	for line in "${DE_CANDIDATES[@]}"; do
		IFS='|' read -r name cmd bin <<<"$line"
		if PATH="${GUI_DETECTED_PATH:-$PATH}" command -v "$bin" >/dev/null 2>&1; then
			printf '%s %s\n' "$name" "$cmd"
		fi
	done
}

mapfile -t DE_LINES < <(detect_des)
DE_COUNT=${#DE_LINES[@]}

have_startx=0
PATH="${GUI_DETECTED_PATH:-$PATH}" command -v startx >/dev/null 2>&1 && have_startx=1

# --- ΕΡΩΤΗΣΕΙΣ στην αρχή -----------------------------------------------------

if [ "$DRY_RUN" -eq 0 ] && [ -z "$BOOT_GUI" ]; then
	while :; do
		printf 'Μετά το login, να μπαίνεις κατευθείαν σε GUI; [b]oot-σε-GUI ή [c]onsole; b/c: '
		read -r ans
		case "$ans" in
		b|B) BOOT_GUI=yes; break ;;
		c|C) BOOT_GUI=no;  break ;;
		*) printf 'Πάτα b ή c\n' ;;
		esac
	done
fi

if [ -z "$PICKED_DE" ] && [ "$DE_COUNT" -gt 1 ]; then
	if [ "$DRY_RUN" -eq 0 ]; then
		info "Βρέθηκαν εγκατεστημένα γραφικά περιβάλλοντα:"
		i=1
		for l in "${DE_LINES[@]}"; do
			info "  $i) ${l%% *}"
			i=$((i + 1))
		done
		while :; do
			printf 'Ποιο να βάλω στο .xinitrc (αριθμός); '
			read -r num
			case "$num" in				''|*[!0-9]*) printf 'Δώσε αριθμό\n' ;;
			*)
				if [ "$num" -ge 1 ] && [ "$num" -le "$DE_COUNT" ]; then
					PICKED_DE=${DE_LINES[$((num - 1))]%% *}
					break
				fi
				printf 'Αριθμός εκτός εύρους\n' ;;
			esac
		done
	elif [ "$DE_COUNT" -ge 1 ]; then
		PICKED_DE=${DE_LINES[0]%% *}
	fi
fi

cmd_of_de() { # $1 = όνομα -> εντολή
	local l
	for l in "${DE_LINES[@]}"; do
		[ "${l%% *}" = "$1" ] && { printf '%s\n' "${l#* }"; return 0; }
	done
	return 1
}

# --- plan ---------------------------------------------------------------------

current_init=$(grep -E '^id:' "$INITTAB_FILE" 2>/dev/null | head -1)

info "== Γραφικό περιβάλλον (Slackware) =="
info "τρέχον inittab : ${current_init:-'(καμία γραμμή id:)'}"
info "DE/WM εντοπίστηκαν: $DE_COUNT$([ "$DE_COUNT" -gt 0 ] && echo " ($(printf '%s ' "${DE_LINES[@]%% *}"))")"
info "startx         : $([ "$have_startx" -eq 1 ] && echo υπάρχει || echo λείπει)"
info "boot σε GUI    : ${BOOT_GUI:-'(θα ρωτηθεί)'}"
info "DE για xinitrc : ${PICKED_DE:-'(κανένα/θα επιλεγεί)'}"

if [ "$DRY_RUN" -eq 1 ]; then
	if [ "$BOOT_GUI" = yes ] || [ -z "$BOOT_GUI" ]; then
		info "θα γραφότανε: id:3 → id:4 στο $INITTAB_FILE (με backup)"
	fi
	[ -n "$PICKED_DE" ] && info "θα γραφότανε: ~/.xinitrc με exec $(cmd_of_de "$PICKED_DE" 2>/dev/null || echo DE)"
	info "(dry-run: δεν έγινε καμία αλλαγή)"
	exit 0
fi

# --- εκτέλεση -----------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "πρέπει να τρέξει ως root: sudo $PROG"

[ "$DE_COUNT" -gt 0 ] || [ "$have_startx" -eq 1 ] ||
	die "δεν βρέθηκε κανένα γραφικό περιβάλλον (ούτε DE/WM ούτε startx) - εγκατέστησε ένα (π.χ. slackpkg install xfce) πρώτα"

if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Ενεργοποίηση GUI (boot=%s, de=%s); συνέχεια; [y/N] ' \
		"${BOOT_GUI:-?}" "${PICKED_DE:-?}"
	read -r ans
	case "$ans" in
	y|Y|yes|YES) ;;
	*) info "ακυρώθηκε"; exit 0 ;;
	esac
fi

ts=$(date +%Y%m%d-%H%M%S)

# 1) .xinitrc του χρήστη που τρέχει το sudo (ή root)
if [ -z "$GUI_USER_HOME" ]; then
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
		GUI_USER_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
	fi
	GUI_USER_HOME=${GUI_USER_HOME:-/root}
fi

if [ -n "$PICKED_DE" ]; then
	de_cmd=$(cmd_of_de "$PICKED_DE") || fail "άγνωστο DE: $PICKED_DE"
	if [ -n "$de_cmd" ]; then
		xinitrc="$GUI_USER_HOME/.xinitrc"
		[ -f "$xinitrc" ] && cp -a "$xinitrc" "$xinitrc.bak.$ts" 2>/dev/null &&
			info "backup: $xinitrc.bak.$ts"
		if printf '#!/bin/sh\n# slackkit setup_gui_JBs.sh\nexec %s\n' "$de_cmd" >"$xinitrc" 2>/dev/null; then
			chmod +x "$xinitrc" 2>/dev/null
			info ".xinitrc: exec $de_cmd → $xinitrc"
		else
			fail "αποτυχία εγγραφής: $xinitrc"
		fi
	fi
fi

# 2) boot σε GUI: inittab id:3 → id:4
if [ "$BOOT_GUI" = yes ]; then
	if grep -qE '^id:[34]:initdefault:' "$INITTAB_FILE" 2>/dev/null; then
		if grep -qE '^id:4:initdefault:' "$INITTAB_FILE"; then
			info "το inittab είναι ήδη σε runlevel 4 (GUI)"
		else
			cp -a "$INITTAB_FILE" "$INITTAB_FILE.bak.$ts" || fail "αποτυχία backup: $INITTAB_FILE"
			sed -i 's~^id:3:initdefault:~id:4:initdefault:~' "$INITTAB_FILE" ||
				fail "αποτυχία αλλαγής runlevel"
			grep -qE '^id:4:initdefault:' "$INITTAB_FILE" &&
				info "inittab: runlevel 4 (GUI) - backup: $INITTAB_FILE.bak.$ts" ||
				fail "το runlevel δεν άλλαξε σε 4"
		fi
	else
		fail "δεν βρέθηκε γραμμή id:3/4 στο $INITTAB_FILE"
	fi
else
	info "το inittab δεν άλλαξε (console mode) - χρήση startx για GUI"
fi

# --- σύνοψη -------------------------------------------------------------------

info ""
if [ "$failures" -eq 0 ]; then
	if [ "$BOOT_GUI" = yes ]; then
		info "ολοκληρώθηκε: reboot → γραφικό περιβάλλον${PICKED_DE:+ (DE: $PICKED_DE)}"
	else
		info "ολοκληρώθηκε: τρέξε startx για γραφικό περιβάλλον${PICKED_DE:+ (DE: $PICKED_DE)}"
	fi
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -i preferences-desktop-display "Slackware GUI" \
			"Γραφικό περιβάλλον ενεργοποιήθηκε" 2>/dev/null || true
	fi
	exit 0
fi

warn "τελείωσε με $failures σφάλμα(τα) - δες τις γραμμές ERROR παραπάνω"
exit 1
