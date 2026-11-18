#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
"$ROOT/install" "$stage"
script=$stage/usr/share/wireplumber/scripts/omarchy-mac/headphones-on-plug.lua
fragment=$stage/usr/share/wireplumber/wireplumber.conf.d/omarchy-mac-headphones.conf
[[ -f $script && -f $fragment ]] || fail 'the headphones hook and its fragment are staged'
grep -q 'name = omarchy-mac/headphones-on-plug.lua, type = script/lua' "$fragment" || fail 'the fragment loads the staged script'
grep -q 'custom.omarchy-mac-headphones-on-plug = optional' "$fragment" || fail 'the main profile loads the hook as optional'

lua - "$script" <<'LUA'
local hook, sets, metadata_present = nil, {}, true
Log = { open_topic = function () return { info = function () end } end }
Constraint = function (t) return t end
EventInterest = function (t) return t end
Json = {
  Object = function (t) return { to_string = function () return '{"name":"' .. t.name .. '"}' end } end,
}
SimpleEventHook = function (t) return { register = function () hook = t end } end
dofile (arg [1])
assert (hook.name == "omarchy-mac/headphones-on-plug")
assert (hook.before [1] == "default-nodes/find-selected-default-node", "runs before the configured node gets its bonus")

local metadata = { set = function (_, subject, key, kind, value) table.insert (sets, { subject, key, kind, value }) end }
local source = { call = function (_, method, kind)
  assert (method == "get-object-manager" and kind == "metadata")
  return { lookup = function () return metadata_present and metadata or nil end }
end }
local headphones = { ["node.name"] = "alsa_output.platform-sound.HiFi__Headphones__sink", ["alsa.driver_name"] = "snd_soc_macaudio" }
local speakers = { ["node.name"] = "audio_effect.j314-convolver" }
local other = { ["node.name"] = "alsa_output.platform-sound.HiFi__Headphones__sink", ["alsa.driver_name"] = "snd_usb_audio" }
local function rescan (nodes)
  sets = {}
  hook.execute { get_source = function () return source end,
    get_data = function (_, key) assert (key == "available-nodes"); return { parse = function () return nodes end } end }
  return sets
end

assert (#rescan { speakers } == 0, "speakers alone change nothing")
local plugged = rescan { speakers, headphones }
assert (#plugged == 1 and plugged [1] [1] == 0 and plugged [1] [2] == "default.configured.audio.sink" and plugged [1] [3] == "Spa:String:JSON")
assert (plugged [1] [4] == '{"name":"alsa_output.platform-sound.HiFi__Headphones__sink"}', plugged [1] [4])
assert (#rescan { speakers, headphones } == 0, "a later rescan leaves a speaker choice made while plugged in")
assert (#rescan { speakers } == 0, "unplugging leaves the fallback to the saved history")
assert (#rescan { speakers, headphones } == 1, "plugging in again chooses the headphones again")
rescan { speakers }
assert (#rescan { speakers, other } == 0, "a headphone sink from another driver is not the jack")
metadata_present = false
assert (#rescan { speakers, headphones } == 0, "no metadata, nothing set")
metadata_present = true
assert (#rescan { speakers, headphones } == 1, "the plug is still seen once the metadata exists")
LUA
pass 'headphones on plug'
