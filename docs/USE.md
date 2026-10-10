# Using Peri

After [setup](../device/INSTALL.md), Peri starts automatically when the Pi boots.

## Touch controls

| Action | Result |
|---|---|
| Tap while asleep | Wake Peri, then speak |
| Tap while Peri is speaking | Interrupt its reply |
| Tap while awake and not speaking | Mute or unmute the microphone |
| Double-tap while awake | Put Peri to sleep |
| Hold the display for about one second | Open settings |

Peri returns to sleep after the idle period selected in settings. There is no wake-word detector.

## Settings

Hold the display to change volume, personality, voice, captions, brightness, display rotation and sleep timing. Opening settings puts the conversation to sleep.

**Wake** lets you choose tap-to-talk or always listening. Audio goes to OpenAI while Peri is awake and its microphone is enabled. Leave tap-to-talk selected if you want to choose when a conversation begins.

If Peri hears its own speaker and interrupts itself, reduce the volume and set **Talk over Peri → Tap only**. You can still interrupt a reply by tapping.

**Head movement** can be turned off. If you enable it, check the mechanism and cable clearance first. Its position is estimated; it cannot detect a stuck gear or a skipped step.

## Shut down

Open settings, find **Power → Shut down**, and tap again to confirm. Wait for the Pi to shut down before unplugging it. You can also run `sudo shutdown -h now` over SSH.

## Get help

Start with [troubleshooting](../device/docs/TROUBLESHOOTING.md). These commands run on the Pi:

```bash
sudo peri-config status
sudo /opt/peri/scripts/verify.sh
sudo journalctl -u peri-server -u peri-kiosk -n 80 --no-pager
```

When reporting a problem, include the Pi model, OS, what happened and the relevant error. Remove API keys, passwords and network details from anything you share.
