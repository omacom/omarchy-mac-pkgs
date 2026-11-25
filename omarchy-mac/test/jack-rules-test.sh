#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
"$ROOT/install" "$stage"
rules=$stage/usr/share/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf
[[ -f $rules ]] || fail 'the no-suspend rule ships'

# The headphone jack is device 0 of the speaker card on M1 to M3 (hw:AppleJ314)
# and device 0 of a card of its own on the M4 MacBooks (hw:AppleJack).
python3 - "$rules" <<'PY' || fail 'the outputs that stay open'
import re
import sys
text = re.sub(r'#[^\n]*', '', open(sys.argv[1]).read())
matches = re.search(r'matches = \[(.*?)\]\s*actions = \{\s*update-props = \{\s*session\.suspend-timeout-seconds = 0\s*\}', text, re.S)
objects = [dict(re.findall(r'(\S+) = "([^"]*)"', block)) for block in re.findall(r'\{([^{}]*)\}', matches.group(1))]
assert text.count('update-props') == 1 and objects and all(objects), text
def matched(pattern, value):
    # WirePlumber treats "~" as an unanchored regular expression search.
    return re.search(pattern[1:], value) is not None if pattern.startswith('~') else pattern == value
def held(path, media_class):
    node = {'api.alsa.path': path, 'media.class': media_class}
    return any(all(matched(pattern, node.get(key, '')) for key, pattern in match.items()) for match in objects)
# Speakers and the jack stay open on either layout.
for path in ('hw:AppleJ293,1', 'hw:AppleJ314,0', 'hw:AppleJ413,0', 'hw:AppleJ616,1', 'hw:AppleJ713,1', 'hw:AppleJack,0'):
    assert held(path, 'Audio/Sink'), path
# Capture still suspends, and nothing else is held open.
for path, media_class in (('hw:AppleJ314,0', 'Audio/Source'), ('hw:AppleJack,0', 'Audio/Source'),
                          ('hw:AppleJ713HPAI,0', 'Audio/Source'), ('hw:AppleJack,1', 'Audio/Sink'),
                          ('hw:AppleJacket,0', 'Audio/Sink'), ('hw:PCH,0', 'Audio/Sink')):
    assert not held(path, media_class), (path, media_class)
PY
pass 'the headphone jack stays open on the speaker card and on a card of its own, and capture still suspends'
