# Waymate display fonts

The firmware links only the generated C bitmap assets in `../moto_font_*.c`.
The source faces in `source/` exist only for reproducible regeneration with
`scripts/generate_fonts.sh`; they are not included in either firmware or app
partitions. Generated glyphs use 4 bpp, target-size rasterization, and explicit
UI subsets. Noto Sans SC is assigned to the CJK fallback but its LVGL resource
symbols use Waymate names, respecting its reserved name `Source`.

Sources: Inter Medium and SemiBold by The Inter Project Authors, copyright
2020; Noto Sans SC Medium by Adobe, copyright 2014-2021. The full SIL OFL 1.1
notices and copyright holders are retained in `licenses/`.

The Noto subset currently contains the fixed Chinese UI strings and reviewed
preview samples. Arbitrary runtime Chinese road names and media metadata may
contain unsupported glyphs; this bitmap subset does not promise full CJK
coverage.
