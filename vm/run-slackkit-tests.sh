#!/bin/bash
# run-slackkit-tests.sh - τρέχει ΜΕΣΑ στο Slackware live VM (root) και γράφει
# τα αποτελέσματα στον κοινό φάκελο του host (vm/test-results.txt).
#
# Χρήση (από το console του VM, root):
#   sh /mnt/slackkit/vm/run-slackkit-tests.sh          # check (ασφαλές, μόνο read/dry-run)
#   sh /mnt/slackkit/vm/run-slackkit-tests.sh full     # + ΠΡΑΓΜΑΤΙΚΕΣ αλλαγές (disposable live)
#
# check  : mock harnesses (7 suites, 206 checks) + πραγματικοί dry-run/read-only
#          έλεγχοι (και των 7 scripts)
# full   : + πραγματικός καθαρισμός πυρήνων (--no-update, χωρίς slackpkg download)
#          + πραγματική εφαρμογή vm.swappiness=6

set -u

MODE=${1:-check}

# --- εύρεση των scripts: 9p share, extract από tarball, ή δίπλα σε αυτό το αρχείο
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
REPO=""
if [ -n "$SELF" ] && [ -d "$SELF/../scripts" ]; then
	# τρέχει από εξαγμένο copy ή από το share: repo = μία επίπεδο πάνω
	REPO=$(cd "$SELF/.." && pwd)
elif [ -d /mnt/slackkit/scripts ]; then
	REPO=/mnt/slackkit
else
	# τελευταίος ελιγμός: mount του 9p share
	SHARE=/mnt/slackkit
	mkdir -p "$SHARE"
	mount -t 9p -o trans=virtio slackkit "$SHARE" 2>/dev/null ||
		mount -t 9p -o trans=virtio,version=9p2000.L slackkit "$SHARE" 2>/dev/null
	[ -d "$SHARE/scripts" ] && REPO=$SHARE
fi

[ -n "$REPO" ] && [ -d "$REPO/scripts" ] || {
	echo "ΔΕΝ ΒΡΕΘΗΚΑΝ τα scripts. Δοκίμασε:" >&2
	echo "  wget http://10.0.2.2:8000/slackkit.tar.gz && tar xzf slackkit.tar.gz" >&2
	echo "  sh slackkit/vm/run-slackkit-tests.sh" >&2
	exit 1
}

RESULTS="$REPO/vm/test-results.txt"
SCRIPTS="$REPO/scripts"

# αν το repo είναι read-only (π.χ. σε μερικά mounts), γράφουμε results σε /tmp
: >"$RESULTS" 2>/dev/null || RESULTS=/tmp/slackkit-test-results.txt

pass=0
fail=0
summary=""

step() { # $1=όνομα, υπόλοιπα=εντολή
	name=$1
	shift
	echo ""
	echo "########## $name ##########"
	if "$@"; then
		pass=$((pass + 1))
		summary="$summary
PASS - $name"
	else
		rc=$?
		fail=$((fail + 1))
		summary="$summary
FAIL - $name (rc=$rc)"
	fi
}

main() {
	echo "=============================================="
	echo " slackkit tests σε ΠΡΑΓΜΑΤΙΚΟ Slackware"
	echo " mode: $MODE"
	echo "=============================================="
	echo "ημερομηνία:  $(date)"
	echo "kernel:      $(uname -a)"
	echo "distro:      $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo n/a)"
	echo "root:        $(id -u) ($(whoami))"
	echo "swappiness:  $(sysctl -n vm.swappiness 2>/dev/null || echo n/a)"

	cd "$SCRIPTS" || exit 1

	# 1) mock harnesses (ίδια με στον host - πρέπει να περνάνε και εδώ)
	step "harness: kernels (50 checks)" bash test_clean_old_kernels.sh
	step "harness: swappiness (27 checks)" bash test_speedup_swappiness.sh
	step "harness: grub (30 checks)" bash test_install_grub.sh
	step "harness: mirrors (27 checks)" bash test_setup_slackware_mirror.sh
	step "harness: sbo tools (30 checks)" bash test_install_sbo_tools.sh
	step "harness: sudo (19 checks)" bash test_enable_sudo.sh
	step "harness: gui (23 checks)" bash test_setup_gui.sh

	# 2) ΠΡΑΓΜΑΤΙΚΟΙ read-only έλεγχοι στο live σύστημα
	step "real: dry-run kernels (read-only)" bash slackware_clean_old_kernels_JBs.sh -n
	step "real: dry-run swappiness (read-only)" bash speedup_swappiness_JBs.sh -n
	step "real: swappiness status" bash speedup_swappiness_JBs.sh -s
	step "real: dry-run grub (read-only)" bash install_grub_JBs.sh -n
	step "real: dry-run mirror stable (read-only)" \
		bash setup_slackware_mirror_JBs.sh -n --stable --no-update
	step "real: dry-run sbo tools (read-only)" \
		bash install_sbo_tools_JBs.sh -n --stable --no-sync
	step "real: dry-run sudo (read-only)" bash enable_sudo_JBs.sh -n
	step "real: dry-run gui (read-only)" bash setup_gui_JBs.sh -n --console

	# 3) πραγματικές αλλαγές (μόνο σε full mode - ζωντανά στο RAM/disposable)
	if [ "$MODE" = "full" ]; then
		step "REAL: καθαρισμός παλιών πυρήνων (--no-update)" \
			bash slackware_clean_old_kernels_JBs.sh -y --no-update
		step "REAL: vm.swappiness=6" bash speedup_swappiness_JBs.sh
		step "verify: swappiness runtime=6" \
			sh -c '[ "$(sysctl -n vm.swappiness)" = "6" ]'
		step "verify: swappiness persistent στο sysctl.conf" \
			grep -qE '^vm\.swappiness = 6' /etc/sysctl.conf
	fi

	echo ""
	echo "=============================================="
	printf 'ΣΥΝΟΛΟ: %s ok, %s FAIL\n' "$pass" "$fail"
	printf '%s\n' "$summary"
	echo "ALL_DONE rc=$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
	echo "=============================================="
	[ "$fail" -eq 0 ]
}

main "$@" 2>&1 | tee "$RESULTS"
exit "${PIPESTATUS[0]}"
