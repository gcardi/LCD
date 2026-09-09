# Terminus bitmap sources used by the font generators

This directory intentionally contains only the files needed to reproduce the
fixed-cell bitmap tables:

- `ter-u16n.bdf`, the 8x16 normal Unicode BDF;
- `ter-u24n.bdf`, the 12x24 normal Unicode BDF;
- `ter-u32n.bdf`, the 16x32 normal Unicode BDF;
- `OFL.TXT`, the SIL Open Font License 1.1 and Reserved Font Name notice;
- `AUTHORS`, the upstream author list.

They come from the `mikebeaton/terminus-font-4.49.1` GitHub mirror of the
[official Terminus Font 4.49.1 release](https://sourceforge.net/projects/terminus-font/files/terminus-font-4.49/).
The mirror archive was used because SourceForge returned its HTML interstitial
instead of the archive to the command-line client.

Source checksums:

```text
ter-u16n.bdf  5197662B22BF9F3E68D4AF9F969A7FEFA3EDAE40DD82AE969A147381130FB4AE
ter-u24n.bdf  FF640E9E097983355E8F70ED8FB645BD850184A0D590DE17F6FC9CEEC1BF8EAF
ter-u32n.bdf  5AD01972D58ADFEE75077E2C65BA5947E260043031664CB8AD8F98B5473B23A4
OFL.TXT       C14F8D795784A547EA35E69C51DEE2957BB71A1CDB492EC5321E4B61D3D97630
```

`tools/generate_lcd_font.py` extracts a subset into the unnamed firmware table
`lcd_font_12x24_bitmap`. `tools/generate_user_flash_fonts.py` builds the three
FPGA tables, their manifest and the Gowin `.fi` image. “Terminus Font” is a
Reserved Font Name, so it is used only to identify the unchanged upstream
source and is not assigned to the derived embedded tables.
