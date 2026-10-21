#!/bin/bash
# start-slackware-vm.sh - εκκινά VM με Slackware 15.0 LIVE ISO για τα τεστ slackkit.
#
# Γιατί live και όχι εγκατάσταση: η live έκδοση κάνει boot αμέσως (καμία
# διαδραστική εγκατάσταση), τρέχει σε RAM/disposable οπότε τα διστρεπτικά τεστ
# (removepkg, sysctl) δεν χάλαγαν τίποτα, και έχει ΠΡΑΓΜΑΤΙΚΑ slackpkg /
# removepkg / grub-install / sysctl για end-to-end έλεγχο.
#
# Χρήση:
#   ./start-slackware-vm.sh            # live: GUI login (SDDM) + sshd + γνωστός root
#   ROOTPW=xxx ./start-slackware-vm.sh # άλλαξε τον root κωδικό της live
#   BOOT=disk ./start-slackware-vm.sh  # boot από τον εγκατεστημένο δίσκο
#
# Live boot (default): εξάγγελμα kernel+initrd από τη ISO με boot params:
#   * tweaks=ssh   -> ενεργοποιεί το sshd της live (αλλιώς είναι απενεργοποιημένο)
#   * rootpw=...   -> γνωστός root κωδικός (default: tkor)
#   * χωρίς runlevel 3 -> το inittab της live (id:4) φέρνει αυτόματα GUI (SDDM)
# Αν αποτύχει η εξαγωγή (κάποιο εργαλείο λείπει), πέφτει πίσω σε κανονικό
# boot από το ISO menu (console runlevel 3, τυχαίος root κωδικός).
#
# Στοιχεία σύνδεσης (live):
#   * Παράθυρο VM: root / <ROOTPW> ή live / live
#   * SSH από τον host: ssh -p 2222 live@localhost  (κωδ.: live, μετά su -)
#   * Τα scripts είναι στο κοινό share: mount -t 9p -o trans=virtio slackkit /mnt/slackkit
#     και μία εντολή για τα τεστ:
#        bash /mnt/slackkit/vm/run-slackkit-tests.sh        (read-only)
#        bash /mnt/slackkit/vm/run-slackkit-tests.sh full   (+ πραγματικές αλλαγές)
#     Αποτελέσματα στον host: ~/slackkit/vm/test-results.txt

set -euo pipefail

ISO=${ISO:-$HOME/Downloads/slackware64-live-15.0.iso}
BOOT=${BOOT:-cdrom}   # cdrom (live ISO) | disk (εγκατεστημένο σύστημα)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DISK=${DISK:-$SCRIPT_DIR/slackware-live.qcow2}
SHARE_DIR=${SHARE_DIR:-$HOME/slackkit}
SSH_PORT=${SSH_PORT:-2222}
ROOTPW=${ROOTPW:-tkor}
LIVE_APPEND=${LIVE_APPEND:-"kbd=us locale=en_US.utf8 tz=UTC tweaks=ssh rootpw=$ROOTPW"}
CACHE_DIR=${CACHE_DIR:-$SCRIPT_DIR/boot-cache}

CDROM_ARGS=()
KERNEL_ARGS=()

if [ "$BOOT" = "cdrom" ]; then
	[ -f "$ISO" ] || { echo "Δεν βρέθηκε η ISO: $ISO" >&2; exit 1; }
	# Προσπάθεια εξαγωγής kernel+initrd από τη ISO για boot params
	# (gui/sshd/γνωστός root). Αν αποτύχει → κανονικό boot από το ISO menu.
	vmlinuz="$CACHE_DIR/generic"
	initrd="$CACHE_DIR/initrd.img"
	if [ ! -f "$vmlinuz" ] || [ ! -f "$initrd" ] ||
	   [ "$ISO" -nt "$vmlinuz" ]; then
		mkdir -p "$CACHE_DIR"
		echo "εξαγωγή kernel+initrd από τη ISO (μία φορά)..."
		rm -f "$vmlinuz" "$initrd"
		if command -v 7z >/dev/null 2>&1; then
			7z x -y -o"$CACHE_DIR" "$ISO" boot/generic boot/initrd.img >/dev/null 2>&1 || true
		elif command -v bsdtar >/dev/null 2>&1; then
			bsdtar -xf "$ISO" -C "$CACHE_DIR" boot/generic boot/initrd.img 2>/dev/null || true
		elif command -v xorriso >/dev/null 2>&1; then
			xorriso -indev "$ISO" -osirrox on \
				-extract /boot/generic "$vmlinuz" \
				-extract /boot/initrd.img "$initrd" >/dev/null 2>&1 || true
		fi
		# τα 7z/bsdtar κρατούν το εσωτερικό path (boot/...) - κανονικοποίηση:
		[ -f "$CACHE_DIR/boot/generic" ] && mv "$CACHE_DIR/boot/generic" "$vmlinuz"
		[ -f "$CACHE_DIR/boot/initrd.img" ] && mv "$CACHE_DIR/boot/initrd.img" "$initrd"
		rmdir "$CACHE_DIR/boot" 2>/dev/null || true
	fi
	if [ -f "$vmlinuz" ] && [ -f "$initrd" ]; then
		KERNEL_ARGS=(-kernel "$vmlinuz" -initrd "$initrd"
			-append "load_ramdisk=1 prompt_ramdisk=0 rw printk.time=0 $LIVE_APPEND")
		echo "boot: kernel+initrd από ISO με παραμέτρους: $LIVE_APPEND"
	else
		echo "σημείωση: δεν εξάχθηκε kernel (λείπει 7z/bsdtar/xorriso?) -" \
			"κανονικό boot από ISO menu (χωρίς tweaks=ssh/rootpw, console)"
		CDROM_ARGS=(-cdrom "$ISO" -boot d)
	fi
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
	${KERNEL_ARGS[@]+"${KERNEL_ARGS[@]}"} \
	${CDROM_ARGS[@]+"${CDROM_ARGS[@]}"} \
	-virtfs "local,path=$SHARE_DIR,mount_tag=slackkit,security_model=mapped-xattr,id=slackkit" \
	-netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
	-device virtio-net-pci,netdev=net0 \
	-display gtk \
	-name slackkit-slackware-live
