# Peri software

This folder contains the software installed on the Raspberry Pi. The standard build runs without an Arduino; an optional Arduino uses separate power and does not connect to the Pi.

Start with **[INSTALL.md](INSTALL.md)**. For touch controls and settings, see **[Using Peri](../docs/USE.md)**.

- `server/` — Python server and device controls.
- `web/` — the round display's interface.
- `firmware/` — experimental standalone sweep and serial-controlled Nano sketches; [start here](firmware/README.md).
- `scripts/`, `systemd/`, `assets/` — installation, startup and diagnostics.
- `config/` — default settings and an API-key configuration example.

Run the installer on the Pi. Keep your API key in `/etc/peri/peri.env`; no key is included here.
