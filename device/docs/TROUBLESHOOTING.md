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
| Nano not detected | Check that its USB cable carries data and connects to the Pi. Run `sudo peri-config head status`. |
| Nano connected but no movement | Check driver/motor power, the motor connector, D8–D11 wiring and the head-movement setting. The reference device's motor still needs physical verification. |
| Nano upload says `not in sync` | Try the old bootloader command in the [firmware guide](../firmware/README.md). |
| Head moves in the wrong direction | Run `sudo peri-config set PERI_HEAD_INVERT 1`, then repeat the small head test. |
| Head grinds or hits a cover | Stop movement, power off and inspect the gear mesh and cable clearance. Recenter the neck before restarting and use a smaller movement range. |
| Need to retry installation | From `~/device`, run `sudo bash ./install.sh --yes`. Existing settings and the API key are retained. |

The installation log is `/var/log/peri-install.log`. To undo installation, use the [removal instructions](../INSTALL.md#update-or-remove).
