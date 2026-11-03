#!/bin/bash
set -euo pipefail
package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
bash "$package/install" "$temporary/stage"
mkdir -p "$temporary/bin"
cat > "$temporary/bin/setcap" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CAP_TEST_LOG"
exit "${CAP_TEST_FAIL:-0}"
EOF
printf '#!/bin/bash\necho aarch64-apple\n' > "$temporary/bin/omarchy-hw-platform"
printf '#!/bin/bash\nexit 0\n' > "$temporary/bin/omarchy-hw-apple-silicon"
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH" CAP_TEST_LOG="$temporary/calls"
helper=$temporary/stage/usr/lib/omarchy-mac/hyprland-capabilities
bash "$helper" "$temporary/stage"
[[ ! -e $CAP_TEST_LOG ]]
printf 'test binary\n' > "$temporary/stage/usr/bin/Hyprland"
bash "$helper" "$temporary/stage"
grep -Fxq "cap_sys_nice=ep $temporary/stage/usr/bin/Hyprland" "$CAP_TEST_LOG"
# A package replacement needs the same grant again.
printf 'replacement\n' > "$temporary/stage/usr/bin/Hyprland"
bash "$helper" "$temporary/stage"
[[ $(wc -l < "$CAP_TEST_LOG") -eq 2 ]]
# Initial system setup grants it before any update hook has been read.
printf '#!/bin/bash\nexit 1\n' > "$temporary/stage/usr/lib/omarchy-mac/wifi-supported"
bash "$temporary/stage/usr/bin/omarchy-mac-setup-system" "$temporary/stage"
[[ $(wc -l < "$CAP_TEST_LOG") -eq 3 ]]
if CAP_TEST_FAIL=1 bash "$helper" "$temporary/stage"; then
  echo 'setcap failure was hidden' >&2
  exit 1
fi
[[ $(wc -l < "$CAP_TEST_LOG") -eq 4 ]]
rm "$temporary/stage/usr/bin/Hyprland"
ln -s /bin/true "$temporary/stage/usr/bin/Hyprland"
bash "$helper" "$temporary/stage"
[[ $(wc -l < "$CAP_TEST_LOG") -eq 4 ]]
hook=$temporary/stage/usr/share/libalpm/hooks/90-omarchy-mac-hyprland-capabilities.hook
grep -Fxq 'Target = usr/bin/Hyprland' "$hook"
grep -Fxq 'When = PostTransaction' "$hook"
echo 'PASS Hyprland capability hook and setup helper'
