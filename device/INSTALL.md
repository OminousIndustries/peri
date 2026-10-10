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

Insert the card. With the power off, check all wiring, then power on the Pi. The optional Arduino does not connect to the Pi and needs its own power source; it is not needed for this setup. The display may stay dark until the installer runs and the Pi reboots.

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
sudo bash ./install.sh --dry-run --yes --head none
sudo bash ./install.sh --yes --head none
```

The first command previews the changes. The second installs Peri, configures the display/audio and sets the interface to start at boot. `--head none` disables Pi motor control and hides its head settings, including when you have an independently powered Arduino. Wait for it to finish and resolve any `FAIL` entries. If it reports **REBOOT REQUIRED**, run:

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

## 5. Optional Arduino

**No Arduino flashing or Pi connection is needed for the normal build.** The enclosure has no room for a USB connection between the Pi and Nano. If you fit the optional motor assembly, its Arduino needs separate power and a standalone movement sketch. See the [assembly instructions](../docs/ASSEMBLY.md#7-optional-arduino-power-and-firmware).

For optional movement, upload the [experimental standalone sweep sketch](firmware/README.md) from your computer, following its separate guide. Do not use the Pi flashing helper: it uploads the other, serial-controlled sketch. Head movement remains physically unverified.

If you used the earlier instructions, disable Pi motor control with:

```bash
sudo peri-config set PERI_HEAD_DRIVER none
```

## 6. Check the finished device

```bash
sudo /opt/peri/scripts/post-reboot-verify.sh
sudo /opt/peri/scripts/audio-test.sh
```

Check that the display appears after boot, touch works, both speakers play and the microphone hears you. Tap the face and try a conversation. Any optional Arduino movement needs its own power and testing; it is not controlled or verified by the Pi.

Next: **[Using Peri](../docs/USE.md)**. If something fails, use [troubleshooting](docs/TROUBLESHOOTING.md).

## Update or remove

To update, copy the new `device` folder to the Pi again, then run `cd ~/device` and `sudo bash ./install.sh --yes --head none`. The installed API key and other settings are retained.

To uninstall, run `sudo bash /opt/peri/uninstall.sh --yes`, then reboot. The uninstaller restores backed-up system files and keeps settings and credentials unless you explicitly request data removal.
