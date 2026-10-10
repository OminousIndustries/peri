# Print the parts

The 23 STL files are in this folder. They use millimeters: import at **100% / 1:1** and check dimensions in your slicer.

The reference Peri build uses the **Arduino** variant. Print the common parts below plus the four `Arduino_Build/` parts. Do not also print the older `NO_Arduino/` gearbox bottom, pinion or crossbrace for that build.

## Common parts

| File | Quantity |
|---|---:|
| `Base_Left.stl` | 1 |
| `Base_Right.stl` | 1 |
| `Top_Cover_Left.stl` | 1 |
| `Top_Cover_Right.stl` | 1 |
| `Speaker_Grill_Left.stl` | 1 |
| `Speaker_Grill_Right.stl` | 1 |
| `Speaker_Mount_Left.stl` | 1 |
| `Speaker_Mount_Right.stl` | 1 |
| `Neck.stl` | 1 |
| `Neck_Mount.stl` | 1 |
| `Big_Gear.stl` | 1 |
| `Gearbox_Top.stl` | 1 |
| `Gear_Top_Cover.stl` | 1 |
| `Gearbox_Mount_4_Round.stl` | 1 |
| `Gearbox_Mount_PRINT3X.stl` | **3** |
| `Speaker_WasherPRINT6x.stl` | **6** |

## Arduino variant

One each of `Arduino_Build/Arduino_Mount.stl`, `Motor_Mount.stl`, `Gearbox_Bottom_Arduino.stl` and `Small_Gear_Arduino.stl`. This gives **27 printed pieces** including the common parts. Follow the [Arduino mounting guide](../docs/ArduinoAssemblyGuide.pdf) and [combined assembly instructions](../docs/ASSEMBLY.md); the [parts list](../docs/PARTS.md) includes its fasteners.

## Older variant, preserved for reference

One each of `NO_Arduino/X_Brace_NOARD.stl`, `Gearbox_Bottom_NOARD.stl` and `Small_Gear_NOARD.stl`, plus common parts. The illustrated guide depicts this mechanism. Peri's preferred firmware/configuration uses the Arduino instead.

## Slicing and fit

Starting settings for test pieces: PLA, a 0.4 mm nozzle, 0.2 mm layers, three walls and 20–30% infill. These settings have not been validated as a complete print profile. Fit-test gears, nut pockets, posts and mating edges before printing the whole case. Gears may benefit from finer layers; settings depend on your printer and material.

Preview orientation and supports in the slicer. Some exports use a deliberate angled print frame: do not confuse that with assembled orientation. Place pieces with stable bed contact and support only where needed; inspect thin grilles, gear teeth and overhangs. Clean supports and elephant-foot edges without removing gear teeth or enlarging precision surfaces unnecessarily.

Check the dimensions of each part in your slicer before printing. The base is split into left and right halves.

Next: [assemble Peri](../docs/ASSEMBLY.md).
