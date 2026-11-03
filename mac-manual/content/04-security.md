---
title: Encryption and passwords
description: Disk encryption on a Mac, the first-boot re-key, password changes, a forgotten password and resetting a Mac.
section: Using it
---

Encryption on a Mac is chosen in the installer and carried out on the Mac's first boot. The result is the same LUKS root an x86 Omarchy install has, unlocked with your own password. [Security](https://omarchy.org/manual/security/) in the Omarchy manual covers the rest.

## Turning it on

Choose encryption in the installer. The image is written unencrypted, with a temporary install key for the first boot. On that boot, from the initramfs and before the root is mounted, the root file system is converted to LUKS in place: it is shrunk, re-encrypted and its boot entries and initramfs are rebuilt to unlock it. The conversion keeps a recovery journal on the boot partition, so an interrupted conversion can be picked up again.

A Mac that was not asked to encrypt is never touched. The conversion needs a marker the installer writes and refuses to run without it.

## First boot: your password

Owner provisioning then asks for your name and password, as on x86. On an encrypted Mac it also makes your password the disk password and removes the temporary install key, so no key from the image can unlock your disk. As on x86, that one password unlocks the disk and logs in your account and root; there is no separate recovery key.

The next boot unlocks the disk with your password. At the prompt the built-in keyboard and trackpad work, because their drivers are loaded early in the initramfs. A Bluetooth keyboard does not, just as on x86: use the built-in keyboard or a wired one.

## Changing passwords

Change passwords under _Update > Password_ in the Omarchy menu, as on x86. On a Mac your disk password and your login password start out the same, but each changes on its own: _Drive Encryption_ changes only the disk password, and _User_ only the login password. A disk password change is recorded step by step, so an interruption resumes rather than leaving the disk half changed. If you no longer know your password, see the next section.

## If you forget your password

As on x86, no other key opens the disk: without the password its data cannot be read. Reinstall with the installer app to use the Mac again.

A Mac set up before Omarchy dropped the recovery passphrase keeps it as a second password for the disk. It still unlocks the disk at the prompt, and a password change leaves it as it is, but it no longer offers to set a new password.

## Turning on Touch ID

Touch ID on Linux is experimental and can be unstable. It shares the Secure Enclave with macOS, so back up any data on your macOS partition before you turn it on. Fingerprint setup under _Setup > Security > Fingerprint_ asks first, and saying no leaves Touch ID off. The choice applies to every user on the Mac and needs an administrator.

Turning it on loads the Secure Enclave driver and creates a key store for Linux, or uses the one an earlier setup created. In normal use the enclave advances its anti-replay state, which only moves forward. Linux and macOS share that state: it is one file in the Mac's iBoot System Container, and both systems update it.

If a bug ever writes that shared state wrongly, the enclave stops accepting it and macOS can lose data:

- With FileVault on, macOS can't unlock its disk and won't start, and the startup picker may not open. Getting the Mac back takes a DFU restore, which erases it.
- With FileVault off, macOS resets its keychain and Touch ID fingerprints and shows a warning.

On a MacBook Neo, setup also reads the sensor's key from the factory records the installer left on the boot partition, into a firmware file only root can read. Turning Touch ID off deletes that file.

Turning Touch ID off later removes your fingerprints and stops the driver loading. The key store stays.

## Resetting the Mac for a new owner

_Setup > Reset Computer_ hands a Mac to its next owner, as described in [Security](https://omarchy.org/manual/security/). It works on Macs installed with the installer app. On a Mac it also re-keys the encryption for the next owner, resets the Limine menu and checks the boot files before it activates the clean system. If a check fails, it rolls back and leaves the current system in place.

A clean system expects the kernel it was installed with. When the kernel on the boot partition has moved on since, the reset refuses rather than activating a root that kernel cannot boot.

### Reusing an existing J613 identity

For an administrator migrating a working J613 installation, `/usr/lib/omarchy-mac/touchid-enable --existing` records consent and loads the existing bag with provisioning disabled. This is separate from fingerprint setup: do not enrol again. It requires the installed calibration, six existing state records and the ownership journal. It never copies state or carves calibration. An already loaded driver requires a cold boot before adoption. The candidate kernel must support the `trusted_keys` and `filevault_api` options; older kernels refuse those options. Normal first-time setup is unchanged.

Two Linux roots must use the same current SEP records and fprint directory before either can load the driver. Snapshots are not state backups: never replace a current host store with an older root's copy. Mount the authoritative state globally before the load and activation units; a service-only mount namespace does not redirect the kernel's file opens. A missing shared mount must block both activation and fprintd. Do not reset keys or use enrolment to repair a migration.

The driver need not publish its load parameters under `/sys/module/apple_sep/parameters`. `touchid-policy` reports the selected policy from cached `diag/policy` when available, or the existing xART diagnostics and current-boot decision messages. Missing fields are reported as unobserved, not a failed load. The report distinguishes configured values from active evidence and never prints the preboot identity or saved state. A positive contradictory readback needs correction and a cold boot, not a module reload.

Administrators with shared state can install a root-owned, executable `/etc/omarchy-mac/touchid-statecheck`. The package runs it before loading and activation, and in `omarchy-mac-touchid-statecheck.service` before fprintd. Install the site's mount dependencies on this unsandboxed service; do not add the check as an ExecStartPre inside fprintd. Its read-only/private mount view can legitimately differ from the global namespace the kernel uses. The one-shot service runs again when fprintd starts. Mount changes while SEP is loaded require a cold boot; a completed admission check does not monitor mount health.

Touch ID activation and fingerprint authentication require successful driver policy admission. A rejected policy blocks both services, including activation requested when the device appears.
