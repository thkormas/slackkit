# slackkit

**All-in-one toolkit for Slackware Linux (stable)** — easy installation,
configuration, speed, and maintenance in one program.

**Status: early development (v0.x)** — this repo is the foundation for a
single CLI that, in its final form, will cover:

- **Installation** — guided install of a usable system: package profiles
  (base, desktop, dev, media), codecs, fonts, printers, services
- **Configuration** — profile-based setup: dotfiles, users, networking,
  desktop environment, hardware (backlight, wifi, power)
- **Speed** — boot and runtime tuning: GRUB timeout, sysctl, service audit,
  CPU governor/power profiles (inspired by the Fedora `speedup` script)
- **Maintenance** — system updates (slackpkg + flatpak), old kernel cleanup,
  GRUB sync, disk hygiene

## What's in here now

### `scripts/slackware_clean_old_kernels_JBs.sh` (v1.1.0)

The first building block — system update + old kernel cleanup + GRUB sync:

1. `slackpkg -batch=on update` + `slackpkg -batch=on upgrade-all`
2. `flatpak update -y` + `flatpak uninstall --unused -y`
3. Re-scan packages (the upgrade may have brought a new kernel), then remove
   every kernel except **the running one + the newest N** (`--keep N`,
   default 1) with `removepkg`, plus `/boot` leftovers
4. Regenerate `grub.cfg` (or run `lilo`) so the menu never points at deleted
   kernels and always shows the new one

Safety: `-n/--dry-run` previews everything without changes, `-y` for
unattended (cron) runs, the running kernel is never removed, and step
failures are counted and reported (non-zero exit) without aborting the rest.

```bash
# preview
sudo ./scripts/slackware_clean_old_kernels_JBs.sh -n

# run interactively
sudo ./scripts/slackware_clean_old_kernels_JBs.sh

# cron: every Sunday, keep 2 kernel versions
0 3 * * 0 /usr/local/bin/slackware_clean_old_kernels_JBs.sh -y --keep 2
```

Flags: `-u/--update` (default on), `--no-update`, `-n/--dry-run`, `-y/--yes`,
`--keep N`, `-h/--help`.

## Testing

The script ships with a mock-based harness (fake `slackpkg`, `flatpak`,
`removepkg`, `grub2-mkconfig`) — no root or real Slackware needed:

```bash
cd scripts && bash test_clean_old_kernels.sh
# == ΣΥΝΟΛΟ: 44 ok, 0 FAIL ==
```

## Roadmap

- [ ] `slackkit` CLI skeleton (subcommands: `install`, `config`, `speed`,
      `maintain`)
- [ ] `maintain`: wrap the kernel/update script as `slackkit maintain`
- [ ] `speed`: GRUB timeout, sysctl tuning, service audit
- [ ] `install`: package profiles + post-install essentials
- [ ] `config`: profile-based dotfiles and hardware setup
- [ ] dry-run everywhere, rollback/safety checks, unified notifications

## License

TBD.
