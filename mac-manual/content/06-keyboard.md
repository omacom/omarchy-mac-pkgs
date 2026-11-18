---
title: Keyboard and trackpad
description: Command as Super, the top row, screenshots without a Print Screen key, the trackpad and the keyboard backlight.
section: Using it
---

On an Apple keyboard, Command is Omarchy's `Super` key, so every binding in [Hotkeys](https://omarchy.org/manual/hotkeys/) works with Command wherever it says Super.

The top row behaves as it does in macOS: press a key on its own for its media function, or hold `Fn` to send F1 to F12.

External keyboards that are not Apple keyboards but use the same driver, such as Keychron boards, keep F1 to F12 first. To put F1 to F12 first on the Mac keyboard too, write `options hid_apple fnmode=2` to `/etc/modprobe.d/hid_apple.conf` and rebuild the boot image the keyboard driver loads from: run `sudo omarchy-mac-boot-update` on a Mac that boots Limine, or `sudo mkinitcpio -P` on an older Mac that still boots GRUB. The setting takes effect at the next boot. Updates keep a setting you made.

## Screenshots and recording

Apple keyboards have no Print Screen key, so Omarchy's `Print` bindings have no key on the built-in keyboard yet. Take screenshots and recordings from the Capture menu, `Command + Ctrl + C`; everything else in [Screenshots & recording](https://omarchy.org/manual/screenshots-recording/) applies as written. Giving the built-in keyboard a Print key is tracked in [omacom/omarchy-mac#683](https://github.com/omacom/omarchy-mac/issues/683).

## Keyboard backlight

On Macs with an ambient light sensor, the keyboard backlight follows the room: lit in the dark, off in bright light. Apple Silicon keyboards have no backlight keys, so Omarchy's keyboard backlight bindings have no key on the built-in keyboard yet; [omacom/omarchy-mac#683](https://github.com/omacom/omarchy-mac/issues/683) tracks giving it some.

## Trackpad

The trackpad follows Omarchy's defaults, as on any other machine. Change scrolling, tap-to-click and gestures in `~/.config/hypr/input.lua`, as [Keyboard, mouse, trackpad](https://omarchy.org/manual/keyboard-mouse-trackpad/) describes. For example, to scroll naturally and click only by pressing the trackpad:

```lua
hl.config({ input = { touchpad = { natural_scroll = true, tap_to_click = false } } })
```

To swipe sideways with three fingers between workspaces, as in macOS, uncomment the `hl.gesture` line for it in that file.
