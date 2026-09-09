# Terminus 12x24 source used by the STM32 font generator

This directory intentionally contains only the files needed to reproduce the
embedded bitmap table:

- `ter-u24n.bdf`, the 12x24 normal Unicode BDF;
- `OFL.TXT`, the SIL Open Font License 1.1 and Reserved Font Name notice;
- `AUTHORS`, the upstream author list.

They come from the `mikebeaton/terminus-font-4.49.1` GitHub mirror of the
[official Terminus Font 4.49.1 release](https://sourceforge.net/projects/terminus-font/files/terminus-font-4.49/).
The mirror archive was used because SourceForge returned its HTML interstitial
instead of the archive to the command-line client.

Source checksums:

```text
ter-u24n.bdf  FF640E9E097983355E8F70ED8FB645BD850184A0D590DE17F6FC9CEEC1BF8EAF
OFL.TXT       C14F8D795784A547EA35E69C51DEE2957BB71A1CDB492EC5321E4B61D3D97630
```

`tools/generate_lcd_font.py` extracts a subset into the unnamed firmware table
`lcd_font_12x24_bitmap`. “Terminus Font” is a Reserved Font Name, so it is used
only to identify the unchanged upstream source and is not assigned to the
derived embedded table.
