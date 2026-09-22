# Boot logo

On reset, the FPGA draws the logo stored in User Flash before accepting SPI
commands. The MCU is not involved: a visible logo confirms that the
bitstream and the User Flash image are in sync.

![Boot logo](../resources/BootLogo.png)

The versioned source file is `resources/BootLogo.png`. The generator
converts it to RGB565, centers it on the 480x272 panel, and appends it after
the three Terminus font tables. Fonts don't move when the logo changes.

## Current logo and available space

The current logo is **256x144**, centered at **(112, 64)**. A raw RGB565
bitmap would need 73,728 bytes and, together with the fonts, would exceed
the User Flash's 77,824 bytes. This is why the version 3 image uses
**RGB565-RLE**: every 32-bit word holds `{ RGB565 color, run length }`. The
encoding is lossless, and runs can span a row.

With the current PNG, the logo payload is 5,444 bytes (versus 73,728
uncompressed); the complete `fonts/user_flash_fonts.bin` image is 30,612
bytes, leaving 47,212 bytes free. A solid black background compresses very
well; a photographic or noisy logo may not fit, and the generator rejects
it before producing a programmable image.

## Procedure for replacing the logo

This is the complete procedure. For a normal PNG replacement, steps 1-4 and
6 are enough: the format stays version 3, so rebuilding the FPGA isn't
necessary. Step 5 applies only for a format or RTL change.

### 1. Prepare the PNG

Replace `resources/BootLogo.png` with the new file. It must have:

- even width;
- dimensions within 480x272;
- preferably a uniform background or flat areas, for good RLE compression.

Transparency is allowed: it is composited onto black. The logo is opaque
once on the panel — there is no alpha mask in the fabric.

### 2. Check local tools

The only requirement to regenerate the image is Python 3 with Pillow. The
following command must end with `Pillow OK`:

```powershell
python -c "from PIL import Image; print('Pillow OK')"
```

The generator also uses the Terminus submodule's BDF sources, already present
in `third_party/terminus-font-4.49.1-master`. If the clone is new:

```powershell
git submodule update --init --recursive
```

### 3. Rebuild the User Flash

From the repository root, run exactly:

```powershell
python .\tools\generate_user_flash_fonts.py `
  .\third_party\terminus-font-4.49.1-master .\fonts `
  --logo .\resources\BootLogo.png
```

The script reads the PNG with Pillow and produces three consistent artifacts:

| Files | Usage |
|---|---|
| `fonts/user_flash_fonts.bin` | binary image to load with openFPGALoader |
| `fonts/user_flash_fonts.mem` | hex-word copy used by Verilog simulations |
| `fonts/user_flash_fonts.json` | readable manifest: size, CRC, occupancy and RLE data |

Check the printed summary: it must report size, encoded bytes, raw bytes,
and free space. The generator fails outright if the PNG is out of panel
bounds, has an odd width, or the complete image exceeds the User Flash.
Optional further check:

```powershell
Get-Content .\fonts\user_flash_fonts.json | ConvertFrom-Json |
  Select-Object version, image_bytes, free_bytes, logo
```

`version: 3` and the new `width`/`height` must appear, with
`format: RGB565-RLE`.

> Do not omit `--logo`: without it, the generator still produces a valid
> image, just without a logo section.

### 4. Test RTL and image together

```powershell
.\sim\run_spi_sim.ps1
```

The suite also runs `tb_boot_logo`: it independently decodes the RLE from
the `.mem` file, checks that every written pixel matches, that nothing
outside the rectangle is touched, and that `boot_complete` rises only after
drawing finishes. The expected output includes `PASS: boot_logo`.

### 5. When to rebuild the FPGA bitstream

A normal PNG replacement **doesn't** require synthesis: the renderer reads
width, height, position, and format from User Flash. Rebuilding the FPGA is
necessary only if you modify `src/FontStore.sv`, `src/TextRenderer.sv`, or
the image format. Introducing RLE and version 3 was exactly such a case; the
bitstream for this commit had to be rebuilt once:

```powershell
.\build.ps1
```

Gowin EDA (synthesis/place-and-route), oss-cad-suite with Icarus Verilog, and
openFPGALoader are required. `build.ps1` finishes only after the timing gate
passes and produces `impl/pnr/LCD.fs`. Environment details are in
[README.md](../README.md) and [VERIFICATION.md](VERIFICATION.md).

### 6. Program the card

To make the new logo effective at startup, program **together** the
bitstream `impl/pnr/LCD.fs` and `fonts/user_flash_fonts.bin`:

```powershell
.\program_tang_nano_flash.ps1
```

Don't invoke openFPGALoader or Gowin Programmer manually for the bitstream
alone: Embedded Flash and User Flash are parts of the same array, and
writing the bitstream without the User Flash image erases the logo and
fonts. The script checks the `LCDF` header and programs both artifacts.
Wait for both progress bars (bitstream and User Flash), then power-cycle or
reset the board.

On this machine the standard path is openFPGALoader; don't add
`-UseGowinProgrammer` unless there's a specific reason. For wiring, drivers,
and diagnostics see [PROGRAMMING.md](PROGRAMMING.md).

## Format on board

The `LCDF` header is now version **3**. Word 6 (offset 24, little endian)
holds the byte offset of the logo section, or zero if there is none. The
section layout is:

| Offset | Field |
|---:|---|
| 0..3 | magic `LGO1` |
| 4..5 | width |
| 6..7 | height |
| 8..11 | format: `2` = RGB565-RLE |
| 12..13 | origin x |
| 14..15 | origin y |
| 16.. | little-endian words: 16-bit run length, then 16-bit RGB565 color |

`FontStore` first checks the CRC-32 of the whole image, then the magic,
geometry, format, and position of the logo. If the logo descriptor is
invalid, the fonts stay usable but the logo is skipped. If the image
version doesn't match the bitstream's, the whole image is rejected instead:
this prevents an incompatible layout from being misread.

`TextRenderer` uses the same burst path as the fill and decodes one pixel
per selected column of the rectangle. `boot_complete` is raised only after
the last burst; until then the SPI side stays `busy`, so the first MCU
command can't overlap with drawing the logo.

## References

- [PROGRAMMING.md](PROGRAMMING.md): Persistent programming and the difference between
  Embedded Flash and User Flash.
- [VERIFICATION.md](VERIFICATION.md): Simulation environment and timing gate.
