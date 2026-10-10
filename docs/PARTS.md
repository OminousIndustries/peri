# Parts list

Parts for the Raspberry Pi 4B build shown in the assembly guides. The Arduino and motor are optional and have their own power source.

## Electronics and cables

| Quantity | Part | Fit/setup notes |
|---|---|---|
| 1 | Raspberry Pi 4B | Reference case and guide use this board; Pi 3/5 fit and cabling need separate checks |
| 1 | Waveshare **4inch DSI LCD (C)** | Round, 720×720, capacitive touch; use its mounting screws, DSI ribbon and 4-pin power/I2C lead |
| 1 | [Waveshare WM8960 Audio HAT](https://www.waveshare.com/product/wm8960-audio-hat.htm), SKU 15668 | 40-pin GPIO HAT, stereo microphones and speaker outputs; available separately or bundled with speakers |
| 2 speaker enclosures total | [Waveshare 14595, 8Ω 5W speakers](https://www.waveshare.com/product/accessories/8ohm-5w-speaker.htm) | Left/right enclosures used in the owner's tested build; supplied with that HAT kit, also available separately |
| 1 | Pi 4 compatible USB-C supply | Powers the Pi, display and audio HAT; use the right-angle USB-C adapter |
| 1 | Right-angle USB-C adapter | Compare orientation with PDF pages 18 and 23 |
| 1 | microSD card | Room for a 64-bit OS and updates; 32 GB is a practical starting size |
| 1 | Network connection | Wi-Fi or Ethernet with internet |

Compare the [display manufacturer's connections](https://www.waveshare.com/wiki/4inch_DSI_LCD_(C)) and [audio HAT documentation](https://www.waveshare.com/wiki/WM8960_Audio_HAT) with your board revision. The HAT uses I2C on BCM 2/3 and I2S on BCM 18/19/20/21; its bridge speaker outputs must not be connected to a common ground.

You need two speaker enclosures total. Some WM8960 HAT kits include both, so check the package contents before ordering additional speakers. The 5 W figure is the speaker rating; the HAT's specified output is 1 W per channel into 8Ω.

## Optional Arduino and motor

The Arduino does **not** connect to the Pi: the enclosure has no room for that USB connection. It needs independent power and a standalone sketch to control movement. An experimental [standalone sweep sketch](../device/firmware/README.md) is included. Read its wiring and testing notes before buying these optional parts; physical head movement remains unverified.

| Quantity | Part | Fit/setup notes |
|---|---|---|
| 1 | Arduino Nano, ATmega328P/compatible | Independent motor controller |
| 1 | ULN2003 stepper-driver board | Match the five-wire motor connector |
| 1 | 28BYJ-48 **5 V** stepper | Geared motor for the Arduino pinion |
| 1 | Separate power supply for the Nano and 5 V motor/driver | Check the board's power-input requirements and the motor's current draw; not powered by the Pi |
| 1 | Nano power cable | Connector depends on the Nano and its separate supply; allow access outside the enclosure |
| 1 set | Nano/driver jumper wires | Control signals and a shared ground within the motor assembly; match the standalone sketch |

## Printed parts

See the [print quantities](../prints/README.md). Print the common parts and either `NO_Arduino/` or `Arduino_Build/`, depending on your build.

## Fasteners

The first column follows the [main guide](AssemblyGuide.pdf). The optional Arduino column substitutes the [Arduino guide](ArduinoAssemblyGuide.pdf) for its base, motor and Nano bracket steps. These totals count the pictured steps; verify fit and the hardware supplied with your display.

| Fastener | Without Arduino | Optional Arduino | Uses |
|---|---:|---:|---|
| M3×8 screws | 1 | 13 | Free pinion axle without Arduino; motor mount, posts and rear join with Arduino |
| M3×10 screws | 20 | 7 | Speaker mounts and neck; also base joins/posts without Arduino |
| M3×12 screws | 5 | 5 | Big gear/neck mount (3), rear top covers (2) |
| M3×16 screws | 3 | 3 | Gearbox top through bottom to square posts |
| M3×20 screw | 1 | 1 | Main neck pivot |
| M3×25 screws | 6 | 8 | Speaker attachments (6), optional motor (2) |
| M3 standard nuts | 33 | 35 | Base, gearbox, neck, speakers and pivot |
| M3 lock nut | 1 | 0 | Free pinion axle without Arduino |
| M4×8 screws | 3 | 3 | Display to neck |
| M2×4 screws | 6 | At least 8 | Speaker grilles (6), optional ULN2003 board (at least 2; up to 4 matching holes) |
| M2×6 screws | 0 | 2 | Optional Arduino bracket to speaker mount |
| Pi/display mounting screws | 4 | 4 | Supplied with display; thread/length not specified in guide |
| Printed speaker washers | 6 | 6 | `Speaker_WasherPRINT6x.stl` |

The Arduino pinion presses onto the motor shaft and does not use the separate M3 axle screw or lock nut.

Avoid longer substitute screws: proud gearbox-top screws can hit the neck mount. Pivot fasteners must retain the assembly while permitting free motion.

## Tools

The guides call for 1.5 mm, 2 mm, 2.5 mm and 3 mm hex keys and a Phillips screwdriver. Match the key to the actual screw head. Also have a microSD writer, computer with SSH, support-removal tools and a way to measure fit and verify wiring.
