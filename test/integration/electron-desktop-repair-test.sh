#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
export ROOT
python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(os.environ['ROOT'])
with tempfile.TemporaryDirectory() as tmp:
  tmp = Path(tmp)
  home = tmp / 'home'
  bind = tmp / 'bin'
  bind.mkdir()
  home.mkdir()
  real = tmp / 'real app'
  real.write_text('#!/bin/bash\nexit 0\n')
  real.chmod(0o755)
  compatible = tmp / 'compatible'
  compatible.write_text('apple,j613')
  vendor = tmp / 'vendor.desktop'
  original = f'''# user comment
[Desktop Entry]
Name=My profile
Exec="{real}" --profile-directory="Profile 2" %U
TryExec="{real}"
[Desktop Action private]
Exec={real.as_posix().replace(' ', '-')} --incognito %U
[Desktop Action custom]
Exec=env SPECIAL=yes chromium %U
'''
  vendor.write_text(original)
  env = dict(os.environ, HOME=str(home), OMARCHY_PATH=str(root), PATH=f'{bind}:{root}/bin:' + os.environ['PATH'],
             OMARCHY_ELECTRON_GL_BIND_DIR=str(bind), OMARCHY_CHROMIUM_BIN=str(real),
             OMARCHY_CHROMIUM_DESKTOP=str(vendor), OMARCHY_1PASSWORD_BIN='/absent',
             OMARCHY_CURSOR_BIN='/absent',
             OMARCHY_DRI_PATH=str(tmp / 'dri'))
  apple = bind / 'omarchy-hw-apple-silicon'
  apple.write_text('#!/bin/bash\nexit 0\n')
  apple.chmod(0o755)
  platform = bind / 'omarchy-hw-platform'
  platform.write_text('#!/bin/bash\necho apple-silicon\n')
  platform.chmod(0o755)
  sentinel = tmp / 'forbidden'
  for name in ('sudo', 'pkexec', 'curl'):
    path = bind / name
    path.write_text(f'#!/bin/bash\ntouch "{sentinel}"\nexit 91\n')
    path.chmod(0o755)
  def run(args, status=0):
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    assert result.returncode == status, (args, result.returncode, result.stderr)
    return result
  wrap = str(root / 'bin/omarchy-cmd-electron-gl-wrap')
  # omarchy-mac's user and system halves of the Electron wrapping.
  leaf = '"$MAC/lib/electron-desktop-entries"'
  system = '"$MAC/lib/electron-launchers"'
  if not os.path.exists(wrap):
    # A runtime without the wrapper: both halves skip and change nothing.
    for script in (system, leaf):
      assert 'runtime has no' in run(['bash', '-euo', 'pipefail', '-c', script]).stderr
    assert not sentinel.exists() and not (bind / 'chromium').exists()
    assert not (home / '.local/share/applications').exists()
    print('ok - Electron setup skips a runtime without the wrapper helpers')
    raise SystemExit(0)
  # A runtime with the wrapper but no desktop repair: system setup wraps, user
  # setup leaves the desktop entries alone.
  partial = tmp / 'partial-runtime'
  partial.mkdir()
  for helper in (root / 'bin').iterdir():
    if helper.name != 'omarchy-cmd-desktop-exec-repair':
      (partial / helper.name).symlink_to(helper)
  full_path = env['PATH']
  env['PATH'] = full_path.replace(f'{root}/bin:', f'{partial}:')
  run(['bash', '-euo', 'pipefail', '-c', system])
  assert (bind / 'chromium').exists()
  assert 'runtime has no omarchy-cmd-desktop-exec-repair' in run(['bash', '-euo', 'pipefail', '-c', leaf]).stderr
  assert not (home / '.local/share/applications').exists() and not sentinel.exists()
  env['PATH'] = full_path
  (bind / 'chromium').unlink()
  run([wrap, '--check', 'chromium', str(real)], 4)
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert not sentinel.exists() and not (bind / 'chromium').exists()
  run(['bash', '-euo', 'pipefail', '-c', system])
  run([wrap, '--check', 'chromium', str(real)])
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  desktop = home / '.local/share/applications/chromium.desktop'
  expected = original.replace(f'"{real}"', f'"{bind}/chromium"').replace(f'TryExec="{bind}/chromium"', f'TryExec={bind}/chromium')
  assert desktop.read_text() == expected
  desktop.write_text(original + '# extra customization\n')
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert desktop.read_text() == expected + '# extra customization\n'
  backups = list(desktop.parent.glob('chromium.desktop.bak.*'))
  assert len(backups) == 1 and backups[0].read_text() == original + '# extra customization\n'
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert list(desktop.parent.glob('chromium.desktop.bak.*')) == backups
  desktop.unlink()
  desktop.symlink_to(vendor)
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert desktop.is_symlink() and vendor.read_text() == original
  (bind / 'chromium').write_text('#!/bin/bash\n# administrator launcher\n')
  run([wrap, 'chromium', str(real)], 3)
  run(['bash', '-euo', 'pipefail', '-c', system])
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert not sentinel.exists()
  # An administrator's ordinary Chromium alias must also skip both setup phases.
  (bind / 'chromium').unlink()
  (bind / 'chromium').symlink_to(real)
  binary_before = (real.read_bytes(), real.stat().st_mode)
  for args in ([wrap, 'chromium', str(real)], [wrap, '--check', 'chromium', str(real)]):
    run(args, 3)
  run(['bash', '-euo', 'pipefail', '-c', system])
  run(['bash', '-euo', 'pipefail', '-c', leaf])
  assert (bind / 'chromium').is_symlink() and (bind / 'chromium').readlink() == real
  assert (real.read_bytes(), real.stat().st_mode) == binary_before
  assert not sentinel.exists()
  # Operational failures are not ownership conflicts and must stop the leaf.
  (bind / 'chromium').unlink()
  failure = bind / 'mktemp'
  failure.write_text('#!/bin/bash\nexit 93\n')
  failure.chmod(0o755)
  run(['bash', '-euo', 'pipefail', '-c', system], 93)
  failure.unlink()
  # GLib must accept a valid desktop before and after rewriting a spaced
  # executable path. Parsing the entry never executes its command.
  import ctypes
  gio = ctypes.CDLL('libgio-2.0.so.0')
  gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
  gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
  gio.g_object_unref.argtypes = [ctypes.c_void_p]
  def resolves(path):
    app = gio.g_desktop_app_info_new_from_filename(os.fsencode(path))
    if app:
      gio.g_object_unref(app)
    return bool(app)
  spaced = tmp / 'wrapper directory' / 'chromium'
  spaced.parent.mkdir()
  spaced.write_bytes(real.read_bytes())
  spaced.chmod(0o755)
  valid = tmp / 'valid.desktop'
  valid.write_text(f'[Desktop Entry]\nType=Application\nName=Spaced path\nExec="{real}" %U\nTryExec={real}\n')
  assert resolves(valid), 'native resolver accepts the original unquoted TryExec path'
  repair = str(root / 'bin/omarchy-cmd-desktop-exec-repair')
  run([repair, str(valid), str(vendor), str(spaced), str(real)])
  assert f'TryExec={spaced}\n' in valid.read_text()
  assert resolves(valid), 'native resolver accepts the repaired spaced wrapper path'
  bad = tmp / 'quoted.desktop'
  bad.write_text(valid.read_text().replace(f'TryExec={spaced}', f'TryExec="{spaced}"'))
  assert not resolves(bad), 'quoted TryExec is a rejected negative control'
  run([repair, str(bad), str(vendor), str(spaced), str(real)])
  assert resolves(bad), 'a previously generated quoted wrapper route is repaired too'
print('ok - Electron ownership, user privilege boundary and preserving desktop repair')
PY
