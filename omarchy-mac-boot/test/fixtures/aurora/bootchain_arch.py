#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Arch Linux ARM layout for Aurora's shared Stage 2 updater.

bootchain.py is fedora-aurora's packages/update-m1n1/bootchain.py, unchanged.
It owns the DT ABI generation guard, the aura-try trial, the boot-time commit
and the guard. This file only says where Arch keeps things:

- a kernel package installs /usr/lib/modules/<release>/{vmlinuz,dtbs/,dtb-abi}
  and mkinitcpio copies its image to /boot/vmlinuz-<pkgbase>;
- GRUB boots with the device tree U-Boot hands it, so there is no /boot/dtb
  link or /boot/dtb-<release> copy to keep;
- pacman removes packages, so the refusal names `pacman -R`.
"""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

_spec = importlib.util.spec_from_file_location(
    'bootchain', Path(os.environ.get('BOOTCHAIN_MODULE', Path(__file__).with_name('bootchain.py'))))
bootchain = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bootchain)
Refused = bootchain.Refused

# The shared refusal names Fedora's command and its /boot/dtb link.
_DNF = re.compile(r"`sudo dnf remove ((?:'[^']*'(?: |(?=`)))+)`")


class ArchUpdate(bootchain.Update):
    def kernel_images(self):
        modules = {p.parent.name: p for p in self.path('/usr/lib/modules').glob('*/vmlinuz')}
        for version in modules:
            self.validate_version(version)
        pkgbases = set()
        for version in modules:
            pkgbase = self.path(f'/usr/lib/modules/{version}/pkgbase')
            if pkgbase.is_file():
                pkgbases.add(pkgbase.read_text().strip())
        images = dict(modules)
        # GRUB boots every /boot/vmlinuz-<pkgbase> mkinitcpio left there. One
        # whose package is gone has no provable device trees, so it is checked
        # (and refused) like Fedora's orphaned boot entries, never skipped.
        for p in self.path('/boot').glob('vmlinuz-*'):
            name = p.name.removeprefix('vmlinuz-')
            if name not in pkgbases:
                self.validate_version(name)
                images.setdefault(name, p)
        if self.action == 'add':
            images.setdefault(self.version, self.path(f'/usr/lib/modules/{self.version}/vmlinuz'))
        if self.action == 'remove':
            images.pop(self.version, None)
        return images

    def dtb_dir(self, version):
        self.validate_version(version)
        path = self.path(f'/usr/lib/modules/{version}/dtbs')
        if path.is_dir():
            return path
        raise Refused(f'kernel {version} has no DTB directory')

    def plan(self):
        try:
            return super().plan()
        except Refused as error:
            message = str(error)
            if 'sudo dnf remove ' not in message:
                raise
            match = _DNF.search(message)
            if not match:
                raise
            paths = match[1].strip()
            message = (message[:match.start()] + f'`sudo pacman -R $(pacman -Qqo {paths})`' +
                       message[match.end():]).replace('Stage 2 and /boot/dtb are kept', 'Stage 2 is kept')
            raise Refused(message) from None

    def apply(self):
        selected, _source, _own, payload = self.plan()
        target = self.target()
        if target.is_symlink():
            raise Refused('Stage 2 target is a symlink')
        previous = target.read_bytes() if target.exists() else None
        if previous is not None and previous != payload and self.supports_trial():
            self.stage_trial(selected, payload)
        elif previous != payload:
            # Finish and sync the candidate before changing even the backup.
            fd, name = tempfile.mkstemp(prefix=f'.{target.name}.', dir=target.parent)
            staged = Path(name)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fchmod(stream.fileno(), 0o644)
                    os.fsync(stream.fileno())
                if staged.read_bytes() != payload:
                    raise Refused('Stage 2 read-back failed')
                if previous is not None:
                    bootchain.replace_file(target.with_name(target.name + '.old'), previous)
                os.replace(staged, target)
                bootchain.sync_dir(target.parent)
            finally:
                staged.unlink(missing_ok=True)
        print(f'Stage 2 verified at {target}; DTBs from kernel {selected}')


def main():
    parser = bootchain.argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--commit', action='store_true')
    parser.add_argument('--guard', action='store_true')
    args = parser.parse_args()
    try:
        update = ArchUpdate()
        if args.guard:
            update.guard()
        elif args.commit:
            update.commit()
        elif args.check:
            update.plan()
        else:
            update.apply()
    except (Refused, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'update-m1n1: {error}; keeping the last complete Stage 2 and trial evidence', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
