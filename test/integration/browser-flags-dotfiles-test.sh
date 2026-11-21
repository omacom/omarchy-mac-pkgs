#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# Browser installs through the runtime: omarchy-install-browser's own flags copy,
# then the real omarchy-lifecycle-dispatch into omarchy-mac's post-install hook,
# staged by its install script. A flags file that a dotfiles manager links in stays a link.
require_platform_fixtures "browser installs through lifecycle dispatch"

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
fake_platform "$tmp/apple" "$(runtime_platform aarch64-apple)"
"$MAC/install" "$tmp/package" >/dev/null

# Dispatch runs an entrypoint with an empty environment; the fixture entrypoint
# hands the staged one its root and the faked platform.
lifecycle=$tmp/lifecycle
mkdir -p "$lifecycle/usr/lib/omarchy/mac"
cat >"$lifecycle/usr/lib/omarchy/mac/post-install" <<SH
#!/bin/bash
exec /usr/bin/env OMARCHY_MAC_ROOT="$tmp/package" OMARCHY_PROC_ROOT="$tmp/apple/proc" \\
  PATH="$tmp/apple/bin:$ROOT/bin:/usr/bin:/bin" "$tmp/package/usr/lib/omarchy/mac/post-install" "\$@"
SH
chmod 755 "$lifecycle/usr/lib/omarchy/mac/post-install"
chmod -R go-w "$lifecycle"

# The installer's own flags copy; the extensions and decode steps it also runs
# are the runtime's, and stubbed.
awk '/^copy_chromium_flags\(\) \{/ { copying = 1 } copying { print } copying && /^}/ { exit }' \
  "$ROOT/bin/omarchy-install-browser" >"$tmp/functions"
source "$tmp/functions"
declare -F copy_chromium_flags >/dev/null || fail "omarchy-install-browser defines copy_chromium_flags"
stub_bin=$tmp/bin
mkdir -p "$stub_bin"
for command in omarchy-install-chromium-copy-url omarchy-install-chromium-ytdlp omarchy-install-video-decode; do
  printf '#!/bin/bash\nexit 0\n' >"$stub_bin/$command"
  chmod +x "$stub_bin/$command"
done

unset XDG_CONFIG_HOME XDG_STATE_HOME
export HOME=$tmp/home XDG_RUNTIME_DIR=$tmp/no-session OMARCHY_PATH=$ROOT
export OMARCHY_LIFECYCLE_ROOT=$lifecycle OMARCHY_PROC_ROOT=$tmp/apple/proc PATH=$stub_bin:$tmp/apple/bin:$PATH
install_browser() {
  copy_chromium_flags "$HOME/.config/$1-flags.conf"
  "$ROOT/bin/omarchy-lifecycle-dispatch" post-install "$1" || fail "post-install $1 runs omarchy-mac's user setup"
}
mkdir -p "$HOME/dotfiles" "$HOME/.config"
dotfile=$HOME/dotfiles/brave-flags.conf
: >"$dotfile"
ln -s ../dotfiles/brave-flags.conf "$HOME/.config/brave-flags.conf"
install_browser brave
# The second install edits Brave's flags through the link, which needs no
# write access to the dotfiles directory.
chmod a-w "$HOME/dotfiles"
install_browser chromium
[[ -L $HOME/.config/brave-flags.conf ]] ||
  fail 'a linked flags file stays a link through later browser installs' "$(stat -c %F "$HOME/.config/brave-flags.conf")"
(( $(grep -c -- '^--disable-features=AcceleratedVideoDecoder$' "$dotfile") == 1 )) ||
  fail "the linked flags file's target turns hardware decode off once" "$(cat "$dotfile")"
chromium=$HOME/.config/chromium-flags.conf
[[ -f $chromium && ! -L $chromium ]] && grep -Fxq -- '--disable-features=AcceleratedVideoDecoder' "$chromium" ||
  fail 'a plain flags file is edited in place' "$(cat "$chromium")"
pass 'browser installs keep a dotfiles-linked flags file a link and turn hardware decode off in its target'
