---
title: Install on a Mac
description: Verify the installer, pick a channel and a disk split, and install Omarchy next to macOS.
section: Using it
---

Installation starts in macOS. The installer app downloads the signed Omarchy image for the channel you pick, resizes the APFS container, writes the image and hands over to a first boot that finishes the setup on the Mac itself.

## Before you begin

- Back up macOS and anything you care about. The installer shrinks your macOS volume.
- Check your model on the [Hardware support]({{page:hardware}}) page. The installer refuses any Mac its signed catalog does not list, before it touches the disk, and names the Macs it does support.
- The release carries the macOS system firmware the Omarchy volume boots with, in the versions it knows about. A Mac running a newer macOS than the release knows about cannot install until the release is updated.
- Keep at least 50 GB free on the internal SSD. 100 GB is comfortable.
- Plug in power and use a reliable Internet connection. The image is a multi-gigabyte download.
- Expect model-specific limits around external displays, speakers, cameras and power management.

## Get the installer

The installer is the **Omarchy Installer** app. It needs macOS 15 (Sequoia) or later on an Apple Silicon Mac.

The simplest way to get it is [Homebrew](https://brew.sh):

```bash
brew install omacom/mac/omarchy
```

This installs the app into `/Applications` and opens it. Homebrew prints a deprecation warning about `postflight`, which is expected. `brew upgrade omarchy` updates the app. `brew uninstall --zap omarchy` removes the app, its helper and its support files, but not Omarchy itself: use **Remove Omarchy** in the app for that.

Without Homebrew, download [`Omarchy-Mac-Installer-2.3.15.dmg`](https://github.com/omacom/omarchy-mac-installer/releases/download/v2.3.15/Omarchy-Mac-Installer-2.3.15.dmg) and its [`.dmg.sha256`](https://github.com/omacom/omarchy-mac-installer/releases/download/v2.3.15/Omarchy-Mac-Installer-2.3.15.dmg.sha256) from the [2.3.15 release](https://github.com/omacom/omarchy-mac-installer/releases/tag/v2.3.15), or a newer `Omarchy Installer <version>` release if the [releases page](https://github.com/omacom/omarchy-mac-installer/releases) has one. Every installer release is marked pre-release; ignore the `catalog-*` and `engine-*` releases. Check the download from the folder that holds both files:

```bash
shasum -a 256 -c Omarchy-Mac-Installer-2.3.15.dmg.sha256
```

Then open the disk image and drag **Omarchy Installer** to `/Applications`. The app is signed and notarized; to check it, Gatekeeper must report `Notarized Developer ID`:

```bash
codesign --verify --deep --strict "/Applications/Omarchy Installer.app"
spctl -a -vv -t execute "/Applications/Omarchy Installer.app"
```

## Run the installer

1. Open the app. When it first asks for your macOS administrator password, it adds a privileged helper that performs the disk work.
2. It fetches the signed catalog for the selected channel and checks the catalog signature, the sequence number and the SHA-256 of every file it downloads.
3. The app opens on **Stable** at every launch and always shows the channel it is installing. Choose **RC** in the **Release Channel** menu only if the Mac should take release candidates first; the choice lasts until the app quits. See [Updates and channels]({{page:updates}}).
4. Choose how much space to give Omarchy. The APFS container is shrunk, and four partitions are created: a small APFS stub for the boot object, an EFI system partition, a boot partition and a root partition that fills the space you chose. While this screen is up the app downloads the image in the background, over Wi-Fi or Ethernet only, and changing the split does not restart the download. **Install** stays disabled until the download matches the signed catalog. If the download fails, the strip under the disk split names the check that failed, for example not enough free space or a file that does not match the signed release, and offers **Try again**.
5. Choose whether to encrypt the root file system. Encryption is set up on the first Linux boot and asks for your password on every boot afterwards. See [Encryption and passwords]({{page:security}}).
6. Follow the prompt to complete the boot policy step in recoveryOS. This is Apple's own step and needs your macOS password. The disk is already written when that prompt appears.

The Mac reboots into Omarchy. The [first boot]({{page:install-flow}}) installs Apple's vendor firmware, converts the root to LUKS if you asked for it, creates your account and lands on the desktop.

## When the installer stops

When the Asahi engine stops with an error, the app explains it in plain language: the reason, and whether any disk step had started. The helper keeps the end of the engine's error output, with the machine-owner password and anything shaped like a credential removed, readable only by root, and the app writes its summary to its folder under `~/Library/Logs/`. Attach those when you [report a problem]({{page:hardware}}#reporting-a-problem).

The engine re-checks the approved size against the live disk before it changes anything. When macOS can no longer give up the space you approved, the app says no disk changes were made and offers **Check available space**, which runs the size check again and asks you to approve a fresh split.

A Mac the release does not support is named by model, model identifier and device identifier, and the message lists the Mac families the channel's signed catalog admits.

## Switch between macOS and Omarchy

Hold the power button at startup to pick macOS or Omarchy. In macOS, System Settings → General → Startup Disk sets the default.
