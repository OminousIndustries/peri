# Peri software

This folder contains the software installed on the Raspberry Pi and the firmware for the Arduino Nano.

Start with **[INSTALL.md](INSTALL.md)**. For touch controls and settings, see **[Using Peri](../docs/USE.md)**.

- `server/` — Python server and device controls.
- `web/` — the round display's interface.
- `firmware/` — Nano motor firmware.
- `scripts/`, `systemd/`, `assets/` — installation, startup and diagnostics.
- `config/` — default settings and an API-key configuration example.

Run the installer on the Pi. Keep your API key in `/etc/peri/peri.env`; no key is included here.
