#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Fail-closed Stage 2 updates. Only the shell entry point mounts the ESP.

Kernel packages declare the DT ABI generation their trees use and require.
An older retained generation cannot boot with a newer shared tree generation.
"""
import argparse
import glob
import fnmatch
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


class Refused(RuntimeError):
    pass


class Tree(dict):
    def __init__(self):
        super().__init__()
        self.boards = {}

    def proof(self, board):
        if board is None:
            return dict(self)
        return {name: data for name, data in self.items() if board in self.boards[name]}


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def replace_file(path, data):
    """Same-directory staging; exceptions never expose a partially written file."""
    fd, name = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    staged = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            os.fsync(stream.fileno())
        if hashlib.sha256(staged.read_bytes()).digest() != hashlib.sha256(data).digest():
            raise Refused(f'failed read-back of {staged}')
        os.replace(staged, path)
        sync_dir(path.parent)
    finally:
        staged.unlink(missing_ok=True)


class Update:
    def __init__(self, root=Path('/'), env=None):
        self.root = Path(root)
        self.env = os.environ if env is None else env
        self.action = self.env.get('AURORA_KERNEL_ACTION', 'refresh')
        self.version = self.env.get('AURORA_KERNEL_VERSION', '')
        if self.action not in ('refresh', 'add', 'remove'):
            raise Refused('unknown kernel action')
        if self.action != 'refresh':
            self.validate_version(self.version)

    @staticmethod
    def validate_version(version):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+~-]*', version):
            raise Refused(f'invalid kernel version: {version!r}')

    def path(self, path):
        return self.root / str(path).lstrip('/')

    def compatibles(self):
        path = self.path(self.env.get('AURORA_DEVICE_TREE_COMPATIBLE', '/proc/device-tree/compatible'))
        return [value.decode('ascii') for value in path.read_bytes().split(b'\0') if value] if path.exists() else []

    def board(self):
        values = self.compatibles()
        boards = [value for value in values if re.fullmatch(r'apple,[jk][a-z0-9]+', value)]
        if boards:
            return boards[0]
        if any(value.startswith('apple,') for value in values):
            raise Refused('cannot identify the Apple board')
        return None  # Image builds validate the entire selected set.

    def ctxr_board(self):
        marker = self.path(self.env.get('AURORA_MONITOR_FREE_MARKER', '/usr/share/aura/monitor-free'))
        patterns = ('apple,t81[3-9a-f]?', 'apple,t8[2-9a-f]??',
                    'apple,t60[4-9a-f]?', 'apple,t6[1-9a-f]??')
        if marker.exists() and any(fnmatch.fnmatchcase(value, pattern)
                                   for value in self.compatibles() for pattern in patterns):
            return self.board()
        return None

    def target(self):
        name = self.env.get('TARGET')
        if not name:
            raise Refused('the entry point has not mounted a target ESP')
        target = self.path(name)
        if self.ctxr_board() and target.name == 'boot.bin':
            target = target.with_name('boot-ctxr.bin')
        return target

    def kernel_images(self):
        images = {p.parent.name: p for p in self.path('/usr/lib/modules').glob('*/vmlinuz')}
        for p in self.path('/boot').glob('vmlinuz-*'):
            images.setdefault(p.name.removeprefix('vmlinuz-'), p)
        # BLS entries can retain kernels which no longer have modules. Those
        # must not silently disappear from the compatibility check.
        for p in self.path('/boot/loader/entries').glob('*.conf'):
            fields = dict(line.split(None, 1) for line in p.read_text().splitlines()
                          if len(line.split(None, 1)) == 2 and not line.startswith('#'))
            version = fields.get('version')
            if version:
                self.validate_version(version)
                if version not in images and self.entry_image_gone(fields):
                    # GRUB cannot load this entry's kernel, so no tree has to
                    # suit it. Such entries outlive a kernel removed without
                    # kernel-install, as Asahi kernels were on migration.
                    print(f'update-m1n1: ignoring boot entry {p.name}: its kernel '
                          f'{fields["linux"].strip()} does not exist', file=sys.stderr)
                    continue
                images.setdefault(version, self.path('/boot/vmlinuz-' + version))
        if self.action == 'add':
            images.setdefault(self.version, self.path(f'/usr/lib/modules/{self.version}/vmlinuz'))
        if self.action == 'remove':
            images.pop(self.version, None)
        return images

    def entry_image_gone(self, fields):
        """True when a BLS entry names a kernel that exists nowhere GRUB looks.

        Its `linux` path is relative to the file system holding the entries:
        a separate /boot, or the root with /boot in the path.
        """
        image = fields.get('linux', '').strip()
        if not image:
            return False
        relative = image.lstrip('/')
        return not any(self.path(base + relative).exists() for base in ('/boot/', '/'))

    def dtb_dir(self, version):
        self.validate_version(version)
        for path in (f'/usr/lib/modules/{version}/dtb', f'/boot/dtb-{version}'):
            if self.path(path).is_dir():
                return self.path(path)
        raise Refused(f'kernel {version} has no DTB directory')

    def generation(self, version):
        self.validate_version(version)
        marker = self.path(f'/usr/lib/modules/{version}/dtb-abi')
        try:
            value = marker.read_text(encoding='ascii')
        except FileNotFoundError:
            # Kernels from before the marker share generation 1: declaring it
            # changed no device tree, and they booted the trees that followed.
            return 1
        if not re.fullmatch(r'(0|[1-9][0-9]*)\n?', value):
            raise Refused(f'invalid DT ABI generation for kernel {version} in {marker}')
        return int(value)

    def tree(self, expression):
        directory = Path(expression)
        if directory.is_dir():
            directory = directory / 'apple' if (directory / 'apple').is_dir() else directory
            paths = sorted(set(directory.glob('t6*.dtb')) | set(directory.glob('t81*.dtb')))
        else:
            # Keep the historical whitespace-separated glob configuration.
            paths = []
            for pattern in str(expression).split():
                matched = sorted(map(Path, glob.glob(pattern)))
                if not matched:
                    raise Refused(f'DTB pattern has no matches: {pattern}')
                paths.extend(matched)
        if not paths:
            raise Refused(f'no Apple DTBs in {expression}')
        result = Tree()
        for path in paths:
            data = path.read_bytes()
            validation = subprocess.run(['dtc', '-I', 'dtb', '-O', 'dtb', '-o', os.devnull],
                                        input=data, capture_output=True)
            if validation.returncode or not data:
                raise Refused(f'invalid DTB: {path}')
            compatible = subprocess.check_output(['fdtget', '-t', 's', str(path), '/', 'compatible'],
                                                 stderr=subprocess.DEVNULL, text=True).split()
            boards = [v for v in compatible if re.fullmatch(r'apple,[jk][a-z0-9]+', v)]
            if not boards:
                raise Refused(f'DTB has no Apple board compatible: {path}')
            if path.name in result:
                raise Refused(f'duplicate DTB filename {path.name} in {expression}')
            # A set may contain multiple variants of the same board. Keep
            # every variant and its original filename order, as the vendor
            # updater does, rather than silently selecting a different one.
            result[path.name] = data
            result.boards[path.name] = boards
        return result

    @staticmethod
    def shell_assignments(path):
        values = {}
        if path.is_file():
            for line in path.read_text(errors='replace').splitlines():
                match = re.fullmatch(r'\s*([A-Za-z_][A-Za-z0-9_]*)=(["\']?)(.*?)\2\s*', line)
                if match:
                    values[match[1]] = match[3]
        return values

    def grub_default(self):
        """Return the GRUB default entry id and where it came from, or None.

        custom.cfg is sourced last by grub.cfg, so its `set default=` wins over
        /etc/default/grub and the saved_entry in grubenv.
        """
        for directory in ('/boot/grub2', '/boot/grub'):
            custom = self.path(directory + '/custom.cfg')
            if custom.is_file():
                found = re.findall(r'^\s*set\s+default=(["\']?)([^"\'\s]+)\1\s*$',
                                   custom.read_text(errors='replace'), re.M)
                found = [value for _, value in found if '$' not in value]
                if found:
                    return found[-1], str(custom.relative_to(self.root))
        configured = self.shell_assignments(self.path('/etc/default/grub')).get('GRUB_DEFAULT', 'saved')
        if configured != 'saved':
            return (configured, 'GRUB_DEFAULT') if configured else None
        for name in ('/boot/grub2/grubenv', '/boot/grub/grubenv', '/boot/efi/EFI/fedora/grubenv'):
            entry = self.shell_assignments(self.path(name)).get('saved_entry')
            if entry:
                return entry, 'saved_entry'
        return None

    def default_kernel(self, images, versions):
        """The installed kernel GRUB boots by default, or None if unknown."""
        default = self.grub_default()
        if not default:
            return None
        entry, origin = default
        if re.fullmatch(r'\d+', entry):
            # BLS entries are listed newest first.
            index = int(entry)
            return versions[-1 - index] if index < len(versions) else None
        bls = self.path(f'/boot/loader/entries/{entry}.conf')
        if '/' not in entry and bls.is_file():
            for line in bls.read_text().splitlines():
                key, _, value = line.partition(' ')
                if key == 'version' and value.strip() in images:
                    return value.strip()
        # BLS ids are <machine-id>-<version>; hand-written menu entries in
        # custom.cfg commonly end in the version too.
        matches = [v for v in images if entry == v or entry.endswith('-' + v)]
        if matches:
            return max(matches, key=len)
        print(f'update-m1n1: GRUB default {entry!r} ({origin}) is not an installed kernel; '
              'using the newest kernel, as GRUB does', file=sys.stderr)
        return None

    def select_kernel(self, images, versions):
        newest = versions[-1]
        default = self.default_kernel(images, versions)
        if self.action == 'add':
            pinned = self.grub_default()
            kernel = self.shell_assignments(self.path('/etc/sysconfig/kernel'))
            # Fedora's kernel-install makes a new kernel the saved default
            # unless UPDATEDEFAULT says otherwise; a custom.cfg default stays.
            becomes_default = (kernel.get('UPDATEDEFAULT', 'yes') == 'yes'
                               and not (pinned and pinned[1].endswith('custom.cfg')))
            if becomes_default or default is None:
                return self.version
            selected = default
        else:
            selected = default or newest
        if selected != newest:
            print(f'update-m1n1: composing Stage 2 from the default kernel {selected}, '
                  f'not the newer non-default {newest}', file=sys.stderr)
        return selected

    def plan(self):
        images = self.kernel_images()
        if not images:
            raise Refused('no remaining installed kernels; preserving Stage 2 and /boot/dtb')
        # Match Fedora's version ordering, including its release suffixes.
        versions = subprocess.check_output(['sort', '-V'], input='\n'.join(images), text=True).splitlines()
        selected = self.select_kernel(images, versions)
        source = self.dtb_dir(selected)
        configured = self.env.get('DTBS', '/boot/dtb')
        if not configured.strip():
            raise Refused('DTBS config unset or empty')
        expression = source if configured == '/boot/dtb' else ' '.join(
            str(self.path(pattern)) for pattern in configured.split())
        candidate = self.tree(expression)
        board = self.board()
        proof = candidate.proof(board)
        if not proof:
            raise Refused(f'selected DTBs have no {board}')
        trees = {}
        generations = {version: self.generation(version) for version in images}
        for version, image in images.items():
            if not image.is_file():
                raise Refused(f'kernel image missing for BLS entry {version}')
            try:
                own = self.tree(self.dtb_dir(version))
            except Refused:
                # Fedora's rescue image is a copy of an installed kernel. Use
                # its original tree only when the complete images match.
                if not version.startswith('0-rescue-'):
                    raise
                matches = [v for v, p in images.items() if not v.startswith('0-rescue-')
                           and p.is_file() and p.read_bytes() == image.read_bytes()]
                if not matches:
                    raise Refused(f'rescue kernel {version} has no provable DTB source')
                own = self.tree(self.dtb_dir(matches[0]))
            trees[version] = own
        generation = generations[selected]
        if configured != '/boot/dtb':
            # Custom trees must have a known declaration too. Match the board
            # set to installed trees, rather than guessing an ABI from a path
            # or trusting arbitrary DTBS bytes as the selected kernel's ABI.
            matches = [generations[v] for v, tree in trees.items() if tree.proof(board) == proof]
            if not matches:
                raise Refused('custom DTBS have no installed DT ABI source')
            generation = max(matches)
        self.selected_generation = generation
        older = sorted(v for v in images if generations[v] < generation)
        if older:
            kernels = ', '.join(f'{v} (generation {generations[v]})' for v in older)
            command = 'sudo dnf remove ' + ' '.join(f"'/{images[v].relative_to(self.root)}'" for v in older)
            raise Refused(f'selected DTBs use DT ABI generation {generation}, but retained kernels '
                          f'{kernels} require an older generation. Stage 2 and /boot/dtb are kept. '
                          f'After verifying a working compatible fallback, remove the listed kernels '
                          f'with `{command}` and run `sudo update-m1n1` again. '
                          'No fallback kernel is removed automatically.')
        # An administrator-owned real /boot/dtb must never be replaced.
        link = self.path('/boot/dtb')
        if link.exists() and not link.is_symlink():
            raise Refused('/boot/dtb is not a symlink')
        m1n1 = self.path(self.env.get('M1N1', '/usr/lib64/m1n1/m1n1.bin')).read_bytes()
        uboot = self.path(self.env.get('U_BOOT', '/usr/share/uboot/apple_m1/u-boot-nodtb.bin')).read_bytes()
        if not m1n1 or not uboot:
            raise Refused('empty aura or U-Boot input')
        options = []
        config = self.path(self.env.get('CONFIG', '/etc/m1n1.conf'))
        if config.exists():
            for line in config.read_bytes().splitlines():
                if re.match(rb'^(chosen\.[^=]+|display|mitigations)=', line):
                    options.append(line + b'\n')
        # Deduplicate multi-compatible trees and keep deterministic ordering.
        ctxr = self.ctxr_board()
        blobs = list(dict.fromkeys(candidate[key] for key in sorted(candidate)
                                   if not ctxr or ctxr in candidate.boards[key]))
        payload = m1n1 + b''.join(blobs) + gzip.compress(uboot, mtime=0) + b''.join(options)
        if ctxr and len(payload) > 16 * 1024 * 1024:
            raise Refused('CTXR Stage 2 exceeds the 16 MiB slot; keeping the working images')
        return selected, source, trees[selected], payload

    def chosen(self, name):
        path = self.path('/proc/device-tree/chosen') / name
        return path.read_bytes().rstrip(b'\0').decode('ascii') if path.exists() else ''

    def supports_trial(self):
        # The aura property is authoritative when present. A stock m1n1
        # version (such as 1.6.1) does not imply aura-try support.
        if self.board() is None:
            return False
        aura_version = self.chosen('aura,stage1-version')
        version = aura_version or self.chosen('asahi,m1n1-stage1-version')
        match = re.fullmatch(r'(?:aura[- v]?)?v?(\d+)\.(\d+)\.(\d+)(?:b(\d+))?(?:-(?:[0-9]+-)?g[0-9a-f]+)?(?:-dirty)?', version)
        if not match or (match[4] is None and not aura_version and
                         not version.startswith(('aura', '1.0.0', 'v1.0.0'))):
            return False
        release = tuple(map(int, match.group(1, 2, 3)))
        return release > (1, 0, 0) or (release == (1, 0, 0) and
                                                   (match[4] is None or int(match[4]) >= 4))

    def check_esp(self):
        device = self.env.get('ESP_DEVICE', '')
        if (self.env.get('ESP_FSTYPE') != 'vfat' or not device or
                not stat.S_ISBLK(os.stat(device).st_mode)):
            raise Refused('aura-try requires a mounted block-device FAT ESP')

    def trial_paths(self):
        self.check_esp()
        target = self.target()
        esp = self.path(self.env['ESP_ROOT'])
        # Resolve parent components too, so a configured symlink cannot escape
        # the mounted ESP. Never follow a final candidate/marker symlink.
        if target.is_symlink() or target.parent.resolve() != target.parent:
            raise Refused('Stage 2 target must not contain symlinks')
        relative = target.relative_to(esp).as_posix() + '.next'
        if not re.fullmatch(r'[A-Za-z0-9_./-]+', relative) or any(
                part in ('', '.', '..') for part in relative.split('/')) or len(relative) >= 128:
            raise Refused('invalid ESP-relative trial path')
        candidate = target.with_name(target.name + '.next')
        receipt = target.with_name(target.name + '.next.json')
        marker = esp / 'aura-try'
        for path in (candidate, receipt, marker):
            if path.is_symlink():
                raise Refused(f'trial file is a symlink: {path}')
        return target, candidate, receipt, marker, relative

    def flush_esp(self):
        os.sync()
        subprocess.run(['blockdev', '--flushbufs', self.env['ESP_DEVICE']], check=True)

    def marker(self, path):
        if not path.exists():
            return None
        fields = path.read_bytes().split(b'\n')
        if len(fields) != 3 or fields[0] not in (b'armed', b'spent') or fields[2]:
            raise Refused('unrecognized aura-try marker; preserving it')
        return fields[0].decode(), fields[1].decode('ascii')

    def attempts(self):
        return self.path('/var/lib/aurora-stage2/attempts')

    def attempt(self, digest):
        """Return the path and record of this candidate's automatic attempt.

        Attempts are keyed by the candidate's SHA-256, so an aura, U-Boot,
        m1n1.conf or DTB change gets its own trial even for the same kernel.
        Records from 20261107-1 are named after the kernel version; they still
        count for the candidate whose hash they contain.
        """
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise Refused('invalid Stage 2 candidate sha256')
        path = self.attempts() / digest
        if path.exists():
            return path, json.loads(path.read_text())
        if self.attempts().is_dir():
            for legacy in sorted(self.attempts().iterdir()):
                if legacy.name.startswith('.') or re.fullmatch(r'[0-9a-f]{64}', legacy.name):
                    continue
                details = json.loads(legacy.read_text())
                if not isinstance(details, dict):
                    raise Refused(f'unrecognized Stage 2 attempt record {legacy}')
                if details.get('sha256') == digest:
                    return legacy, details
        return path, None

    def trial_running(self, current):
        """True while this boot is a trial that can still commit.

        The aurora,trial property lasts for the whole boot, but only the spent
        marker lets commit() publish the booted candidate, and commit removes
        it. Without a spent marker a trial boot stages like an ordinary boot.
        An armed marker was written after this boot's commit; the ownership,
        attempt and armed checks apply to it.
        """
        return bool(self.chosen('aurora,trial')) and current is not None and current[0] == 'spent'

    def verify_stage2(self, payload, offset):
        """Traverse the composed FDT records, including the ESP read-back."""
        board = self.board()
        if board is None:
            raise Refused('trial staging requires this Mac\'s live compatible')
        live = self.path('/proc/device-tree/aliases')
        required = [name for name in ('dcp', 'disp0') if (live / name).exists()]
        matched = False
        count = 0
        while payload[offset:offset + 4] == b'\xd0\x0d\xfe\xed':
            header = payload[offset:offset + 40]
            if len(header) != 40:
                raise Refused('truncated Stage 2 DTB header')
            size = int.from_bytes(header[4:8], 'big')
            if size < 40 or offset + size > len(payload):
                raise Refused('invalid Stage 2 DTB size')
            blob = payload[offset:offset + size]
            check = subprocess.run(['dtc', '-I', 'dtb', '-O', 'dtb', '-o', os.devnull],
                                   input=blob, capture_output=True)
            if check.returncode:
                raise Refused('invalid Stage 2 DTB structure')
            with tempfile.NamedTemporaryFile(suffix='.dtb') as stream:
                stream.write(blob)
                stream.flush()
                compatible = subprocess.check_output(
                    ['fdtget', '-t', 's', stream.name, '/', 'compatible'], text=True).split()
                if board in compatible:
                    for alias in required:
                        found = subprocess.run(['fdtget', '-t', 's', stream.name, '/aliases', alias],
                                               capture_output=True, text=True)
                        node = found.stdout.strip()
                        if found.returncode or not node.startswith('/'):
                            raise Refused(f'{board} DTB lacks display alias {alias}')
                        exists = subprocess.run(['fdtget', '-p', stream.name, node], capture_output=True)
                        if exists.returncode:
                            raise Refused(f'{board} DTB display alias {alias} has no node')
                    matched = True
            offset += size
            count += 1
        if not matched or not count or payload[offset:offset + 2] != b'\x1f\x8b':
            raise Refused(f'Stage 2 lacks complete DTBs for {board} or compressed U-Boot')

    def stage_trial(self, selected, payload):
        target, candidate, receipt, marker, relative = self.trial_paths()
        current = self.marker(marker)
        if self.trial_running(current):
            raise Refused('a trial is running; preserve its candidate until the next boot')
        if current and current[1] != relative:
            raise Refused('another aura-try owns the ESP marker')
        digest = hashlib.sha256(payload).hexdigest()
        attempt, recorded = self.attempt(digest)
        # Only a committed candidate may be tried again, e.g. after a package
        # revert. One that fell back or was interrupted is never rearmed.
        if recorded is not None and recorded.get('result') != 'committed':
            print(f'Stage 2 trial already attempted for candidate {digest} '
                  f'(kernel {recorded.get("kernel")}); not rearming')
            return
        attempt = self.attempts() / digest
        if current and current[0] == 'armed':
            raise Refused('a Stage 2 trial is already armed')
        offset = len(self.path(self.env.get('M1N1', '/usr/lib64/m1n1/m1n1.bin')).read_bytes())
        self.verify_stage2(payload, offset)
        if candidate.exists():
            # Keep the previous trial evidence when a newer kernel is staged.
            suffix = hashlib.sha256(candidate.read_bytes()).hexdigest()
            replace_file(target.with_name(target.name + '.failed-' + suffix), candidate.read_bytes())
            if receipt.exists():
                replace_file(target.with_name(target.name + '.failed-' + suffix + '.json'), receipt.read_bytes())
        replace_file(candidate, payload)
        self.verify_stage2(candidate.read_bytes(), offset)
        details = {'kernel': selected, 'path': relative, 'sha256': hashlib.sha256(payload).hexdigest(),
                   'dtb_offset': offset, 'generation': self.selected_generation}
        replace_file(receipt, (json.dumps(details, sort_keys=True) + '\n').encode())
        # Persist before arming. An interrupted update must never automatically
        # grant this kernel another attempt. Marker is always the last write.
        attempt.parent.mkdir(parents=True, exist_ok=True)
        sync_dir(attempt.parent.parent)
        replace_file(attempt, (json.dumps(details, sort_keys=True) + '\n').encode())
        self.flush_esp()
        temporary = marker.with_name(marker.name + '.tmp')
        if temporary.is_symlink():
            raise Refused('aura-try.tmp is a symlink')
        replace_file(temporary, f'armed\n{relative}\n'.encode())
        os.replace(temporary, marker)
        sync_dir(marker.parent)
        self.flush_esp()
        print(f'Stage 2 trial armed for kernel {selected} at {relative}, sha256 {digest}; live image kept')

    def sanity(self):
        source = subprocess.check_output(['findmnt', '-nro', 'SOURCE', '--target', '/'], text=True).strip()
        devices = subprocess.check_output(['lsblk', '-snro', 'KNAME', source.split('[')[0]], text=True).split()
        if not any(re.fullmatch(r'nvme\d+n\d+(?:p\d+)?', name) for name in devices):
            raise Refused('root is not mounted on NVMe')
        deferred = self.path('/sys/kernel/debug/devices_deferred')
        # Absence of debugfs cannot prove that DT-described devices probed.
        for line in deferred.read_text().splitlines():
            if not line.strip():
                continue
            name = line.split()[0]
            if '/' in name or name in ('.', '..'):
                raise Refused('unrecognized deferred device name')
            if any(self.path('/sys/bus').glob(f'*/devices/{name}/of_node')):
                raise Refused(f'DT device still deferred: {name}')
        tree = self.path('/proc/device-tree')
        devices = list(self.path('/sys/bus/platform/devices').glob('*/of_node'))
        for compatible in tree.rglob('compatible'):
            values = compatible.read_bytes().split(b'\0')
            if not any(re.fullmatch(rb'apple,(?:[a-z0-9]+-)?dcp(?:ext)?', value) for value in values):
                continue
            node = compatible.parent
            ancestors = [node] + list(node.parents)[:len(node.relative_to(tree).parts) - 1]
            if any((p / 'status').exists() and (p / 'status').read_bytes().rstrip(b'\0')
                   not in (b'ok', b'okay') for p in ancestors):
                continue
            bound = [p for p in devices if p.resolve() == node.resolve()]
            if not bound or not all((p.parent / 'driver').is_dir() for p in bound):
                raise Refused(f'DCP is not bound: {node.relative_to(tree)}')

    def guard(self):
        # Keep the one-shot fallback even if Linux feeds the hardware watchdog
        # but never reaches the commit service or fails its DT checks.
        _, _, _, marker, relative = self.trial_paths()
        if self.chosen('aurora,trial') == relative and self.marker(marker) == ('spent', relative):
            print(f'aurora-stage2-guard: trial {relative} was not committed; rebooting to the configured Stage 2', flush=True)
            subprocess.run(['systemctl', '--no-block', 'reboot'], check=True)

    def commit(self):
        target, candidate, receipt, marker, relative = self.trial_paths()
        current = self.marker(marker)
        trial = self.chosen('aurora,trial')
        if not current:
            return
        if current[1] != relative:
            # A trial armed by hand with aura-try (or by another tool) is not
            # this updater's to commit: leave its marker and image alone.
            print(f'aurora-stage2-commit: the aura-try marker names {current[1]}, not {relative}; '
                  'that trial is not managed here, nothing to commit')
            return
        if current[0] == 'spent' and not trial:
            print(f'aurora-stage2-commit: trial {relative} fell back; live Stage 2 kept, candidate left for inspection')
            return
        if current != ('spent', relative) or trial != relative:
            return
        details = json.loads(receipt.read_text())
        self.validate_version(details['kernel'])
        attempt, recorded = self.attempt(details['sha256'])
        if recorded != details or details['path'] != relative:
            raise Refused('trial receipt does not match its recorded attempt')
        payload = candidate.read_bytes()
        if hashlib.sha256(payload).hexdigest() != details['sha256']:
            raise Refused('trial candidate changed since it was armed')
        self.verify_stage2(payload, details['dtb_offset'])
        older = [version for version in self.kernel_images()
                 if self.generation(version) < details['generation']]
        if older:
            raise Refused('retained kernels now require an older DT ABI generation: ' + ', '.join(sorted(older)))
        self.sanity()
        previous = target.read_bytes()
        replace_file(target.with_name(target.name + '.prev'), previous)
        self.flush_esp()
        try:
            # Same-directory rename publishes exactly the verified trial file.
            os.replace(candidate, target)
            sync_dir(target.parent)
            self.flush_esp()
            if hashlib.sha256(target.read_bytes()).hexdigest() != details['sha256']:
                raise Refused('committed Stage 2 read-back sha256 mismatch')
        except (OSError, Refused, subprocess.SubprocessError):
            if not candidate.exists():
                replace_file(candidate, payload)
            replace_file(target, previous)
            self.flush_esp()
            raise
        marker.unlink()
        sync_dir(marker.parent)
        self.flush_esp()
        print(f'aurora-stage2-commit: committed {relative}, sha256 {details["sha256"]}; backup {target.name}.prev')
        # The marker removal above is the commit. Recording the result lets a
        # later update try this exact candidate again; failing to record it
        # only keeps that candidate from another automatic trial.
        try:
            committed = self.attempts() / details['sha256']
            replace_file(committed, (json.dumps(dict(details, result='committed'), sort_keys=True) + '\n').encode())
            if attempt != committed:
                attempt.unlink()
                sync_dir(attempt.parent)
        except OSError as error:
            print(f'aurora-stage2-commit: could not record the committed attempt: {error}')

    def sign(self, payload):
        """Hand the composed Stage 2 to aurora-secboot ("stage2 hook"), which signs it with the
        owner's Stage 2 key when Stage 2 signing is on and returns it unchanged otherwise. A Stage 1
        that enforces signatures refuses an unsigned Stage 2, so a failure keeps the last one."""
        signer = self.path(self.env.get('AURORA_STAGE2_SIGNER', '/usr/bin/aurora-secboot'))
        if not signer.is_file():
            return payload
        with tempfile.TemporaryDirectory(prefix='aurora-stage2-sign.') as work:
            source, signed = Path(work) / 'stage2', Path(work) / 'stage2.signed'
            source.write_bytes(payload)
            result = subprocess.run([str(signer), 'stage2', 'hook', str(source), str(signed)],
                                    capture_output=True, text=True)
            if result.returncode:
                detail = (result.stderr or result.stdout).strip().splitlines()
                raise Refused('Stage 2 signing failed: ' + (detail[-1] if detail else f'exit {result.returncode}'))
            output = signed.read_bytes()
        # Signing only appends a trailer; the composed image itself stays as built.
        if output[:len(payload)] != payload:
            raise Refused('the Stage 2 signer changed the composed image')
        if self.ctxr_board() and len(output) > 16 * 1024 * 1024:
            raise Refused('signed CTXR Stage 2 exceeds the 16 MiB slot; keeping the working images')
        for line in result.stdout.splitlines():
            print(line)
        return output

    def apply(self):
        selected, source, own, payload = self.plan()
        payload = self.sign(payload)
        target = self.target()
        if target.is_symlink():
            raise Refused('Stage 2 target is a symlink')
        # Make the versioned boot DTB directory complete before exposing it.
        destination = self.path(f'/boot/dtb-{selected}')
        if destination.exists():
            if self.tree(destination) != own:
                raise Refused(f'{destination} differs from the installed kernel DTBs')
        else:
            staged = Path(tempfile.mkdtemp(prefix='.dtb-', dir=self.path('/boot')))
            try:
                for p in source.iterdir():
                    if p.is_dir():
                        shutil.copytree(p, staged / p.name)
                    else:
                        shutil.copy2(p, staged / p.name)
                for p in staged.rglob('*'):
                    if p.is_file():
                        with p.open('rb') as stream:
                            os.fsync(stream.fileno())
                for p in sorted((p for p in staged.rglob('*') if p.is_dir()), reverse=True):
                    sync_dir(p)
                sync_dir(staged)
                os.rename(staged, destination)
                sync_dir(destination.parent)
            finally:
                if staged.exists():
                    shutil.rmtree(staged)
        previous = target.read_bytes() if target.exists() else None
        if previous is not None and previous != payload and self.supports_trial():
            self.stage_trial(selected, payload)
        elif previous != payload:
            # Finish and sync the candidate before changing even the backup.
            fd, name = tempfile.mkstemp(prefix='.boot.bin.', dir=target.parent)
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
                    replace_file(target.with_name(target.name + '.old'), previous)
                os.replace(staged, target)
                sync_dir(target.parent)
            finally:
                staged.unlink(missing_ok=True)
        link = self.path('/boot/dtb')
        if self.env.get('AURORA_FIRMWARE_DT') == 'True':
            # Preserve grubby's firmware-DT policy, but defer link removal
            # until the complete Stage 2 has been durably staged.
            if link.is_symlink():
                link.unlink()
                sync_dir(link.parent)
            print(f'Stage 2 verified at {target}; firmware DT policy retained')
            return
        if not link.is_symlink() or os.readlink(link) != destination.name:
            fd, name = tempfile.mkstemp(prefix='.dtb-link-', dir=link.parent)
            os.close(fd)
            temporary = Path(name)
            temporary.unlink()
            try:
                temporary.symlink_to(destination.name)
                os.replace(temporary, link)
                sync_dir(link.parent)
            finally:
                temporary.unlink(missing_ok=True)
        print(f'Stage 2 verified at {target}; /boot/dtb -> {destination.name}')

    def cleanup_remove(self):
        if self.action != 'remove':
            raise Refused('erase cleanup requires a remove action')
        link = self.path('/boot/dtb')
        if link.is_symlink() and os.readlink(link) in (
                f'dtb-{self.version}', f'/boot/dtb-{self.version}'):
            link.unlink()
            sync_dir(link.parent)
        print('Stage 2 refresh deferred; continuing removal of the erased kernel boot files')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--commit', action='store_true')
    parser.add_argument('--guard', action='store_true')
    parser.add_argument('--cleanup-remove', action='store_true')
    args = parser.parse_args()
    try:
        update = Update()
        if args.guard:
            update.guard()
        elif args.commit:
            update.commit()
        elif args.cleanup_remove:
            update.cleanup_remove()
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
