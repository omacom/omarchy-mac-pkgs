-- Plugging headphones into a Mac's jack makes them the chosen output, as on macOS.
-- The jack is its own sink here, so a saved speaker choice otherwise keeps them.
-- Unplugging falls back to the previous choice through WirePlumber's own history.

log = Log.open_topic ("s-omarchy-mac-headphones")

local available = {}

local function is_jack_headphones (node_props)
  return node_props ["alsa.driver_name"] == "snd_soc_macaudio" and
      node_props ["node.name"] == "alsa_output.platform-sound.HiFi__Headphones__sink"
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
    local available_nodes = event:get_data ("available-nodes")
    available_nodes = available_nodes and available_nodes:parse () or {}

    local metadata = event:get_source ():call ("get-object-manager", "metadata"):lookup {
      Constraint { "metadata.name", "=", "default" },
    }
    if not metadata then
      return
    end

    local now = {}
    for _, node_props in ipairs (available_nodes) do
      if is_jack_headphones (node_props) then
        local name = node_props ["node.name"]
        now [name] = true
        if not available [name] then
          log:info ("headphones plugged in, choosing " .. name)
          metadata:set (0, "default.configured.audio.sink", "Spa:String:JSON",
              Json.Object { ["name"] = name }:to_string ())
        end
      end
    end
    available = now
  end
}:register ()
