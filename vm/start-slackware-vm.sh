#!/bin/bash
# start-slackware-vm.sh - εκκινά VM με Slackware 15.0 LIVE ISO για τα τεστ slackkit.
#
# Γιατί live και όχι εγκατάσταση: η live έκδοση κάνει boot αμέσως (καμία
# διαδραστική εγκατάσταση), τρέχει σε RAM/disposable οπότε τα διαστρεπτικά τεστ
# (removepkg, sysctl) δεν χάλαγαν τίποτα, και έχει ΠΡΑΓΜΑΤΙΚΑ slackpkg /
# removepkg / grub2-mkconfig / sysctl για end-to-end έλεγχο.
#
# Χρήση:
#   ./start-slackware-vm.sh          # εκκίνηση VM (boot από ISO - live)
#   BOOT=disk ./start-slackware-vm.sh  # boot από τον εγκατεστημένο δίσκο
#                                     # (χωρίς ISO - μετά την εγκατάσταση)
#
# Μετά την εκκίνηση (στο παράθυρο του VM):
#   1. Σύνδεση: root / root
#   2. Μία εντολή για τα τεστ:
#      sh /mnt/slackkit/vm/run-slackkit-tests.sh
#   Αποτελέσματα γράφονται στον κοινό φάκελο (διαβάζονται από τον host):
#      ~/slackkit/vm/test-results.txt
#
# Επιπλέον: SSH forwarding localhost:2222 -> guest:22 (αν στήσεις sshd).

set -euo pipefail

ISO=${ISO:-$HOME/Downloads/slackware64-live-15.0.iso}
BOOT=${BOOT:-cdrom}   # cdrom (live ISO) | disk (εγκατεστημένο σύστημα)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DISK=${DISK:-$SCRIPT_DIR/slackware-live.qcow2}
SHARE_DIR=${SHARE_DIR:-$HOME/slackkit}
SSH_PORT=${SSH_PORT:-2222}

CDROM_ARGS=()
if [ "$BOOT" = "cdrom" ]; then
	[ -f "$ISO" ] || { echo "Δεν βρέθηκε η ISO: $ISO" >&2; exit 1; }
	CDROM_ARGS=(-cdrom "$ISO" -boot d)
fi

if [ ! -f "$DISK" ]; then
	echo "δημιουργία disk: $DISK (40G)"
	qemu-img create -f qcow2 "$DISK" 40G
fi

# Ρυθμίσεις VM: 2 CPU / 3GB RAM / 40G disk, KVM, virtfs share του slackkit repo
# (mount tag: slackkit -> /mnt/slackkit στο guest χωρίς δίκτυο), SSH fwd.
exec qemu-system-x86_64 \
	-enable-kvm \
	-cpu host \
	-m 3072 \
	-smp 2 \
	-drive "file=$DISK,format=qcow2,if=virtio" \
	${CDROM_ARGS[@]+"${CDROM_ARGS[@]}"} \
	-virtfs "local,path=$SHARE_DIR,mount_tag=slackkit,security_model=mapped-xattr,id=slackkit" \
	-netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
	-device virtio-net-pci,netdev=net0 \
	-display gtk \
	-name slackkit-slackware-live
