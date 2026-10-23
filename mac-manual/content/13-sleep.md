---
title: Battery and sleep
description: What a closed lid costs on a Mac running Omarchy today, how to see it, and when to shut down instead.
---

Sleep works: close the lid and the Mac suspends, open it and the desktop is back. But asleep, the Mac still draws far more power than it does under macOS, and that is what drains a battery overnight.

## What sleep costs today

Linux on Apple Silicon has one sleep state, suspend-to-idle (`s2idle`): the desktop stops and the CPUs idle, but much of the chip stays powered. On the 14" M1 Pro this draws about 2 W with the lid closed, 3 to 4 % of the battery an hour, so a full battery is flat in about a day. macOS on the same Mac uses a deeper sleep state that the Linux kernel for these Macs does not have yet. Upstream tracks the work in [AsahiLinux/linux#262](https://github.com/AsahiLinux/linux/issues/262).

There is no fallback either:

- No hibernation, so the Mac cannot write memory to disk and power off when the battery runs low.
- No timed wake: the real-time clock has no wake alarm on these Macs, so a sleeping Mac cannot wake itself to shut down.

## Shut down for long unplugged periods

Closing the lid is fine for a meeting or a commute. For anything longer while unplugged, overnight in a bag or a weekend away, shut down instead. A Mac left asleep long enough runs its battery flat and needs a charger before it starts again.

Plugged in, sleep costs nothing from the battery, and leaving the lid closed overnight is fine.

## Seeing what sleep used

Around every sleep, `omarchy-mac` records the battery's stored energy and the time, and keeps one line per sleep in `/var/lib/omarchy-mac/sleep-cost.log`. The time comes from the clock that counts suspended time, checked against the wall clock. A sleep is not counted when a charger was connected, the battery was charging, a reading is missing or the two clocks disagree.

After a counted sleep of half an hour or more, the first unlock shows what it used:

> Suspend used 14.8 Wh over 7.5 h. Overnight suspend can substantially drain this Mac.

Sleeps since the last unlock add up, so a quick look at the lock screen in the morning does not hide the night. To stop the notice, run `systemctl --user mask --now omarchy-sleep-cost.service`. To stop the recording as well, add `NoExtract = usr/lib/systemd/system-sleep/omarchy-mac-sleep-cost` under `[options]` in `/etc/pacman.conf`, delete that file, and the next updates leave it out.

## The power report

`omarchy power report` shows, in one place:

- The battery's charge and the draw now. While a charger is connected, the battery shows no draw, because the charger powers the Mac; unplug it to measure.
- Whether the adapter and each USB-C port are supplying power.
- The kernel, and the power profile. Profiles can be selected, but power-profiles-daemon has no driver for Apple Silicon, so they change nothing.
- Each CPU cluster's frequency range and current limit, and the CPU idle states.
- Whether the power management processor (PMP) driver is bound. The kernel carries it, but it is off unless the device tree enables it.
- The sleep states the kernel offers, and what the last sleep used.
- The processes that used the CPU over a 10-second sample (`--sample` changes it). This is activity, as a share of one core, not power: a process near the top costs battery, but the report cannot say how much.

Attach its output when you [report a problem]({{page:hardware}}#reporting-a-problem) with battery life.
