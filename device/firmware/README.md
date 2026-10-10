# Arduino Nano firmware

The Nano drives the 28BYJ-48 motor through a ULN2003 board. Connect it to the Pi with a USB data cable. Wiring is in the [assembly guide](../../docs/ASSEMBLY.md#7-peri-motor-wiring).

## Flash from the Pi

After installing Peri:

```bash
sudo /opt/peri/scripts/flash-firmware.sh
sudo peri-config head status
```

The script downloads Arduino tooling if needed, compiles the included sketch, uploads it and checks that the Nano responds. It stops the Peri server during flashing and restarts it afterward.

If automatic detection fails, specify your serial port:

```bash
sudo /opt/peri/scripts/flash-firmware.sh --port /dev/ttyUSB0
```

Some Nano clones use the old bootloader. If upload reports `not in sync`, try:

```bash
sudo /opt/peri/scripts/flash-firmware.sh --fqbn arduino:avr:nano:cpu=atmega328old
```

You can also open [peri_head/peri_head.ino](peri_head/peri_head.ino) in the Arduino IDE, select **Arduino Nano**, choose the matching ATmega328P bootloader and upload.

## First movement

Center the neck with power off before startup. There is no position sensor. After flashing, keep cables and covers clear and run:

```bash
sudo peri-config head test
```

This requests small +5°, −5° and center movements. Physical head movement has not yet been verified on the reference device. Confirm motor power, direction and clearance on your own build before enabling normal movement.
