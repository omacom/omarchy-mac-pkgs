#!/bin/bash
# The desktop shell reads the platform's audio hints (omarchy-mac/share/omarchy-platform/audio.json)
# through its own AudioNodesModel.js. On an M5 MacBook Pro (a K board: K114, K116) the microphone graph
# names its nodes audio_effect.k114-mic and effect_output.k114-mic: the shell must hide the capture
# stream, and list the mono source only until the stereo omarchy_asahi_mic exists. J boards still work.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
requires_runtime "$(basename -- "$0")" || exit 0
model=$OMARCHY_TEST_RUNTIME/shell/Commons/AudioNodesModel.js
[[ -f $model ]] || fail 'the runtime has shell/Commons/AudioNodesModel.js'
command -v node >/dev/null || fail 'node is available'
node - "$model" "$MAC/share/omarchy-platform/audio.json" <<'JS' || fail 'the shell hides the K-board microphone graph as it does the J boards'
const A = require(process.argv[2]), fs = require("fs");
const hints = A.parsePlatformAudio(fs.readFileSync(process.argv[3], "utf8"));
const hides = (name, present) => A.platformHidesNode(name, hints, present);
const check = (ok, what) => { if (!ok) { console.error("not ok: " + what); process.exit(1); } };
for (const board of ["k114", "k116", "j314", "j414"]) {
  const mic = "effect_output." + board + "-mic", cap = "audio_effect." + board + "-mic";
  check(hides(cap, [cap, mic]), board + ": the capture stream is hidden");
  check(hides(mic, [mic, "omarchy_asahi_mic"]), board + ": the mono source hides behind the stereo mapping");
  check(!hides(mic, [mic]), board + ": the mono source stays listed while no mapping exists");
}
check(!hides("omarchy_asahi_mic", ["omarchy_asahi_mic", "effect_output.k114-mic"]), "the stereo source stays listed");
check(!hides("effect_output.x114-mic", ["effect_output.x114-mic", "omarchy_asahi_mic"]), "only j and k boards");
JS
pass 'the shell hides the K-board (k114, k116) microphone graph by the platform audio hints, and J boards still'
