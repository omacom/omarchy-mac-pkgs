-- Plugging headphones into a Mac's jack makes them the chosen output, as on macOS.
-- The jack is its own sink here, so a saved speaker choice otherwise keeps them.
-- Unplugging falls back to the previous choice through WirePlumber's own history.

log = Log.open_topic ("s-omarchy-mac-headphones")

local JACK = "alsa_output.platform-sound.HiFi__Headphones__sink"

-- The jack as last seen: false unplugged, true plugged, nil not seen yet.
local plugged = nil

local function name_of (metadata, key)
  local value = metadata:find (0, key)
  return value and Json.Raw (value):parse () ["name"] or nil
end

local function choose (metadata, key, name)
  metadata:set (0, key, "Spa:String:JSON", Json.Object { ["name"] = name }:to_string ())
end

SimpleEventHook {
  name = "omarchy-mac/headphones-on-plug",
  before = { "default-nodes/find-selected-default-node" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
      Constraint { "default-node.type", "=", "audio.sink" },
    },
  },
  execute = function (event)
    local source = event:get_source ()
    local metadata = source:call ("get-object-manager", "metadata"):lookup {
      Constraint { "metadata.name", "=", "default" },
    }
    local jack = source:call ("get-object-manager", "session-item"):lookup {
      type = "SiLinkable",
      Constraint { "node.name", "=", JACK },
    }
    local node = jack and jack:get_associated_proxy ("node")
    if not metadata or not node or node.properties ["alsa.driver_name"] ~= "snd_soc_macaudio" then
      plugged = nil
      return
    end

    local available = false
    local available_nodes = event:get_data ("available-nodes")
    for _, node_props in ipairs (available_nodes and available_nodes:parse () or {}) do
      if node_props ["node.name"] == JACK then
        available = true
      end
    end

    -- Only a plug-in seen happening switches, not jack state found at startup,
    -- so a WirePlumber restart keeps a speaker choice made with headphones in.
    if available and plugged == false then
      log:info ("headphones plugged in, choosing " .. JACK)
      local current = name_of (metadata, "default.audio.sink")
      if current and current ~= JACK and current ~= name_of (metadata, "default.configured.audio.sink") then
        choose (metadata, "default.configured.audio.sink", current)
      end
      choose (metadata, "default.configured.audio.sink", JACK)
    end
    plugged = available
  end
}:register ()
