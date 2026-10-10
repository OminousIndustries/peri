# Experimental head movement

Head movement is optional and **has not been verified on the physical Peri**. The Arduino needs separate power and does not connect to the Pi: there is no room for that USB connection in the enclosure. The Pi's voice, display and audio features work without it.

## Standalone sweep

Use [peri_sweep/peri_sweep.ino](peri_sweep/peri_sweep.ino) for the experimental, independently powered build. It uses only the Arduino core, with no extra libraries or serial commands.

After a three-second startup pause, it repeats:

**Left → pause → middle → pause → right → pause → middle → pause.**

The default is an estimated **±5°** of neck movement, with two-second pauses and a slow step rate. The estimate uses the existing project's nominal motor and gear ratio; actual direction, travel and clearances need a physical check. The coils turn off during each pause to avoid continuous holding current.

The sketch compiles for Nano ATmega328P and Old Bootloader targets. A host simulation checked 1,000 cycles with each direction setting, including the sequence, pauses, coil release and step-count bounds. These checks do not verify physical motion or prevent lost steps on real hardware.

## Wiring and power

For a classic ATmega328P Nano, ULN2003 board and **5 V** 28BYJ-48 motor:

| Connection | Connect to |
|---|---|
| ULN2003 IN1 | Nano D8 |
| ULN2003 IN2 | Nano D9 |
| ULN2003 IN3 | Nano D10 |
| ULN2003 IN4 | Nano D11 |
| ULN2003 VCC / + | Separate regulated 5 V motor supply |
| ULN2003 GND / − | Supply ground and Nano GND |
| ULN2003 motor socket | Keyed five-wire motor plug |

Power the Nano from its own USB supply, or an appropriate regulated supply for your exact board. A shared external supply may power the Nano and driver if correctly wired and rated for both; the motor current should go directly to the driver, not through Nano I/O pins. Follow the [classic Nano power specifications](https://store.arduino.cc/products/arduino-nano) and check clone-board differences. A regulated 5 V feed is not a VIN feed. No power or data connection to the Pi is required.

## Upload from your computer

1. With the motor supply disconnected, connect the Nano to your computer using a USB data cable.
2. Open `peri_sweep/peri_sweep.ino` in Arduino IDE. Select **Arduino AVR Boards → Arduino Nano**, the matching processor/bootloader and its USB port. Some clones require **ATmega328P (Old Bootloader)**.
3. Upload the sketch, then disconnect the programming cable. Do not connect an external power feed while programming unless your board's power arrangement explicitly supports it.
4. With **all power off**, gently center the neck and check cable slack. The sketch assumes this starting position is the middle; it cannot home itself or detect an end stop.
5. Keep the separate supply switch accessible, clear the mechanism and apply power. It starts moving automatically after three seconds, even with the Pi off. Disconnect that supply immediately if it binds or moves unexpectedly.

The settings near the top of the sketch control sweep angle, pauses, step interval and direction. Re-upload after changes. Keep the small default range until you have measured clearance. Recenter with power off after every reset, power interruption, skipped step or manual movement; pauses release the coils, so position can be disturbed.

Keep `PERI_HEAD_DRIVER=none` on the Pi. Its settings, speech and shutdown commands cannot control or stop this independent sweep. Switch off the Arduino supply separately.

## Existing serial sketch — custom setups only

[peri_head/peri_head.ino](peri_head/peri_head.ino) is a separate serial-controlled experiment. It waits for commands and will not sweep from power alone. It is retained for custom hardware with a real USB data connection to a host outside the standard enclosure arrangement.

The existing `scripts/flash-firmware.sh` uploads **that serial sketch**, not `peri_sweep`. Do not run it for the standalone build. Upload the sweep sketch from your computer as described above.
