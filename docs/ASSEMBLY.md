# Assembly and wiring

Use this with the [34-page main illustrated guide](AssemblyGuide.pdf) and the [13-page Arduino assembly guide](ArduinoAssemblyGuide.pdf). The PDFs use the original name Talk Buddy for this enclosure. Peri replaces its software and standalone motor control with a Pi-connected Nano.

The Arduino guide replaces the main guide's early crossmember, post and pinion steps. Use the Arduino variant below for Peri. Its final page refers to an older Arduino Setup PDF for wiring; use section 7 here and the current [software setup](../device/INSTALL.md). Do not combine the older small-gear pivot screw with the Arduino motor-shaft pinion.

Disconnect all power before connecting or repositioning hardware. Read the [parts list](PARTS.md) and [printing guide](../prints/README.md) first.

## 1. Base and supports — main page 2; Arduino pages 1–6

1. Attach each speaker mount to its matching base half, using four M3×10 screws and four M3 nuts total. Compare mount direction with main page 2.
2. Mount the ULN2003 board in the position shown on Arduino page 1, using at least two M2×4 screws. Board hole patterns vary; use the matching mounting holes without bending the board.
3. Insert two M3 nuts into the motor screw recesses in the case halves (Arduino page 2). These must be in place before the motor mount covers them.
4. Join the halves with `Arduino_Build/Motor_Mount.stl`, using four M3×8 screws and four M3 nuts. Leave these loose initially.
5. Fit three square posts and one round post with eight M3×8 screws and eight M3 nuts. Put the round post at the rear center pivot. Leave these loose initially.
6. Join the rear tabs with one M3×8 screw and one M3 nut. Align the case halves, then tighten the base joins (Arduino pages 5–6).

## 2. Motor, gearbox and Nano mount — Arduino pages 7–13

1. Seat the stepper motor in its mount. Secure it using two M3×25 screws into the two nuts placed beneath the mount in section 1 (Arduino page 7).
2. Place `Arduino_Build/Gearbox_Bottom_Arduino.stl` over the four posts and motor. Ensure the motor shaft passes through its opening without forcing the cover (Arduino page 8).
3. Press `Arduino_Build/Small_Gear_Arduino.stl` onto the motor shaft, matching the shaft profile. This pinion has no separate pivot screw or lock nut (Arduino page 9).
4. Align the gearbox top with the bottom. Insert three M3 nuts in the front recesses of the three square posts, then secure the top through the bottom using three M3×16 screws (Arduino pages 10–11). Screw heads must not protrude above the top where the neck mount travels.
5. Attach `Arduino_Build/Arduino_Mount.stl` to the speaker mount pictured on Arduino page 12, using two M2×6 screws. Insert the Nano into the bracket as shown on page 13. Check access to the USB connector and jumper headers before closing the enclosure.

The older `NO_Arduino` mechanism instead uses the crossbrace, main-guide M3×10 base fasteners, and a freely rotating small gear retained by an M3×8 screw and lock nut. Those early main-guide steps do not apply to the Arduino build. Its later neck, display and enclosure steps below are shared.

## 3. Neck and big gear — main pages 12–13

Join the neck mount to the big gear with three M3×12 screws/nuts. Join that assembly to the neck with three M3×10 screws/nuts. Follow PDF orientation and keep the cable loop accessible.

## 4. Display, Pi and HAT — main pages 14–18

Mount the Pi behind the round display with its four supplied screws. Connect the DSI ribbon with correct contact orientation and close both latches. Seat the WM8960 HAT over all 40 GPIO pins without an offset.

Main page 17 shows the display's four-wire lead through the HAT header:

| Display label | Pi signal | Physical pin |
|---|---|---:|
| SDA | BCM GPIO 2 / SDA1 | 3 |
| 5 V | 5 V supply | 4 |
| SCL | BCM GPIO 3 / SCL1 | 5 |
| GND | Ground | 6 |

Use lead labels and your revision's [Waveshare diagram](https://www.waveshare.com/wiki/4inch_DSI_LCD_(C)); do not infer connections from wire colors. BCM and physical pin numbering differ. Display and HAT share I2C.

Fit the right-angle USB-C adapter as on page 18, pointing clear of the neck.

## 5. Cables and display mounting — main pages 19–24

Route the speaker lead from the base through the neck-mount wiring loop and up the neck before fitting speakers. Connect it to the HAT speaker connector, supporting the board to avoid bending GPIO pins.

Route Pi power from the rear rectangular opening through the loop to the USB-C adapter. Leave slack for the small neck sweep. Route the Nano's Pi USB cable clear of moving gears.

The neck uses three of the display module's four holes. Orient the Pi power port toward the corner without a neck screw hole (page 23). Start all three M4×8 screws before tightening; reach the upper screw through the rear access hole. Keep cables in the loop if removing the neck mount for access.

## 6. Covers, speakers and pivot — main pages 25–33

Fit covers with tabs behind the speaker mounts and rear case. Secure the rear with one M3×12 screw per side; no nuts are used there in the guide.

Attach each speaker with three M3×25 screws, three nuts and three printed washers. The top two attachments also retain the front cover. Connect matching left/right outputs; bridge speaker outputs must not be tied together or to ground.

Slide the big gear between gearbox top and bottom until it meshes with the pinion; the neck mount rests above the top. Insert the M3×20 pivot screw upward through the case, round post, bottom and big gear. Capture its nut in the gear top cover. Retain without binding the pivot.

Fit grilles with six M2×4 screws total. Inspect cable clearance before closing.

## 7. Peri motor wiring

Connect Nano USB **to the Pi** for serial control. Replace standalone sweep firmware with [Peri firmware](../device/firmware/README.md).

| ULN2003 connection | Nano |
|---|---|
| IN1 | D8 |
| IN2 | D9 |
| IN3 | D10 |
| IN4 | D11 |
| VCC / + | 5 V |
| GND / − | GND |
| Keyed motor socket | 28BYJ-48 five-wire plug |

Verify motor voltage and USB power budget on your build. The Nano USB connection carries the control commands. Keep motor signals off the HAT's I2S pins.

## 8. First boot checks

- Verify DSI seating, header alignment, speaker polarity and driver wiring with power off.
- Center the neck by hand; there is no position sensor.
- Check cable slack and cover clearance with a small manual sweep. Do not force gears or assume the sector gear's full arc is available.
- Keep hands clear during the first motor test. Test ±5° first, then confirm printed clearance. Default software sweep is ±20°.

Continue with [software setup](../device/INSTALL.md). Check touch, audio, neck direction and reboot physically before declaring the build complete.
