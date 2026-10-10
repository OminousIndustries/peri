-- /etc/wireplumber/main.lua.d/51-peri-wm8960.lua                   (WirePlumber 0.4.x, Debian 12 "Bookworm")
-- Installed by the Peri installer (scripts/setup-audio.sh).
--
-- Makes the WM8960 audio HAT the default speaker AND microphone by giving its ALSA nodes a high priority. The exact node
-- names depend on the driver/kernel (Pi 4 simple-card: alsa_output.platform-soc_sound.stereo-fallback), so several patterns
-- are matched. scripts/hw-init.sh also sets the default nodes at every boot (wpctl set-default), so this is a second net.
--
-- RECOVERY: if audio ever misbehaves, delete this file and restart WirePlumber:
--   sudo rm /etc/wireplumber/main.lua.d/51-peri-wm8960.lua
--   sudo -u peri XDG_RUNTIME_DIR=/run/user/$(id -u peri) systemctl --user restart wireplumber
table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.*wm8960*" } },
    { { "node.name", "matches", "alsa_output.*seeed*" } },
    { { "node.name", "matches", "alsa_output.*soc_sound*" } },
    -- the board-independent way: the ALSA card name ("wm8960-soundcard", "seeed-2mic-voicecard"; Pi 5 node names differ)
    { { "api.alsa.card.name", "matches", "*wm8960*" } },
    { { "api.alsa.card.name", "matches", "*seeed*" } },
  },
  apply_properties = {
    ["priority.session"] = 2500,
    ["priority.driver"] = 2500,
    -- Optional tuning: never suspend the codec (avoids a clipped first syllable after idle, costs a little power):
    -- ["session.suspend-timeout-seconds"] = 0,
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_input.*wm8960*" } },
    { { "node.name", "matches", "alsa_input.*seeed*" } },
    { { "node.name", "matches", "alsa_input.*soc_sound*" } },
    { { "api.alsa.card.name", "matches", "*wm8960*" } },
    { { "api.alsa.card.name", "matches", "*seeed*" } },
  },
  apply_properties = {
    ["priority.session"] = 2500,
    ["priority.driver"] = 2500,
  },
})
