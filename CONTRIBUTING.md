# Contributing

## Where a change belongs

| Your change | Where it goes |
| --- | --- |
| Mac settings, services and boot support that stay installed and run again at updates | Here, in [omacom/omarchy-mac-pkgs](https://github.com/omacom/omarchy-mac-pkgs), against `main` |
| A new Mac-only package | Here: open an issue first, then a pull request that meets the package contract |
| The Mac manual | Here, in the same pull request as the behaviour it describes |
| Release, acceptance or package-resolution tooling | Here, in `tools/` |
| The desktop, shell, bindings or shared helpers | [omacom/omarchy](https://github.com/omacom/omarchy). Apple Silicon desktop work that builds on [#14431](https://github.com/omacom/omarchy/pull/14431) goes to that pull request while it is open. omarchy-mac's `quattro-upstream` is frozen. |
| Package recipes, signing and publication | [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) |
| The macOS app, the Linux image or anything that runs once to install | [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer) |
| A hardware test report | [omarchy-m-testing.org](https://omarchy-m-testing.org) |

The line people most often get wrong is between `omarchy-mac-boot` and the installer. If it is on an installed Mac and runs again when the Mac updates, it belongs in `omarchy-mac-boot`. If it runs once to produce the system, it belongs in the installer.

## Package or upstream?

Omarchy keeps no Mac code of its own. It knows which platform it runs on and gives a platform fixed places to plug in; the Mac packages fill those places. So ask of every change: **does it only mean something on an Apple Silicon Mac?** If so, it belongs in a package here. If Omarchy needs a new place for a platform to plug in, or the fix helps other machines too, it belongs upstream in [omacom/omarchy](https://github.com/omacom/omarchy).

**Upstream, in omacom/omarchy:**

- Platform detection: `omarchy-hw-platform` and the `omarchy-hw-apple-silicon` predicate.
- The places a platform plugs in: the lifecycle dispatch operations (`setup-boot`, `setup-system`, `setup-user`, provisioning, reset, `update-verify`, `update-takeover`, the app install hooks), the platform root `/usr/share/omarchy-platform` and what Omarchy reads from it, the mkinitcpio HOOKS baseline, and the pacman platform guard.
- The default package lists, the Apple Silicon one included: adding or dropping a package every Mac gets by default is an upstream change to `install/omarchy-apple-silicon.packages`.
- Skipping a PC or Intel Mac quirk that misfires on Apple Silicon, behind `omarchy-hw-apple-silicon`.
- Fixes found during Mac work that help every machine, such as the battery, LUKS and keyboard-layout fixes in [#14431](https://github.com/omacom/omarchy/pull/14431), which superseded #13362.

**Here, in the packages:**

- `omarchy-mac`: the files in the platform root (key names, the notch cutouts, display and audio hints, keyrings), the Mac's services (the Wi-Fi backend and resume recovery, microphone mapping, speaker safety), its setup and app hooks, battery charge limits, and the hardware video decode default.
- `omarchy-mac-boot`: the Mac's lifecycle entrypoints and boot chain: the initramfs drop-ins and vendor firmware, in-place encryption, first boot, Limine and U-Boot, update verification, update takeover, factory reset and snapshot restore checks. Moving an existing Mac onto these packages is a standalone migration, not part of either package.

**Some examples:**

| Change | Where |
| --- | --- |
| The built-in keyboard lacks a key Omarchy binds | `omarchy-mac`, as a udev hwdb remap for the built-in keyboard only |
| A bind or gesture behaves wrongly | Upstream, the same on every machine (the Apple SMC lid switch is the one Apple bind core keeps) |
| Wi-Fi drops after resume on one Broadcom chip | `omarchy-mac` |
| A new default package for every Mac | Upstream, in the Apple Silicon package list |
| A PC-only quirk also fires on Macs | Upstream, skipped behind `omarchy-hw-apple-silicon` |
| Encrypted first boot fails on every machine, Macs included | Upstream |
| The Mac's boot chain needs checking after an update | `omarchy-mac-boot`, in its `update-verify` entrypoint |
| The Mac needs to act at a moment Omarchy has no hook for | Both: see below |

**A change that needs both.** First propose the new plug-in point upstream, doing nothing on a platform that doesn't implement it. Then implement it in the package here, with an integration test in `test/integration/` that runs the package against the runtime. Ship the package with or before the Omarchy that uses the new point. If you change one of `omarchy-mac-boot`'s mkinitcpio drop-ins, also update the copies upstream keeps as test fixtures; CI warns when they drift.

## Pull requests

- Open them against `main`. Each needs an approval from someone other than its author, resolved review threads and passing CI.
- Keep a pull request to one change. A change to what the runtime reads from a package (the platform root, lifecycle entrypoints, setup commands) comes with an integration test in `test/integration/`.
- Boot-critical changes need cold-boot evidence from a test Mac before they are released.
- Anything Apple-specific must stay behind the platform detector. A change to installed systems handles the systems it finds, in the package's own setup; moving Macs from the earlier projects is the standalone migration's job.

## Issues

Bugs go to [the issue tracker](https://github.com/omacom/omarchy-mac-pkgs/issues), labelled `package:omarchy-mac`, `package:omarchy-mac-boot` or `desktop`. Installer bugs go to [omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer/issues).

## Releases

- `omarchy-mac` uses semver in its `version` file. Bump it in the pull request that changes behaviour.
- `omarchy-mac-boot` is versioned by the UTC date of the commit its recipe pins; there is nothing to bump.
- A release is tagged per package, `omarchy-mac-v1.2.3` or `omarchy-mac-boot-v20261010`, and tags are never moved.
- Recipes in omacom/omarchy-pkgs pin full commit SHAs. `tools/release/mac-release` opens the pull request that moves them.
