#!/bin/bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s %s\n' "$1" "${2:-}" >&2; exit 1; }
# The runtime's Apple predicate over the stubbed detector, which names a Mac
# aarch64-apple, or apple-silicon on a runtime from before the platform rename.
stub_apple_predicate() {
  cat >"$1/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
case $(omarchy-hw-platform) in
  aarch64-apple | apple-silicon) exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$1/omarchy-hw-apple-silicon"
}

# Services with default dependencies require this target even during verification.
# Stage it explicitly so the test never depends on the host's boot units.
stub_systemd_boot_targets() {
  local units=$1/usr/lib/systemd/system
  mkdir -p "$units"
  printf '[Unit]\nDescription=Fixture system initialization\nDefaultDependencies=no\n' >"$units/sysinit.target"
}
