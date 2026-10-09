# Omarchy Mac packages

This repository holds the Apple Silicon add-on packages for Omarchy, the tooling that releases and qualifies them, and the Mac manual. It does not hold the desktop. [README.md](README.md) describes the layout and [CONTRIBUTING.md](CONTRIBUTING.md) says where every other kind of change belongs; send such changes there instead of adding them here.

## Layout

- `omarchy-mac/`, `omarchy-mac-boot/`: one directory per package, each meeting the package contract in the README.
- `test/integration/`: tests that stage more than one package, or a package against the Omarchy runtime.
- `tools/`: release, acceptance, hardware and package-resolution tooling.
- `mac-manual/`: the user manual.

CI rejects files outside these, the root documents and `.github/`.

## Rules

- A package never reads another package's tree, and never reads the runtime's source. Tests that need the runtime take a checkout from `OMARCHY_TEST_RUNTIME` and skip without one; a check that stages two packages belongs in `test/integration/`.
- Run the suite of every package you change, and `test/integration/all` with `OMARCHY_TEST_RUNTIME` set when a change touches what the runtime reads.
- `omarchy-mac-boot` covers what stays installed and runs again at updates. What runs once to install a Mac belongs in omacom/omarchy-mac-installer.
- Change the manual in the same commit as the behaviour it describes.
- A udev `add` action that must reach a device already present also gets a pacman hook that does that work on install and upgrade, since on the upgrade that installs the rule no `add` comes. The hook exits 0 in a chroot or an unbooted root, and never fails the transaction. An `add` that should only run when the device appears, such as one tied to the boot splash, does not.
- An invitation the owner sees only once ships only after everything it leads to is published.

## Tests

- A test passes or fails the same on every machine. It never reads the host's `/usr/share/omarchy-platform`, installed `omarchy-*` commands, `/sys` or running services: stage into a temporary root, point copies at fixtures, and stub external dependencies, keeping the real commands under test. Run `systemd-analyze verify` with `--root` at the staged package. A pass on a Mac with Omarchy installed says nothing about CI.
- When a change adds a detection path or a fallback, test the inverse too: the new path never hides what the old one found.
- A test that needs something the runtime gained at a later commit moves `test/integration/runtime` to that commit; it does not skip because that pin lacks it.
- Before calling a change tested, check that CI ran it: a skipped test, or a job that failed before reaching the tests, is not a pass.

## Style

- Bash scripts start with `#!/bin/bash`, indent two spaces, use `[[ ]]` for string and file tests and `(( ))` for numeric ones. In `[[ ]]`, leave variables unquoted and quote string literals.
- Prefer a full `if`/`else` over relying on `exit` in one branch.
- Use full English names, and keep comments to three lines or fewer; longer reasoning goes in the commit message.
- In Markdown, write full lines without hard wrapping.
- Commits are atomic and their messages say what changed.
