---
title: Snapshots and recovery
description: Snapshots in the Limine menu, restoring one, and what a snapshot does not cover on a Mac.
section: Using it
---

Snapshots work as they do on x86 Omarchy, described in [System snapshots](https://omarchy.org/manual/system-snapshots/): `omarchy update` takes one before every package sync, `omarchy-snapshot create` takes one by hand, and the Limine boot menu lists them.

## Booting and restoring a snapshot

1. Restart and pick the snapshot in the Limine menu by its date and Omarchy version.
2. Once it is up, click the notification to restore it, or run `omarchy-snapshot restore`.

Restore from the snapshot you booted: run from the current system, the restore tells you to boot the snapshot first. If you pick a different snapshot from the restore's own list instead, it's checked after the restore. When it doesn't match, you're told not to reboot. Run `omarchy-snapshot restore` again and pick the backup that restore made to put the previous root back. A snapshot holds the root file system, not `/home`, so it undoes a broken update but does not bring back lost files.

Snapshots taken before Limine was activated on your Mac can't be restored. Limine saved no kernel for most of them, so they aren't in the menu, and one that is gets refused. `limine-snapper-list` shows the snapshots the menu offers.

## What a snapshot does not hold on a Mac

Part of what boots a Mac lives outside the root file system: the kernel and initramfs on the boot partition, Limine on the EFI system partition, and m1n1, U-Boot and the device trees. A snapshot does not hold those.

A snapshot from before a kernel, m1n1, U-Boot or Limine update can still be restored. You just booted it from the Limine menu with the boot firmware that's on your Mac now, so the restore keeps that firmware and puts the snapshot's kernel and initramfs on the boot partition. It checks what the next boot reads before it offers the reboot. Your next `omarchy update` rebuilds m1n1, the device trees, U-Boot and Limine from the installed packages. If the kernel you're running doesn't belong to the snapshot's own packages, the restore is refused and the message says why.

The check runs from the snapshot you booted, so a snapshot taken before your Mac had this version follows the rules of the version it holds. It may refuse the restore, or restore unchecked, so compare its packages with the current ones first.

A Mac that still boots GRUB, from before the move to Limine, has no snapshot menu, and Omarchy has no other way to restore a snapshot there. The move to Limine makes later snapshots restorable.

## The boot menu stays

Limine always sits in front of Omarchy on a Mac. _Setup > Direct Boot_ refuses to run on Apple firmware, so the snapshot menu is always one restart away.

To reach macOS instead, hold the power button at startup. In macOS, System Settings → General → Startup Disk sets the default.
