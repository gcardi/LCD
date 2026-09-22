# Programming the Tang Nano 9K

The verified configuration for this project is:

- device: `GW1NR-9C` (part number `GW1NR-LV9QN88PC6/I5`);
- JTAG ID detected: `0x1100481B`;
- cable for `programmer_cli`: `--cable-index 5` (WINUSB) under Zadig driver,
  `1` (FT2CH) under FTDI driver;
- `2` operation: volatile SRAM programming;
- bitstream: `impl/pnr/LCD.fs`;
- interface driver 0: **WinUSB**, put with Zadig.

Since September 10, 2026 the two programming scripts use **openFPGALoader**,
the only path that produces a working board here: `programmer_cli` remains
reachable with `-UseGowinProgrammer`, but on this machine it leaves User
Flash fonts that fail the CRC. The section "Why only openFPGALoader remains
on this machine" below reports the tests; the section on Zadig covers how to
change drivers.

From PowerShell, in the project directory:

```powershell
.\program_tang_nano_sram.ps1
```

To use another `.fs` file:

```powershell
.\program_tang_nano_sram.ps1 -Bitstream "path\other_file.fs"
```

The bitstream is not produced by this script: it must be generated first with
`.\build.ps1`, or with synthesis and place-and-route from the Gowin EDA GUI.
`.\build.ps1 -Program` runs both steps in sequence and only programs
afterward if the timing gate has passed; see [VERIFICATION.md](VERIFICATION.md).

The script raises an exception if the indicated bitstream does not exist, or
if `programmer_cli` returns a non-zero code.

Unlike `build.ps1`, which looks for the Gowin installation under
`C:\Program Files\Gowin`, here the path of `programmer_cli.exe` is fixed and
points to `Gowin_V1.9.12.01_x64`. With another version installed, pass
`-ProgrammerPath`, or update the default path in
`tools/Invoke-GowinProgrammer.ps1`, which is now the only place it appears.

## Two traps of programmer_cli

Both scripts go through `tools/Invoke-GowinProgrammer.ps1`, which exists
to work around two behaviors discovered on September 10, 2026:

- **`programmer_cli` does not start if the environment defines
  `PYTHONIOENCODING`.** It is a frozen Python executable, and its interpreter
  rejects the form `utf-8:surrogateescape`: it dies with `0xC0000409` and
  `Fatal Python error: Py_Initialize` before even opening the cable. This is
  almost never seen from an interactive PowerShell, but it affects any
  automation that exports that variable. The helper unsets it for the
  duration of the call and restores it afterward.
- **`programmer_cli` exits with code 0 even when printing `Error: Verify
  Failed`.** Checking `$LASTEXITCODE` alone would therefore report a board
  "programmed and verified" when it never was. The helper also inspects the
  output and raises an exception if it finds an error.

SRAM programming is lost when the board is powered off.

To make both the bitstream and the three User Flash fonts persistent:

```powershell
.\program_tang_nano_flash.ps1
```

This passes `impl/pnr/LCD.fs` and the fonts together, and with
`-UseGowinProgrammer` uses Gowin operation 6 (`embFlash Erase,Program,Verify`)
instead of openFPGALoader. In both cases the font file is
`user_flash_fonts.bin`: the script checks that it starts with `LCDF` before
writing, and for the Gowin path transcribes it to a temporary `.fi`, because
`programmer_cli` only reads that format.

The build sets `-bit_security 0`, which is required to allow Embedded Flash
verification during development. Bitstream compression turns off with
`.\build.ps1 -NoCompress`, but disabling it is not needed to pass the test:
tested on September 10, 2026, the uncompressed bitstream fails exactly like
the compressed one. Keep compression active.

## `Verify Failed` doesn't mean anything on its own

`programmer_cli` **always** fails Embedded Flash verification on this
project, printing `Error: Program failed` and often exiting with code 1.

By September 10, 2026, I had concluded this was a harmless false alarm.
**That was wrong.** After one of those programming runs the board no longer
started: FPGA not configured, `User Code 0x00000000`, and the MCU logged
`ready_attempts = 167` in two seconds without ever receiving a reply. Other
times, with the same message, the flash started fine. The message **does
not correlate** with the outcome: it must be verified each time.

The two halves are checked in different ways.

**User Flash, i.e. the fonts — immediately, without power-cycling.** Just
configure the logic and look at the screen:

```powershell
.\program_tang_nano_sram.ps1
# then MCU reset
```

If the text appears, the fonts are correct byte by byte: `FontStore` checks
the CRC-32 over the 25,152 bytes before accepting any command. If instead
`g_lcd_error.phase` is 11, the font image is invalid.

**Bitstream — only with a power cycle.** Immediately after programming, the
device remains unconfigured, so `Read Device Codes` reports
`User Code 0x00000000` and the CRC error bit, which looks like an empty
flash but proves nothing. Unplug and replug the power, then read again: if
the User Code is no longer `0x00000000`, the flash is good. The reset button
is not enough here, because it triggers a logical reset and does not cause
reconfiguration.

## Programming without `--fiFile` deletes the fonts

It's worth repeating because it really happened: a bitstream-only
programming run, made to isolate a problem, deleted User Flash. The symptom
is consistent — `g_lcd_error.phase = 11`, status byte `E2` instead of `C3` —
and it is fixed by reprogramming with `program_tang_nano_flash.ps1`, which
always passes both files.

To put the board back into operation immediately, without waiting,
`program_tang_nano_sram.ps1` configures it volatile-only in a few seconds.

The generator outputs `user_flash_fonts.bin`, a `.mem` for simulations, and
a JSON manifest. The `.fi` is no longer among the versioned files: it is a
transcription of the image, not a source, and the script produces it on
demand with `--fi-from`. The addresses inside it are hexadecimal without a
prefix.

## Embedded Flash and User Flash are the same array

On the GW1NR-9C, the bitstream and User Flash are not two distinct
memories: they occupy the same internal flash. This is visible in the
artifacts the programmer leaves in `impl/pnr/`: `LCD.bin` measures 444,426
bytes, while the merged image `merged_withUserFlash.bin` measures 524,288.
The difference, about 78 KB, is exactly the User Flash appended after the
bitstream.

From here comes the only operational rule that must be respected:

- **every** programming of the Embedded Flash *without* `--fiFile` deletes
  the fonts. It is not a fault and gives no error: `FontStore` can no longer
  find the `LCDF` header, raises `fonts_error`, and from that point the
  status byte of the text command `B8` stays `E2`. On the STM32 side, the
  demo fails with `g_lcd_fpga_text_demo_state = 3`. This is why
  `program_tang_nano_flash.ps1` should always be used, never
  `programmer_cli` by hand;
- `program_tang_nano_sram.ps1` (operation 2) is safe instead: it only
  touches the configuration SRAM and leaves the fonts already programmed in
  flash intact. It's the right way to iterate on the RTL without
  rewriting the fonts every time.

After successful programming, text rendering becomes available a few
milliseconds after reset: `FontStore` checks the CRC-32 over the 25,152
bytes of the image before accepting commands. The STM32 firmware already
waits for this window, up to one second, in `text_ready()`.

## Programming with openFPGALoader: you need the `.bin`, not the `.fi`

openFPGALoader is the default choice of the two scripts, and it's what
produced the first successful flash boot with fonts on September 10, 2026.
The commands the scripts execute are these:

```powershell
# flash: bitstream + font
openFPGALoader -b tangnano9k --write-flash impl\pnr\LCD.fs --user-flash fonts\user_flash_fonts.bin
# SRAM: w/o --write-flash
openFPGALoader -b tangnano9k impl\pnr\LCD.fs
```

The font file to pass is **`user_flash_fonts.bin`**, the raw binary
image — and it is the only versioned font artifact, precisely so there is no
second file that could be the wrong one. Passing the `.fi` instead also
prints `CRC check: Success`, but it does not work: openFPGALoader has no
parser for Gowin's `.fi` format — only `FsParser` and `RawParser` exist in
the binary — and writes the file byte for byte as-is. The `.fi` is ASCII
text starting with ten lines of `//Copyright...`, so User Flash ends up with
that comment instead of the `LCDF` header, and `FontStore` rejects the
image. The symptom is the same as programming without `--fiFile`:
`g_lcd_error.phase = 11`.

The final `CRC check: Success` doesn't contradict any of this, because it
covers **only the bitstream**: openFPGALoader's `--verify` applies to
external SPI flash, and the internal User Flash is never read back by
anyone. The only way to verify it remains the CRC-32 that `FontStore`
calculates at runtime.

It's worth noting that with the same command the programmer prints two
distinct progress bars, one for the bitstream and a much shorter one for
User Flash: if the second one is missing, the fonts were not written.

## Only one font file, and why

The two programmers expect different formats and neither notices when it
receives the wrong one: they just write, and the fault only shows up as
invalid fonts on the board. To avoid leaving that choice to whoever
programs the board, the repository has **only one font artifact**,
`fonts/user_flash_fonts.bin`, and the `.fi` for Gowin is transcribed on the
fly into a temporary file:

```powershell
python .\tools\generate_user_flash_fonts.py --fi-from .\fonts\user_flash_fonts.bin --fi-out out.fi
```

The transcription is deterministic and checked byte by byte against the
`.fi` that was released previously. Additionally, `program_tang_nano_flash.ps1`
checks that the image begins with `LCDF` before writing: the same check
that `FontStore` does on board, but before the damage instead of after.

The fact that `programmer_cli` cannot ingest the binary is established
inside `JTAGLoading.exe`, the module that does the work: it exposes a class
`UserFlashFile` with a `comments` attribute, a line parser (`readlines`,
`startswith`), and recognition of the `//File Format` line. It's an ASCII
parser. The `//File Format: Hex` line has `Bin` as an alternative, which is
nonetheless not raw binary: the 32 bits are written as 32 characters `0`
and `1`.

## Because only openFPGALoader remains on this machine

On September 10, 2026, the two paths were tested against each other,
changing drivers on purpose. The outcome is that `-UseGowinProgrammer`
**does not produce a working board here**. It stays in the script for other
machines, but it should not be used on this one. The facts, in the order
they emerged:

**Going back to the FTDI driver makes things worse.** Uninstalling WinUSB
with "delete the driver software," Windows Update installs the *current*
FTDI driver, not the one that was there before: version 2.12.36.20 from
October 2024 arrived here. Gowin, however, ships with a `ftd2xx.dll` version
2.12.24 from October 2016, and the two don't mix: `programmer_cli` with
FTDI-based cables gives no error, it **runs forever in circles** without
printing a line, burning CPU inside `ftd2xx.dll`. It's not a bad cable
index: the indexes that don't use FTDI respond in 0.15 s with an honest
`Cable failed to open`.

**The WINUSB cable works, though, and opens the way to a single driver.**
`programmer_cli`'s list of cable types is: 0 GWU2X, 1/3/4 FTDI based, 2
parallel port, **5 WINUSB**. With Zadig's WinUSB installed and
`--cable-index 5`, `programmer_cli` reads the codes in 0.26 s. This is why
the scripts accept `-CableIndex`: 5 is needed under Zadig, not 1.

**But the flash write is wrong, in both halves.** With that path,
programming runs to completion, then fails verification as always. The
fonts it leaves in User Flash fail CRC-32 (`g_lcd_error.phase = 11`), and
the bitstream is no better: after a power cycle the device remains **not
configured**, `User Code 0x00000000`, and status `0x00031421` with the CRC
error bit set. This is the proof, once obtained on September 10, 2026, that
settles the question: it's not just the fonts that are lost.

The counterproof is clean, because only one variable changes: on the same
board, with the same WinUSB driver and the same `user_flash_fonts.bin`
image, openFPGALoader leaves `phase = 0` and the text drawn. It's not the
board, it's not the driver, and it's not the image: it's `programmer_cli`.

**What works fine, though, is SRAM programming.** Still with WinUSB and
`--cable-index 5`, `program_tang_nano_sram.ps1 -UseGowinProgrammer` loads
the bitstream in 4.5 seconds and the logic starts: the MCU finds the FPGA
ready on the first try, zero mismatches. So for a project that doesn't
write to flash, Gowin Programmer remains perfectly usable on this machine;
it's operation 6 on Embedded Flash that is unreliable.

The command to reproduce the test, if you want to try again tomorrow:

```powershell
.\program_tang_nano_flash.ps1 -UseGowinProgrammer -CableIndex 5
.\program_tang_nano_sram.ps1  -UseGowinProgrammer -CableIndex 5
# then read g_lcd_error.phase again via SWD
```

## Note on using Zadig

### To switch from GowinProgrammer (programmer_cli) to openFPGALoader

The device to modify is JTAG Debugger (Interface 0) — USB interface 0
(MI_00), the JTAG one. If it is bound to the FTDIBUS driver, that's the
problem.

- Close any open Gowin tools.
- Start Zadig as administrator.
- Menu Options → List All Devices (check this, otherwise the two interfaces
  will not appear).
- In the drop-down menu choose JTAG Debugger (Interface 0). Check below that
  the USB ID is 0403 6010 and that the interface is (Interface 0).
- As target driver select WinUSB with the arrows.
- Press Replace Driver and confirm.

⚠️ Do not touch JTAG Debugger (Interface 1). That is interface 1, the one
that provides the COM3 serial port: if you replace that driver, the serial
port is lost.

Two expected effects, both normal:

- `programmer_cli` will stop seeing the cable: from that moment you program
  only with openFPGALoader.
- The screen may go black during replacement, because the device
  re-enumerates itself.

### To go back (to use programmer_cli / Gowin Programmer again)

Zadig doesn't know how to reinstall the FTDI driver, so this goes through
Device Manager instead: find the WinUSB device, uninstall it while ticking
"Delete the driver software", then unplug and reconnect the USB. Windows
puts an FTDI driver back on its own.

⚠️ Attention, tested on September 10, 2026: **the driver that Windows puts
back is not the one that was there before** — it is the current one
downloaded from Windows Update. Here, version 2.12.36.20 from October 2024
came back, and the 2016 `ftd2xx.dll` that ships with Gowin does not hold up
against it: `programmer_cli` with the FTDI cables just spins idle. Going
back therefore does not restore the original state; to actually do so you
would need to manually install a vintage FTDI driver. Before going down
this path, read the section comparing the two programmers above — it leads
nowhere.
