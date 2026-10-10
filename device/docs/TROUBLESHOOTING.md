# Troubleshooting

Run these on the Pi to see what needs attention:

```bash
sudo peri-config status
sudo /opt/peri/scripts/verify.sh
sudo journalctl -u peri-server -u peri-kiosk -n 80 --no-pager
```

| Problem | Check or fix |
|---|---|
| Cannot connect over SSH | Check the Pi's power and network. Try its IP address instead of `peri.local`. SSH must be enabled in the OS. |
| Blank display | Check the DSI ribbon and display power with power disconnected. After installation, reboot and run `sudo peri-kiosk status`. |
| Text console instead of Peri | Run `sudo peri-kiosk start`. To start it automatically on boot, run `sudo peri-kiosk enable` and reboot. |
| Interface appears on an HDMI screen | Disconnect the HDMI monitor and reboot. |
| Interface stopped responding | Run `sudo peri-kiosk restart`. Check the server log if it happens again. |
| No sound or microphone | Run `sudo /opt/peri/scripts/audio-test.sh`. Check HAT seating, speaker connections and volume. A fresh Legacy OS image requires vendor audio drivers. |
| Peri interrupts itself | Lower volume. In settings, change **Talk over Peri** to **Tap only**. |
| API key or connection error | Run `sudo peri-config key-check`. Check internet access, the Pi's clock, API billing and your key. Replace the key using the method in [setup](../INSTALL.md#4-add-your-api-key). |
| Nano not detected / unwanted head settings | Expected for this enclosure: the optional Nano does not connect to the Pi. Run `sudo peri-config set PERI_HEAD_DRIVER none` if you used older setup instructions. Conversation works without the Arduino. |
| Optional Arduino has no power or movement | Check its separate supply and the [standalone sweep wiring](../firmware/README.md). Upload `peri_sweep.ino` from your computer; the other sketch, `peri_head.ino`, waits for serial commands and will not sweep from power alone. Head movement is still unverified. |
| Optional head moves in the wrong direction or hits a cover | Turn off its separate supply. Inspect the gear mesh, wiring and cable clearance; adjust direction/range in its standalone sketch. Pi head settings cannot control this Arduino. |
| Need to retry installation | From `~/device`, run `sudo bash ./install.sh --yes --head none`. Existing settings and the API key are retained. |

The installation log is `/var/log/peri-install.log`. To undo installation, use the [removal instructions](../INSTALL.md#update-or-remove).
