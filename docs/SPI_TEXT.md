# SPI B8 text command

Text opcode reference. `B8` shares the queue and renderer with `B9`
(fill/lines); while either is executing, the other must wait. `B9`
remains available even without valid fonts. For all opcodes and APIs,
including the horizontal/vertical lines drawn via `B9`, see
[GRAPHICS_COMMANDS.md](GRAPHICS_COMMANDS.md).

The FPGA renderer uses three fixed-cell Terminus fonts stored in the
GW1NR-9C's User Flash. The image occupies 25,152 of the 77,824 available
bytes and contains 196 glyphs per size:

| font_id | Cell | Byte/glyph |
|---:|---|---:|
| 0 | 8x16 | 16 |
| 1 | 12x24 | 48 |
| 2 | 16x32 | 64 |

On September 10, 2026, these three fonts were removed and put back
within a few hours, and the story is worth telling because the first
diagnosis was wrong. A bisection search seemed to show that the
bitstream and the User Flash, sharing the same physical array, could not
both fit once fonts exceeded 18,432 bytes. In reality, that bisection was
feeding openFPGALoader `.fi` files, which are ASCII text and take up
roughly four times the payload size: the measured threshold falls
exactly where the `.fi` text exceeds the User Flash's 77,824 bytes
(18,432 → 76,173 bytes, 19,456 → 80,461 bytes). It was never a capacity
conflict — it was the wrong file format, the same mistake that made the
font CRC check fail. Passing the raw binary image instead lets the full
25,152 bytes be programmed, and the FPGA boots from flash without
complaint. See [PROGRAMMING.md](PROGRAMMING.md).

The subset includes printable ASCII, Latin-1, the euro sign, and the
four arrows. A codepoint that is not present is replaced by `?`. The BDF
Terminus sources are distributed under the SIL Open Font License 1.1,
included under `third_party`.

## Package

All multibyte fields are big endian. The length field counts UTF-8
bytes, from 0 to 64; the C string's zero terminator is not transmitted.

| Offset | Field |
|---:|---|
| 0 | opcode `B8` |
| 1 | dummy/status |
| 2 | font_id |
| 3 | flags: bit 0 transparent, bit 1 wrap |
| 4..5 | x |
| 6..7 | y |
| 8..9 | box width; zero = up to the right edge |
| 10..11 | box height; zero = up to the bottom edge |
| 12..13 | foreground RGB565 |
| 14..15 | background RGB565 |
| 16 | UTF-8 length |
| 17.. | text |
| 17+N..18+N | CRC16-CCITT, init `FFFF`, polynomial `1021` |
| 19+N | commit `A6` |
| 20+N | dummy to read the outcome |

The second byte received reads `C3` when the queue is free, `00` while
text is rendering, and `E2` until the font image is validated or if it
fails the CRC-32 check. The byte received after the commit reads `AC` if
the command was accepted, `E1` otherwise.

Clipping to the box and to the screen is always active. A new line starts
only on `\n`, or automatically when the wrap flag is set. Without wrap,
the part of the string to the right of the box is discarded.

## Generation and programming

```powershell
python tools\generate_user_flash_fonts.py third_party\terminus-font-4.49.1-master fonts
.\build.ps1
.\program_tang_nano_flash.ps1
```

The last step programs the FPGA configuration into Embedded Flash and
the fonts into User Flash. It does not verify them: nothing rereads the
User Flash afterward, and the only proof the fonts are good is the
CRC-32 that FontStore computes at runtime. See
[PROGRAMMING.md](PROGRAMMING.md). For ordinary, volatile bitstream-only
updates, `program_tang_nano_sram.ps1` remains available.

The complete hardware test, including the final state of the FPGA
renderer, is:

First enable `SPI_GPIO_PROBE=1` and `LCD_FPGA_TEXT_DEMO=1` in the MCU
configuration; the runner refuses to test with the GPIO probe disabled.
For a Release build, add `-Preset Release`. Then restore the desired
boot configuration and recompile/reflash.

```powershell
.\stm32\WeAct_H743_SPI\test-hardware.ps1 `
  -SerialNumber <seriale-ST-LINK> -RequireFPGAText
```

On the STM32, `LCD_DrawTextFPGA()` builds the packet, computes the CRC,
waits for acceptance, and returns only after rendering completes.
