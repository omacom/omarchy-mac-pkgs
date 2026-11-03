#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The timeout: 3 earlier Mac activations wrote over Omarchy's menu template
# takes the template's timeout and quiet mode; every other menu is left alone.
SCRIPT=$ROOT/files/usr/lib/omarchy/mac-boot/limine-menu-defaults
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '### header\ntimeout: 1\nquiet: yes\ndefault_entry: 2\n' >"$tmp/template"
entries=$'/+Omarchy\n  //linux-aurora\n  protocol: efi\n'

menu() { printf '### header\n%sdefault_entry: 2\n%s' "$1" "$entries" >"$tmp/menu"; }
defaults() { bash "$SCRIPT" "$tmp/menu" "$tmp/template"; }
expect() { [[ $(<"$tmp/menu") == "$(printf '### header\n%sdefault_entry: 2\n%s' "$1" "$entries")" ]] || fail "$2: $(cat "$tmp/menu")"; }

menu $'timeout: 3\nquiet: yes\n'
defaults && expect $'timeout: 1\nquiet: yes\n' "a Mac's own timeout: 3 follows the template"
menu $'timeout: 3\n'
defaults && expect $'timeout: 1\nquiet: yes\n' "quiet is added after the timeout"
defaults && expect $'timeout: 1\nquiet: yes\n' "a second run changes nothing"
menu $'timeout: 3\nquiet: no\n'
defaults && expect $'timeout: 1\nquiet: no\n' "an owner's quiet: no stays"
pass "the timeout Mac activations wrote follows Omarchy's template, with quiet mode"

for kept in $'timeout: 5\n' $'#timeout: 3\n' $'timeout: 0\nquiet: yes\n' ''; do
  menu "$kept"
  defaults && expect "$kept" "a menu without the Mac's timeout: 3 is untouched"
done
pass "every other menu is left to Omarchy's migrations"

printf '### header\n#timeout: 3\ndefault_entry: 2\n' >"$tmp/template"
menu $'timeout: 3\n'
defaults && expect $'timeout: 3\n' "a template from before the quiet boot changes nothing"
rm "$tmp/menu"
defaults && [[ ! -e $tmp/menu ]] || fail "a missing menu is left alone"
pass "an old template and a missing menu change nothing"
