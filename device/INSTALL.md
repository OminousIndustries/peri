# Set up Peri

You need the assembled Pi 4B, display, WM8960 HAT and speakers, a microSD card, internet access, and a computer that can connect to the Pi over SSH. Use your own OpenAI API key.

## 1. Prepare the Pi

The tested device used **Raspberry Pi OS (Legacy) 64-bit, release 2024-07-04 (Bullseye)** with working display and audio drivers. If you already have that working setup, keep it: the installer preserves those drivers. Avoid `apt full-upgrade` on that vendor-driver setup because a kernel change can break them.

For a new SD card, the installer also supports **Raspberry Pi OS Lite 64-bit, Bookworm or Trixie**. Those installation paths have automated checks but have not been physically verified on the reference device. A fresh stock Legacy image also needs the display and audio vendor drivers; it is not the same as an already configured device.

Use Raspberry Pi Imager to write your chosen image. Configure:

- Hostname: `peri`.
- Your own username and password. Use a username other than `peri`, which the installer reserves for its service account.
- Wi-Fi and country, if using wireless networking.
- Your timezone and keyboard layout.
- SSH enabled.

Insert the card. With the power off, center the neck and check all wiring. Connect the Nano's USB data cable to the Pi, then power on. The display may stay dark until the installer runs and the Pi reboots.

## 2. Copy the software

On your computer, open a terminal in the downloaded repository folder. Replace `USER` with the login you chose. If `peri.local` does not work, use the Pi's IP address.

```bash
scp -r device USER@peri.local:~/
ssh USER@peri.local
cd ~/device
```

Alternatively, copy the `device` folder into your Pi user's home folder with an SCP client, then connect over SSH and run `cd ~/device`.

## 3. Install

Run these commands **on the Pi**:

```bash
sudo bash ./install.sh --dry-run --yes
sudo bash ./install.sh --yes
```

The first command previews the changes. The second installs Peri, configures the display/audio and sets the interface to start at boot. Wait for it to finish and resolve any `FAIL` entries. If it reports **REBOOT REQUIRED**, run:

```bash
sudo reboot
```

Reconnect with `ssh USER@peri.local` after the Pi restarts.

## 4. Add your API key

Create a key in your own [OpenAI API account](https://platform.openai.com/api-keys) and enable API billing. A ChatGPT subscription does not include API usage.

Run this block in Bash on the Pi. The key is entered without displaying it or adding it to shell history:

```bash
read -r -s -p 'OpenAI API key: ' PERI_SETUP_KEY; printf '\n'
printf '%s\n' "$PERI_SETUP_KEY" | sudo peri-config set OPENAI_API_KEY -
unset PERI_SETUP_KEY
sudo peri-config key-check
```

The key is stored in `/etc/peri/peri.env`. Keep it out of GitHub, screenshots and shared logs. `key-check` contacts OpenAI to check the key.

## 5. Set up the Nano

**Physical head movement remains unverified on the reference build.** The Nano must be powered, connected to the Pi by USB, and wired to the driver as shown in the [assembly instructions](../docs/ASSEMBLY.md#7-peri-motor-wiring).

With the neck centered and clear of cables and covers:

```bash
sudo /opt/peri/scripts/flash-firmware.sh
sudo peri-config head status
sudo peri-config head test
```

The test requests small +5°, −5° and center movements. Check actual movement and direction. If the first move goes toward the head's left, run `sudo peri-config set PERI_HEAD_INVERT 1` and test again. Start with a small range; keep it at or below the clearance you have measured on your build. The default range is ±20°.

The neck has no position sensor. Center it with power off before first startup and after it loses position. See [Nano flashing help](firmware/README.md) if uploading fails.

## 6. Check the finished device

```bash
sudo /opt/peri/scripts/post-reboot-verify.sh
sudo /opt/peri/scripts/audio-test.sh
sudo peri-config head status
```

Check that the display appears after boot, touch works, both speakers play and the microphone hears you. Tap the face and try a conversation. Test head movement separately and confirm the cables clear the mechanism. Software checks cannot confirm those physical details.

Next: **[Using Peri](../docs/USE.md)**. If something fails, use [troubleshooting](docs/TROUBLESHOOTING.md).

## Update or remove

To update, copy the new `device` folder to the Pi again, then run `cd ~/device` and `sudo bash ./install.sh --yes`. The installed API key and settings are retained.

To uninstall, run `sudo bash /opt/peri/uninstall.sh --yes`, then reboot. The uninstaller restores backed-up system files and keeps settings and credentials unless you explicitly request data removal.
