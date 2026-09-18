#!/usr/bin/env python3
"""Build reproducible Gowin FLASH608K font images from Terminus BDF files.

The image also carries the optional boot logo the fabric paints in the centre
of the panel once the framebuffer has been cleared. See docs/BOOT_LOGO.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path


FLASH_BYTES = 304 * 64 * 4
# The image has one canonical form, the raw .bin, and two transcriptions:
#   .bin  what openFPGALoader wants in --user-flash, and what everything else
#         is derived from;
#   .mem  hexadecimal words for the SIMULATION branch of UserFlashReader;
#   .fi   Gowin's ASCII text, the only thing programmer_cli's --fiFile parses.
#         Produced on demand by --fi-from, not kept on disk: see write_fi.
# The two programmers do not accept each other's format, and neither complains
# when given the wrong one. Handing the .fi to openFPGALoader cost a wrong
# diagnosis on 10 September 2026: it writes the text byte for byte, so the fonts
# came out invalid, and since the text runs about four times the payload it also
# overflowed the User Flash past ~18 KB, which looked like a capacity limit
# shared with the bitstream. It was not one.
HEADER_BYTES = 64
MAGIC = b"LCDF"
# Version 3 adds RLE RGB565 boot-logo support. FontStore checks
# the version word exactly, so an image and a bitstream of different versions
# refuse each other instead of drawing from a layout that has moved. They are
# programmed together anyway: see docs/PROGRAMMING.md.
VERSION = 3
# The logo lives in its own self-describing section rather than in the header,
# where only its byte offset is kept. Geometry travels with the pixels, so the
# fabric reads the size it is actually about to draw.
LOGO_MAGIC = b"LGO1"
LOGO_HEADER_BYTES = 16
LOGO_FORMAT_RGB565_RLE = 2
# The renderer can decode an odd RLE row, but keeping logos even-wide preserves
# the old raw-RGB565 contract and keeps every source asset interchangeable.
LOGO_WIDTH_ALIGN = 2
# Clipping in TextRenderer is what the panel measures; a logo wider or taller
# than the panel would be silently cropped, so it is refused here instead.
PANEL_WIDTH = 480
PANEL_HEIGHT = 272
CODEPOINTS = tuple(range(0x20, 0x7F)) + tuple(range(0xA0, 0x100)) + (
    0x20AC, 0x2190, 0x2191, 0x2192, 0x2193
)
FONT_SPECS = (
    (0, 8, 16, "ter-u16n.bdf"),
    (1, 12, 24, "ter-u24n.bdf"),
    (2, 16, 32, "ter-u32n.bdf"),
)


def parse_bdf(path: Path, width: int, height: int) -> dict[int, bytes]:
    glyphs: dict[int, bytes] = {}
    encoding: int | None = None
    bitmap: list[bytes] | None = None
    row_bytes = (width + 7) // 8
    for line in path.read_text(encoding="ascii").splitlines():
        if line.startswith("ENCODING "):
            encoding = int(line.split()[1])
        elif line.startswith("BBX ") and encoding in CODEPOINTS:
            actual_width, actual_height = map(int, line.split()[1:3])
            if (actual_width, actual_height) != (width, height):
                raise ValueError(f"{path}: U+{encoding:04X} has unexpected BBX")
        elif line == "BITMAP" and encoding in CODEPOINTS:
            bitmap = []
        elif line == "ENDCHAR":
            if encoding in CODEPOINTS:
                if bitmap is None or len(bitmap) != height:
                    raise ValueError(f"{path}: U+{encoding:04X} row count")
                glyphs[encoding] = b"".join(bitmap)
            encoding = None
            bitmap = None
        elif bitmap is not None:
            row = bytes.fromhex(line)
            if len(row) != row_bytes:
                raise ValueError(f"{path}: U+{encoding:04X} row width")
            bitmap.append(row)
    missing = [cp for cp in CODEPOINTS if cp not in glyphs]
    if missing:
        raise ValueError(f"{path}: missing " + ", ".join(f"U+{cp:04X}" for cp in missing))
    return glyphs


def build_logo(path: Path) -> tuple[bytes, dict[str, object]]:
    """Convert an image into an RLE RGB565 logo section, opaque over black.

    Alpha is composited here rather than carried into the flash: the fabric
    draws the logo as a plain rectangle of pixels, with no mask and no read of
    what is already in the framebuffer.
    """
    from PIL import Image

    source = Image.open(path)
    width, height = source.size
    if width % LOGO_WIDTH_ALIGN:
        raise ValueError(f"{path}: width {width} is odd; a flash word holds two pixels")
    if width > PANEL_WIDTH or height > PANEL_HEIGHT:
        raise ValueError(f"{path}: {width}x{height} does not fit {PANEL_WIDTH}x{PANEL_HEIGHT}")
    if width == 0 or height == 0:
        raise ValueError(f"{path}: empty image")

    rgba = source.convert("RGBA")
    flattened = Image.alpha_composite(Image.new("RGBA", rgba.size, (0, 0, 0, 255)), rgba)
    rgb = flattened.convert("RGB")

    # Centring is settled here, not in RTL, so moving or resizing the logo
    # needs a regenerated image and not a resynthesis.
    origin_x = (PANEL_WIDTH - width) // 2
    origin_y = (PANEL_HEIGHT - height) // 2

    raw = rgb.tobytes()
    pixels: list[int] = []
    for index in range(0, len(raw), 3):
        red, green, blue = raw[index], raw[index + 1], raw[index + 2]
        # Round to nearest representable level instead of truncating, so the
        # top of each channel reaches full scale and white stays white.
        pixel = ((min(255, red + 4) >> 3) << 11) | \
                ((min(255, green + 2) >> 2) << 5) | \
                (min(255, blue + 4) >> 3)
        pixels.append(pixel)

    # One 32-bit word is { RGB565 colour, 16-bit run length }, little-endian
    # in User Flash.  Runs cross row boundaries safely: the FPGA consumes one
    # decoded pixel for every selected panel pixel.  The black background of
    # boot logos is therefore virtually free while opaque coloured artwork is
    # still lossless.
    payload = bytearray()
    run_colour = pixels[0]
    run_length = 0
    for pixel in pixels:
        if pixel == run_colour and run_length < 0xFFFF:
            run_length += 1
        else:
            payload.extend(struct.pack("<HH", run_length, run_colour))
            run_colour = pixel
            run_length = 1
    payload.extend(struct.pack("<HH", run_length, run_colour))

    section = bytearray(LOGO_HEADER_BYTES)
    section[0:4] = LOGO_MAGIC
    struct.pack_into("<HHIHH", section, 4, width, height, LOGO_FORMAT_RGB565_RLE,
                     origin_x, origin_y)
    section.extend(payload)

    manifest = {
        "source": path.name,
        "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest().upper(),
        "width": width,
        "height": height,
        "format": "RGB565-RLE",
        "header_bytes": LOGO_HEADER_BYTES,
        "raw_pixel_bytes": 2 * width * height,
        "encoded_bytes": len(payload),
        "rle_words": len(payload) // 4,
        "origin_x": origin_x,
        "origin_y": origin_y,
        "distinct_colors": len(set(pixels)),
    }
    return bytes(section), manifest


def build_image(source_dir: Path, logo_path: Path | None = None) -> tuple[bytes, dict[str, object]]:
    image = bytearray(HEADER_BYTES)
    fonts: list[dict[str, object]] = []
    directory = bytearray()
    for font_id, width, height, filename in FONT_SPECS:
        path = source_dir / filename
        glyphs = parse_bdf(path, width, height)
        offset = len(image)
        row_bytes = (width + 7) // 8
        for codepoint in CODEPOINTS:
            image.extend(glyphs[codepoint])
        fonts.append({
            "font_id": font_id,
            "width": width,
            "height": height,
            "row_bytes": row_bytes,
            "glyph_count": len(CODEPOINTS),
            "data_offset": offset,
            "data_bytes": len(CODEPOINTS) * height * row_bytes,
            "source": filename,
            "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest().upper(),
        })
        directory.extend(bytes((font_id, width, height, row_bytes)))
        directory.extend(struct.pack("<I", offset))

    # The logo goes last so the font offsets, which TextRenderer holds as
    # constants, do not move when the logo is added, changed or dropped.
    logo_offset = 0
    logo_manifest: dict[str, object] | None = None
    if logo_path is not None:
        section, logo_manifest = build_logo(logo_path)
        assert len(image) % 4 == 0, "logo section must start on a flash word"
        logo_offset = len(image)
        logo_manifest["section_offset"] = logo_offset
        image.extend(section)

    if len(image) > FLASH_BYTES:
        raise ValueError("font image exceeds FLASH608K")
    payload_crc = zlib.crc32(image[HEADER_BYTES:]) & 0xFFFFFFFF
    header = bytearray(HEADER_BYTES)
    header[0:4] = MAGIC
    struct.pack_into("<HHII", header, 4, VERSION, HEADER_BYTES, len(image), payload_crc)
    struct.pack_into("<HBBI", header, 16, len(CODEPOINTS), len(FONT_SPECS), 1, 0x00010001)
    # Header word 6: byte offset of the logo section, zero when there is none.
    struct.pack_into("<I", header, 24, logo_offset)
    header[32:32 + len(directory)] = directory
    image[0:HEADER_BYTES] = header
    manifest: dict[str, object] = {
        "format": "LCD User Flash Fonts",
        "magic": MAGIC.decode("ascii"),
        "version": VERSION,
        "flash_bytes": FLASH_BYTES,
        "image_bytes": len(image),
        "free_bytes": FLASH_BYTES - len(image),
        "payload_crc32": f"{payload_crc:08X}",
        "glyph_count": len(CODEPOINTS),
        "encoding": "UTF-8 subset: ASCII printable, Latin-1, euro, arrows",
        "fonts": fonts,
        "logo": logo_manifest,
    }
    return bytes(image), manifest


def write_mem(path: Path, image: bytes) -> None:
    padded = image + bytes(FLASH_BYTES - len(image))
    words = [struct.unpack_from("<I", padded, offset)[0]
             for offset in range(0, len(padded), 4)]
    path.write_text("\n".join(f"{word:08X}" for word in words) + "\n",
                    encoding="ascii", newline="\n")


def write_fi(path: Path, image: bytes) -> None:
    padded = image + bytes((-len(image)) % 4)
    lines = [
        "//Copyright (C)2014-2024 Gowin Semiconductor Corporation.",
        "//All rights reserved.",
        "//File Title: User Flash Initialization File",
        "//Tool Version: V1.9.10(64-bit)",
        "//Part Number: GW1NR-LV9QN88PC6/I5",
        "//Device-package: GW1NR-9-QFN88P",
        "//Device Version: C",
        "//Flash Type: FLASH608K",
        "//File Format: Hex",
        "//Created Time: generated by tools/generate_user_flash_fonts.py",
    ]
    for offset in range(0, len(padded), 4):
        word = struct.unpack_from("<I", padded, offset)[0]
        linear = offset // 4
        x_address, y_address = divmod(linear, 64)
        # Addresses in .fi files are hexadecimal without a 0x prefix.
        lines.append(f"[{x_address:X}:{y_address:X}] {word:08X}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path, nargs="?",
                        help="directory holding the Terminus BDF sources")
    parser.add_argument("output_dir", type=Path, nargs="?",
                        help="where to write the .bin, .mem and .json")
    parser.add_argument("--logo", type=Path, metavar="IMAGE",
                        help="boot logo to embed, converted to RGB565 and "
                             "centred on the panel; anything Pillow reads")
    parser.add_argument("--fi-from", type=Path, metavar="IMAGE.bin",
                        help="skip generation and transcribe an existing image "
                             "into the Gowin .fi text that programmer_cli wants")
    parser.add_argument("--fi-out", type=Path, metavar="OUT.fi",
                        help="destination of --fi-from")
    args = parser.parse_args()

    # The .fi is not a source file: it is a transcription of the image, so it is
    # produced on demand next to the programmer that needs it rather than kept
    # in the repository where it could go stale or be handed to the wrong tool.
    if args.fi_from or args.fi_out:
        if not (args.fi_from and args.fi_out):
            parser.error("--fi-from and --fi-out go together")
        image = args.fi_from.read_bytes()
        if image[:4] != MAGIC:
            parser.error(f"{args.fi_from} does not start with {MAGIC.decode()}")
        write_fi(args.fi_out, image)
        print(f"transcribed {len(image)} bytes into {args.fi_out}")
        return

    if not (args.source_dir and args.output_dir):
        parser.error("source_dir and output_dir are required")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    image, manifest = build_image(args.source_dir, args.logo)
    (args.output_dir / "user_flash_fonts.bin").write_bytes(image)
    write_mem(args.output_dir / "user_flash_fonts.mem", image)
    (args.output_dir / "user_flash_fonts.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="ascii", newline="\n")
    logo = manifest["logo"]
    if logo:
        print(f"logo {logo['width']}x{logo['height']} at "
             f"({logo['origin_x']},{logo['origin_y']}), "
              f"{logo['encoded_bytes']} encoded bytes "
              f"({logo['raw_pixel_bytes']} raw), {logo['distinct_colors']} colours")
    print(f"generated {len(image)} bytes; {FLASH_BYTES-len(image)} bytes free")


if __name__ == "__main__":
    main()
