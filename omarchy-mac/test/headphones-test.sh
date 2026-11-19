#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
"$ROOT/install" "$stage"
script=$stage/usr/share/wireplumber/scripts/omarchy-mac/headphones-on-plug.lua
fragment=$stage/usr/share/wireplumber/wireplumber.conf.d/omarchy-mac-headphones.conf
[[ -f $script && -f $fragment ]] || fail 'the headphones hook and its fragment are staged'
grep -q 'name = omarchy-mac/headphones-on-plug.lua, type = script/lua' "$fragment" || fail 'the fragment loads the staged script'
grep -q 'custom.omarchy-mac-headphones-on-plug = required' "$fragment" || fail 'the main profile requires the hook, since an optional one never loads'

lua - "$script" <<'LUA'
local hook, sets = nil, {}
local values, jack, metadata_present = {}, nil, true
Log = { open_topic = function () return { info = function () end } end }
Constraint = function (t) return t end
EventInterest = function (t) return t end
Json = {
  Object = function (t) return { to_string = function () return '{"name":"' .. t.name .. '"}' end } end,
  Raw = function (v) return { parse = function () return { name = v:match ('"name":"([^"]*)"') } end } end,
}
SimpleEventHook = function (t) return { register = function () hook = t end } end
dofile (arg [1])
assert (hook.name == "omarchy-mac/headphones-on-plug")
assert (hook.before [1] == "default-nodes/find-selected-default-node", "runs before the configured node gets its bonus")

local JACK = "alsa_output.platform-sound.HiFi__Headphones__sink"
local metadata = {
  find = function (_, subject, key) assert (subject == 0); return values [key] end,
  set = function (_, subject, key, kind, value)
    assert (subject == 0 and kind == "Spa:String:JSON")
    values [key] = value; table.insert (sets, key .. "=" .. value)
  end,
}
local managers = {
  metadata = { lookup = function () return metadata_present and metadata or nil end },
  ["session-item"] = { lookup = function (_, t)
    assert (t.type == "SiLinkable" and t [1] [1] == "node.name" and t [1] [3] == JACK)
    return jack
  end },
}
local source = { call = function (_, method, kind) assert (method == "get-object-manager"); return managers [kind] end }
local function present (driver)
  jack = { get_associated_proxy = function (_, kind) assert (kind == "node"); return { properties = { ["alsa.driver_name"] = driver } } end }
end
local function choice (name) values ["default.configured.audio.sink"] = '{"name":"' .. name .. '"}' end
local function current (name) values ["default.audio.sink"] = '{"name":"' .. name .. '"}' end
local function rescan (jack_available)
  sets = {}
  local nodes = { { ["node.name"] = "audio_effect.j314-convolver" } }
  if jack_available then table.insert (nodes, { ["node.name"] = JACK }) end
  hook.execute { get_source = function () return source end,
    get_data = function (_, key) assert (key == "available-nodes"); return { parse = function () return nodes end } end }
  return sets
end
local function chose (list, ...)
  local want = { ... }
  if #list ~= #want then return false end
  for i, name in ipairs (want) do
    if list [i] ~= 'default.configured.audio.sink={"name":"' .. name .. '"}' then return false end
  end
  return true
end

present ("snd_soc_macaudio"); choice ("audio_effect.j314-convolver"); current ("audio_effect.j314-convolver")
assert (#rescan (false) == 0, "an unplugged jack changes nothing")
assert (chose (rescan (true), JACK), "plugging in chooses the headphones")
current (JACK)
assert (#rescan (true) == 0, "a later rescan leaves a speaker choice made while plugged in")
assert (#rescan (false) == 0, "unplugging leaves the fallback to the saved history")
current ("audio_effect.j314-convolver")
assert (chose (rescan (true), "audio_effect.j314-convolver", JACK), "plugging in again saves the speakers in use, then chooses the headphones")

dofile (arg [1])
assert (#rescan (true) == 0, "a restart with headphones in keeps the choice it finds")
rescan (false)
choice (JACK); current ("alsa_output.platform-39b540000.audio-controller.stereo-fallback")
assert (chose (rescan (true), "alsa_output.platform-39b540000.audio-controller.stereo-fallback", JACK),
  "an output picked automatically is saved first, so unplugging returns to it")

dofile (arg [1]); present ("snd_usb_audio")
rescan (false)
assert (#rescan (true) == 0, "a sink of that name from another driver is not the jack")
dofile (arg [1]); present ("snd_soc_macaudio")
rescan (false); jack = nil
assert (#rescan (true) == 0, "no jack node, nothing set")
dofile (arg [1]); present ("snd_soc_macaudio"); metadata_present = false
choice ("audio_effect.j314-convolver"); current ("audio_effect.j314-convolver")
rescan (false)
assert (#rescan (true) == 0, "no metadata, nothing set")
metadata_present = true
rescan (false)
assert (chose (rescan (true), JACK), "the plug is seen once the metadata exists")
LUA
pass 'headphones on plug'
