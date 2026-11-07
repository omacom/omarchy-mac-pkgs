---
title: Hardware support
description: Which Macs are supported, what works, the known limitations and how to report a problem.
section: Reference
---

Hardware support is the Asahi Linux project's work, plus what the Aurora kernel adds. Every release is qualified on real Macs before it reaches `rc` or `stable`, and nothing below claims more than has been exercised.

## Supported Macs

A Mac is admitted by its device-tree identifier, never by its marketing name, because one marketing name can cover boards with different hardware. The identifier is what the installer catalog lists and what releases are qualified against. Read yours with:

```bash
cat /proc/device-tree/model
tr '\0' '\n' < /proc/device-tree/compatible
```

In macOS, `sysctl hw.model` shows the model identifier, such as `MacBookPro18,3`.

The first release is qualified on the MacBook Pro 14" M1 Pro (`apple,j314s`) and the MacBook Pro 16" M2 Max (`apple,j416c`). The signed catalog on each channel lists every identifier it admits, and the installer refuses any other Mac before touching the disk. M1 and M2 Macs only: M3, M4 and M5 Macs are not supported.

## Reference machines

| Machine | Role |
| --- | --- |
| MacBook Pro 14" 2021, M1 Pro, `apple,j314s` | Full regression on every release; VM acceptance host |
| MacBook Pro 16" 2023, M2 Max, `apple,j416c` | Multi-display work: five displays through HDMI and USB4. End-to-end installs for installer changes; VM acceptance host |

Boot-critical changes need a cold boot on a test Mac, never only a warm reboot, before a release proceeds. The checklist covers platform identity, desktop and graphics, networking, audio, power and suspend, updates and snapshots.

## What works

This is what the first release is qualified against on both reference Macs. <span class="status ok">works</span> is expected to work on every admitted Mac; <span class="status wip">in progress</span> and <span class="status wip">known issue</span> are tracked.

| Area | Status | Notes |
| --- | --- | --- |
| Apple GPU | <span class="status ok">works</span> | Mesa `vulkan-asahi`, hardware acceleration. A desktop on `llvmpipe` means something is wrong. |
| Internal display, brightness | <span class="status ok">works</span> | The panel includes the strip beside the notch |
| Keyboard, backlight, trackpad | <span class="status ok">works</span> | Drivers loaded early, so they work at the passphrase prompt. The backlight follows the ambient light sensor. See [Keyboard and trackpad]({{page:keyboard}}). |
| Wi-Fi, Bluetooth | <span class="status ok">works</span> | NetworkManager with the iwd backend. Wi-Fi on BCM4378 and BCM4387 chips recovers after resume. Wi-Fi 6E Macs join on 2.4 and 5 GHz: a 6 GHz join passes no traffic with the current firmware. On the MacBook Neo's MT7932, NetworkManager rather than iwd reconnects, so a connect the firmware rejects is retried. |
| Speakers, microphone, headphones | <span class="status ok">works</span> | Asahi's DSP chain with `speakersafetyd` protecting the speakers. The microphone array is mapped, and a headset microphone takes priority when plugged in. If the microphone is still missing 30 s after the session starts, or when an update changes its DSP chain, one restart of the audio session is attempted to bring it back without a reboot. |
| Suspend and resume | <span class="status ok">works</span> | Open the lid or press the power button to wake the Mac. A key press or trackpad click does not wake it: the kernel drivers for the built-in keyboard and trackpad do not register as a wakeup source on M1 or M2 MacBooks. Closed in a bag, it stays asleep. |
| Battery, lid, power profiles | <span class="status ok">works</span> | |
| External displays | <span class="status ok">works</span> | HDMI on models that have it, USB4 and DisplayPort alt-mode through the Aurora kernel. Five displays on the M2 Max. A third and fourth display rely on an aquamarine fix carried until Hyprland releases it. |
| Variable refresh rate, camera (ISP), always-on processor | <span class="status ok">works</span> | Aurora kernel |
| Hardware video decode | <span class="status wip">in progress</span> | VA-API decoding of H.264, HEVC Main and Main10, and VP9 8 and 10-bit, tested on a 13" M1 MacBook Pro; 8-bit H.264, HEVC and VP9 also on a 16" M2 Max with the Aurora kernel. mpv uses it by default for H.264, HEVC and VP9, at about a quarter of the CPU of software decoding at 1080p; `hwdec=no` in `~/.config/mpv/mpv.conf` turns it off. To change the system default, edit `/etc/mpv/mpv.conf` rather than deleting it, since a deleted copy comes back at the next boot. An unedited copy of the earlier default, which lacks `gpu-sw=yes`, is the one exception: setup replaces it with the current default, which lets mpv play on Macs whose GPU has no driver yet. An upgrade alone does not run setup, so on a Mac that already had the earlier default, run `sudo omarchy-mac-setup-system`, or rerun hardware setup, to apply it. Browser acceleration is still open. No hardware encoding. |
| Screen recording | <span class="status ok">works</span> | Encoded on the CPU through `wf-recorder`, because the Apple GPU has no supported hardware video encoder |
| Widevine DRM in browsers | <span class="status ok">works</span> | When the package is available from the Asahi repositories |
| Steam | <span class="status ok">works</span> | Optional, through FEX (`omarchy-steam-fex`) |
| Fullscreen window on a very wide display | <span class="status wip">known issue</span> | Hyprland paints only a band of a fullscreen window on a 5120×1440 output next to a scaled internal display. Upstream Hyprland issue. |
| Fourth external display after HDMI unplug | <span class="status wip">known issue</span> | A stale DisplayPort link on the M2 Max after unplugging HDMI; replug or reboot |
| Text console between Plymouth and the greeter | <span class="status wip">known issue</span> | Cosmetic, a few seconds |

## What Asahi supports on your chip

Everything below the desktop is the Asahi Linux project's work, and the authoritative, current list of what each Apple chip supports is theirs:

- [M1 feature support](https://asahilinux.org/docs/platform/feature-support/m1/)
- [M2 feature support](https://asahilinux.org/docs/platform/feature-support/m2/)
- [Overview across chips](https://asahilinux.org/docs/platform/feature-support/overview/)

### M3 MacBook Air (edge testers)

M3 Macs are not part of the first release. On an M3 MacBook Air, 13-inch or 15-inch, m1n1 hands the built-in display and the GPU to Linux on every boot, as on M1 and M2 Macs, once `pacman -Q m1n1-aurora` reports 1.6.1.aurora21-1 or newer. Nothing in `/etc/m1n1.conf` is needed for that: m1n1 applies these defaults itself.

```
chosen.asahi,t8122-dcp=1
chosen.asahi,t8122-gpu=1
chosen.asahi,t8122-gpu-power-standin=1
chosen.asahi,t8122-gpu-fuse-leakage=1
```

The first line is the display, and the others start the GPU with its power settings. m1n1 starts the GPU only on the macOS GPU firmware it knows, and leaves it off otherwise. Hardware graphics also need the Aurora kernel and Mesa that use it: until both are installed the desktop renders in software, which is slow. An M3 Pro MacBook Pro, 14-inch or 16-inch, gets its built-in display and GPU the same way, from the defaults `chosen.asahi,t6030-dcp=1` and `chosen.asahi,t6030-gpu=1`.

To keep the GPU off, add `chosen.asahi,t8122-gpu=0` to `/etc/m1n1.conf` (`chosen.asahi,t6030-gpu=0` on an M3 Pro); to keep the display with m1n1 too, add `chosen.asahi,t8122-dcp=0` (`chosen.asahi,t6030-dcp=0`). `chosen.asahi,m3-defaults=0` turns all of these defaults off. Then run `sudo update-m1n1` and reboot. Omarchy never changes a line you set. With an older `m1n1-aurora`, 1.6.1.aurora20-4 or newer, Omarchy still adds the four lines above to `/etc/m1n1.conf` at install and at the first update that finds them missing, and adds no GPU lines while the display line is 0 or any `chosen.asahi,t8122-gpu` line of your own is there. Once `m1n1-aurora` 1.6.1.aurora21-1 is installed it removes the lines it added, and keeps any you wrote.

USB-C and DisplayPort external displays stay off on an M3 Air for now, since the display handoff covers only the built-in one. With an older `m1n1-aurora`, 1.6.1.aurora20-3 included, the display line black-screens the Mac at boot. If that happens, remove it from `/etc/m1n1.conf` and run `sudo update-m1n1` again from a shell on this install that doesn't need the display, such as SSH if you set it up beforehand.

Anything marked work in progress there, Thunderbolt device support among them, is work in progress here too. The Aurora kernel adds the display, camera and USB4 work described above.

### Experimental J514C login

The 14-inch M3 Max J514C bring-up remains outside the supported release. On a J514C/T6031 install whose boot loader handed the native display and GPU over, the login manager waits for them before opening the login screen, for up to 30 seconds plus at most 10 seconds for device events to settle. If either device stays unavailable, login still proceeds for diagnosis. This wait runs automatically and needs no enable parameter; it changes no graphics driver setting.

### M5 Pro MacBook Pro 16-inch (bring-up)

The 16-inch MacBook Pro with the M5 Pro (`apple,j716s`, `Mac17,8`, SoC T6050) is not admitted: the installer refuses it, and nothing else on this page applies to it yet. One J716s runs Linux from a bring-up chain outside these packages: m1n1 with T6050 patches, Aurora Silicon's `integration/aurora` kernel (Linux 7.3) with a J716s patch series, and an Arch Linux ARM root with an Omarchy-style Hyprland session. Neither `omarchy-mac` nor `omarchy-mac-boot` has been installed on it yet.

Nothing in the packages is specific to this board, and nothing needs to be. Their Apple matches already cover it: the speaker no-suspend rule takes the jack and speakers of its `AppleJ716` card and leaves its separate `AppleJ716AOP` microphone card alone, the microphone mapper counts that AOP card as the array, the 16-inch notch entry is its panel's size (3456×2234) and applies while the kernel names the panel's connector eDP, which depends on the device tree, the passphrase-prompt backlight rule matches its `kbd_backlight`, the Wi-Fi resume recovery stays off on its N1, and Touch ID reads `unsupported:board`.

Where that machine stood on 7 November 2026. <span class="status ok">works</span> means it works on the bring-up stack, unattended boots included; <span class="status partial">attended only</span> means it has only been run with someone at the machine; <span class="status no">not yet</span> means it doesn't work or hasn't been tried.

| Area | Status | Notes |
| --- | --- | --- |
| CPUs, storage, keyboard and its backlight | <span class="status ok">works</span> | All 18 cores. The storage controller's firmware can take about 3 s to answer, so the kernel waits 10 s for it. |
| Trackpad | <span class="status ok">works</span> | The kernel drives the touch controller's reset. libinput's stock Apple MTP quirk applies; thresholds for this pad haven't been measured. |
| Battery, charger, power off, restart | <span class="status ok">works</span> | The charge limit hasn't been tried; the SMC has its keys. |
| USB-C ports as hosts | <span class="status ok">works</span> | Both ports. Plugging in with the Mac running has only been seen working on the right port. DisplayPort over USB-C hasn't been tried. |
| Wi-Fi and Bluetooth (Apple N1) | <span class="status ok">works</span> | WPA2 on 2.4 and 5 GHz with DHCP, through restarts with the link in use, and a Bluetooth scan. Needs m1n1 to train the N1's PCIe link, kernel patches and Apple's firmware for the board (below). Its firmware lists no 6 GHz channels. Joined with wpa_supplicant: iwd starts once the kernel has its crypto options, but iwd under NetworkManager, the backend `omarchy-mac` sets, hasn't joined a network here. Bluetooth audio can only be A2DP, since the driver carries no SCO. |
| Microphone | <span class="status ok">works</span> | The three-capsule array on the AOP card, through a DSP source in PipeWire. The `omarchy-mac` mapper hasn't run on it. |
| Suspend and resume | <span class="status partial">attended only</span> | Lid close sleeps and lid open wakes, Wi-Fi up or not, with two kernel patches: one ignores the false lid-open report the SMC sends as sleep begins, one keeps the N1's link up through sleep. Not yet repeated on the latest kernel, and power draw while asleep isn't measured. |
| Speakers | <span class="status partial">attended only</span> | All six play cleanly, under a −30 dB ceiling set on the kernel command line, with `speakersafetyd` running a bring-up profile whose thermal values are estimates, and a bring-up DSP graph. Not for everyday use until Asahi's speaker profile and DSP for this board exist. |
| Headphones, headset microphone | <span class="status partial">attended only</span> | With a corrected ALSA UCM profile: the headset sequence in `alsa-ucm-conf-asahi` sets `Jack ADC Preamp Gain`, which this kernel's CS42L84 driver names `Jack ADC Preamp Capture Volume`, so the whole sequence fails without the fix. |
| Internal display | <span class="status ok">works</span> | Through the boot framebuffer, notch rows included. No display driver yet: no brightness control and no external displays. |
| GPU | <span class="status no">not yet</span> | On a test kernel Vulkan runs on the GPU, OpenGL runs through zink and Hyprland starts on it; the everyday desktop still renders in software. |
| Touch ID, camera, Thunderbolt, video decode | <span class="status no">not yet</span> | |

The N1 starts from a firmware image macOS carries for each board and macOS build, and its ROM takes the image only with the board's Image4 manifest, kept beside it, stitched into the image's ticket slot. It is Apple's firmware, so no package ships it, and it must never be copied off one Mac into a package or a bug report. Once the J716s is supported it would arrive as the Broadcom Wi-Fi and trackpad firmware do: asahi-installer copies firmware out of macOS onto the ESP, asahi-fwextract builds the vendor firmware archive `vendorfw/firmware.cpio` from it, and `omarchy-mac-boot` unpacks that archive in the initramfs on every boot. Two pieces are missing: a step in that collection that picks up the N1's image and manifest and writes the stitched file, and a way for the file to reach a driver built into the kernel, which asks for it while PCI devices are first found, before the initramfs unpacks anything. Built as a module, the driver would load after the unpack instead.

## Reporting a problem

Open an issue on [omacom/omarchy-mac-pkgs](https://github.com/omacom/omarchy-mac-pkgs/issues), or on [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer/issues) for the macOS installer app. Include the output of:

```bash
uname -a
cat /proc/device-tree/model
tr '\0' '\n' </proc/device-tree/compatible
omarchy-hw-platform
pacman -Q omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi
pacman-conf --repo-list
```

For an update that stopped, add the update output and `/var/log/pacman.log`. For an installer that stopped, add the app's log folder under `~/Library/Logs/`.

Never post passwords, Wi-Fi credentials, private keys or complete connection profiles.
