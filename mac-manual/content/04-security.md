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

## Touch ID login

After you explicitly enable Touch ID, its driver starts at each boot and restores the fingerprints already enrolled for Linux. The first login after each boot uses your password, which also unlocks your login keyring if you have one. After that, a stock SDDM login screen accepts Touch ID: submit your username with an empty password and touch the sensor when prompted. This works while your user services from that login are still running, as they are while another session of yours is open and sometimes after you log out. It is not offered while a login keyring of yours is locked. On an encrypted install that logs you in automatically after the disk password, Touch ID therefore works only when you log in again later in a boot, never at the first login screen. Typing your password always works and skips the fingerprint wait. An account that has no password cannot use the SDDM login screen while Touch ID is on. A customized SDDM authentication stack is left for its administrator rather than rewritten, and fingerprint setup carries on without the login screen change.

Fingerprint login does not unlock an encrypted root disk, so keep using the disk password at the early boot prompt. Three rejected fingers count toward the account lockout like wrong passwords, and an accepted finger clears the count. If you change the lockout limits, set up the fingerprint again so the login screen uses the new ones. Turning Touch ID off removes its SDDM authentication include but does not delete the Linux key store. If an administrator has customized the PAM configuration and the include cannot be removed safely, turning Touch ID off still stops the driver loading at the next boot and reports that the PAM configuration needs review.

On the 15-inch M4 Air (J715), Touch ID also requires a compatible kernel and this Mac's own FDR root key and FSC2 calibration. They are private, are not shipped in a package and are not interchangeable with another Mac's files. Setup currently accepts only the 130427-byte calibration size observed working on one reference Mac. Size does not authenticate the file, and other sizes have not been qualified. The earlier J715 port has restored an existing enrollment and completed fingerprint login after a cold boot, but the current upstream kernel still needs its own qualification.

## Changing passwords

Change passwords under _Update > Password_ in the Omarchy menu, as on x86. On a Mac your disk password and your login password start out the same, but each changes on its own: _Drive Encryption_ changes only the disk password, and _User_ only the login password. A disk password change is recorded step by step, so an interruption resumes rather than leaving the disk half changed. If you no longer know your password, see the next section.

## If you forget your password

As on x86, no other key opens the disk: without the password its data cannot be read. Reinstall with the installer app to use the Mac again.

A Mac set up before Omarchy dropped the recovery passphrase keeps it as a second password for the disk. It still unlocks the disk at the prompt, and a password change leaves it as it is, but it no longer offers to set a new password.

## Resetting the Mac for a new owner

_Setup > Reset Computer_ hands a Mac to its next owner, as described in [Security](https://omarchy.org/manual/security/). It works on Macs installed with the installer app. On a Mac it also re-keys the encryption for the next owner, resets the Limine menu and checks the boot files before it activates the clean system. If a check fails, it rolls back and leaves the current system in place.

A clean system expects the kernel it was installed with. When the kernel on the boot partition has moved on since, the reset refuses rather than activating a root that kernel cannot boot.
