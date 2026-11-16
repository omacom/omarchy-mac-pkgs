#!/usr/bin/python3
"""Ask Aurora's bootchain_arch.py what update-m1n1 would do, changing nothing.

Usage: aurora-stage2.py plan OUTPUT | marker FILE | attempt SHA [RECEIPT], each after ROOT BOOTCHAIN
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) not in (5, 6) or sys.argv[1] not in ('plan', 'marker', 'attempt'):
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    mode, root, bootchain, argument = sys.argv[1:5]
    try:
        spec = importlib.util.spec_from_file_location('aurora_bootchain_arch', bootchain)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except (OSError, ImportError, SyntaxError) as error:
        print(f'cannot load {bootchain}: {error}', file=sys.stderr)
        return 1
    update_class = getattr(module, 'ArchUpdate', None)
    refused = getattr(module, 'Refused', None)
    if update_class is None or refused is None:
        print(f'{bootchain} has no ArchUpdate to ask', file=sys.stderr)
        return 1
    try:
        update = update_class(root=Path(root))
        if mode == 'plan':
            # The image `update-m1n1 --check` plans, the file name it gets, and its kernel.
            selected, _source, _tree, payload = update.plan()
            target = update.target()
            Path(argument).write_bytes(payload)
            print(f'target={target.name}')
            print(f'kernel={selected}')
        elif mode == 'marker':
            state, path = update.marker(Path(argument))
            print(f'state={state}')
            print(f'path={path}')
        else:
            # Whether update-m1n1 would arm this candidate again, and commit accept RECEIPT.
            path, recorded = update.attempt(argument)
            if recorded is None:
                print('recorded=none')
            else:
                print('recorded=' + ('committed' if recorded.get('result') == 'committed' else 'tried'))
                print(f'record={path}')
            if len(sys.argv) == 6:
                details = json.loads(Path(sys.argv[5]).read_text())
                print('matches=' + ('yes' if recorded == details else 'no'))
    except (refused, OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
