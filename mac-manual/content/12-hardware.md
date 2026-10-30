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

The first release is qualified on the MacBook Pro 14" M1 Pro (`apple,j314s`) and the MacBook Pro 16" M2 Max (`apple,j416c`). The signed catalog on each channel lists every identifier it admits, and the installer refuses any other Mac before touching the disk. M1 and M2 Macs only: M3 and M4 Macs are not supported.

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
| Wi-Fi, Bluetooth | <span class="status ok">works</span> | NetworkManager with the iwd backend. Wi-Fi on BCM4378 and BCM4387 chips recovers after resume. Wi-Fi 6E Macs join on 2.4 and 5 GHz: a 6 GHz join passes no traffic with the current firmware. |
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

## Battery charge limits

Use `omarchy-battery-charge-limit 80` to cap charging, or `omarchy-battery-charge-limit 100` to restore full charging. The saved limit is restored when the battery appears at boot and when an update installs its restore rule on a running Mac. Without a saved limit, installing the rule leaves charging unchanged.
