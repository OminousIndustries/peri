# Parts list

Parts for the Raspberry Pi 4B and Arduino Nano build shown in the assembly guides.

## Electronics and cables

| Quantity | Part | Fit/setup notes |
|---|---|---|
| 1 | Raspberry Pi 4B | Reference case and guide use this board; Pi 3/5 fit and cabling need separate checks |
| 1 | Waveshare **4inch DSI LCD (C)** | Round, 720×720, capacitive touch; use its mounting screws, DSI ribbon and 4-pin power/I2C lead |
| 1 | [Waveshare WM8960 Audio HAT](https://www.waveshare.com/product/wm8960-audio-hat.htm), SKU 15668 | 40-pin GPIO HAT, stereo microphones and speaker outputs; available separately or bundled with speakers |
| 2 speaker enclosures total | [Waveshare 14595, 8Ω 5W speakers](https://www.waveshare.com/product/accessories/8ohm-5w-speaker.htm) | Left/right enclosures used in the owner's tested build; supplied with that HAT kit, also available separately |
| 1 | Arduino Nano, ATmega328P/compatible | Motor controller; verify bootloader when flashing |
| 1 | ULN2003 stepper-driver board | Match the five-wire motor connector |
| 1 | 28BYJ-48 **5 V** stepper | Reference gear ratio and firmware use this geared motor |
| 1 | USB cable, Nano to Pi | Data-capable; connector depends on your Nano |
| 1 set | Nano/driver jumper wires | IN1–IN4, 5 V and ground; lengths depend on build |
| 1 | Pi 4 compatible USB-C supply | Use right-angle USB-C adapter; verify motor power budget on physical build |
| 1 | Right-angle USB-C adapter | Compare orientation with PDF pages 18 and 23 |
| 1 | microSD card | Room for a 64-bit OS and updates; 32 GB is a practical starting size |
| 1 | Network connection | Wi-Fi or Ethernet with internet |

Compare the [display manufacturer's connections](https://www.waveshare.com/wiki/4inch_DSI_LCD_(C)) and [audio HAT documentation](https://www.waveshare.com/wiki/WM8960_Audio_HAT) with your board revision. The HAT uses I2C on BCM 2/3 and I2S on BCM 18/19/20/21; its bridge speaker outputs must not be connected to a common ground.

You need two speaker enclosures total. Some WM8960 HAT kits include both, so check the package contents before ordering additional speakers. The 5 W figure is the speaker rating; the HAT's specified output is 1 W per channel into 8Ω.

## Printed parts

See the [print quantities](../prints/README.md). The reference build uses the common parts and the Arduino variant.

## Fasteners for the documented Arduino build

These totals combine the [Arduino guide](ArduinoAssemblyGuide.pdf) for the base, motor and Nano bracket with the [main guide](AssemblyGuide.pdf) for the speaker mounts, neck, display and enclosure. They count the pictured steps; verify fit and the hardware supplied with your display.

| Fastener | Count in illustrated steps | Uses |
|---|---:|---|
| M3×8 screws | 13 | Motor mount (4), posts (8), rear join (1) |
| M3×10 screws | 7 | Speaker mounts (4), neck (3) |
| M3×12 screws | 5 | Big gear/neck mount (3), rear top covers (2) |
| M3×16 screws | 3 | Gearbox top through bottom to square posts |
| M3×20 screw | 1 | Main neck pivot |
| M3×25 screws | 8 | Motor (2), speaker attachments and front cover retention (6) |
| M3 standard nuts | 35 | Speaker mounts (4), motor (2), motor mount (4), posts (8), rear join (1), gearbox top (3), big gear/neck (3), neck (3), speakers (6), pivot (1) |
| M4×8 screws | 3 | Display to neck |
| M2×4 screws | At least 8 | Speaker grilles (6), ULN2003 board (at least 2; up to 4 matching holes) |
| M2×6 screws | 2 | Arduino bracket to speaker mount |
| Pi/display mounting screws | 4 | Supplied with display; thread/length not specified in guide |
| Printed speaker washers | 6 | `Speaker_WasherPRINT6x.stl` |

The Arduino pinion presses onto the motor shaft and does not use an M3 axle screw or lock nut. These quantities are for the Arduino build; the older unmotorized variant in the main PDF uses different fasteners.

Avoid longer substitute screws: proud gearbox-top screws can hit the neck mount. Pivot fasteners must retain the assembly while permitting free motion.

## Tools

The guides call for 1.5 mm, 2 mm, 2.5 mm and 3 mm hex keys and a Phillips screwdriver. Match the key to the actual screw head. Also have a microSD writer, computer with SSH, support-removal tools and a way to measure fit and verify wiring.
