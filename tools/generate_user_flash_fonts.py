#!/usr/bin/env python3
"""Build reproducible Gowin FLASH608K font images from Terminus BDF files."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path


FLASH_BYTES = 304 * 64 * 4
# Tre uscite per la stessa immagine, e non sono intercambiabili:
#   .bin  immagine grezza, la vuole openFPGALoader in --user-flash;
#   .fi   testo ASCII nel formato Gowin, lo vuole programmer_cli in --fiFile;
#   .mem  parole esadecimali per il ramo SIMULATION di UserFlashReader.
# Passare il .fi a openFPGALoader non da' errore: non ha un parser per quel
# formato, scrive il testo byte per byte e la scheda si ritrova font non validi.
# E' costato una diagnosi sbagliata il 10 settembre 2026, perche' il .fi occupa
# circa quattro volte il payload e sopra i ~18 KB di font sfonda la User Flash,
# il che sembrava un limite di capacita' condivisa col bitstream. Non lo era.
HEADER_BYTES = 64
MAGIC = b"LCDF"
VERSION = 1
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


def build_image(source_dir: Path) -> tuple[bytes, dict[str, object]]:
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

    if len(image) > FLASH_BYTES:
        raise ValueError("font image exceeds FLASH608K")
    payload_crc = zlib.crc32(image[HEADER_BYTES:]) & 0xFFFFFFFF
    header = bytearray(HEADER_BYTES)
    header[0:4] = MAGIC
    struct.pack_into("<HHII", header, 4, VERSION, HEADER_BYTES, len(image), payload_crc)
    struct.pack_into("<HBBI", header, 16, len(CODEPOINTS), len(FONT_SPECS), 1, 0x00010001)
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
    parser = argparse.ArgumentParser()
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    image, manifest = build_image(args.source_dir)
    (args.output_dir / "user_flash_fonts.bin").write_bytes(image)
    write_mem(args.output_dir / "user_flash_fonts.mem", image)
    write_fi(args.output_dir / "user_flash_fonts.fi", image)
    (args.output_dir / "user_flash_fonts.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="ascii", newline="\n")
    print(f"generated {len(image)} bytes; {FLASH_BYTES-len(image)} bytes free")


if __name__ == "__main__":
    main()
