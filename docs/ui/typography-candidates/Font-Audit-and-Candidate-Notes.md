# Stage C.1 Typography Candidates

This is a comparison set only. No candidate was selected or added to the ESP32 firmware.

## Current LVGL fonts

The 466 × 466 UI canvas is drawn into a circular 1.75-inch display. LVGL lays text out on that square canvas; the display's circular edge remains the final clipping boundary. Labels generally use fixed widths and centered text alignment, while `lv_obj_align` positions each label by LVGL's line box. That makes baseline and font line-height differences visible even where the label box itself is centered.

| Page | Current font and size | Weight / rendering | Alignment, anchor, and clipping notes |
|---|---|---|---|
| Boot | LVGL built-in Montserrat 48 for `WAYMATE`; Montserrat 16 for `POWER OFF` | Built-in bitmap font; text letter spacing 4 px; white outline on wordmark | Both labels use canvas center anchors at y offsets −18 and +35. The wordmark is text rather than the separate geometric W mark used on connection pages. Text remains in the circle. |
| Ready / Connected | Connection W is drawn from line geometry; lifecycle title uses generated Montserrat Medium 32; kicker Montserrat 16; Chinese subtitle uses Source Han Sans SC 16 | Title is medium; custom resources are 4 bpp, direct target-size bitmaps | Centered labels; title at y=231 and subtitle at y=278. The top kicker sits at y=39. The Chinese fallback is a separate 16 px bitmap with a different baseline from Latin. |
| Disconnected / Connecting | Same 32 / 16 / CJK 16 stack as Ready; W/route symbol is vector geometry | Medium title, regular Source Han fallback | Centered, same lifecycle positions. Main status is inside the circle; subtitle width is 280 px. |
| Navigation | Distance: generated Montserrat Medium 56; unit: built-in Montserrat 20; road: Source Han Sans SC Normal 28 with Montserrat 28 fallback; warning labels: Montserrat 16 or generated Medium 32 | Numeric tracking disabled for distance. Road and status use centered fixed-width labels; no scale transform | Distance width 150 px, maneuver icon occupies its own 70 × 65 px box. Road width 230 px at y=280; 28 px Chinese road fallback can dot-truncate. The main hero band is black and safely inside the circle. |
| Rerouting / Off Route | Navigation warning changes to generated Montserrat Medium 32; secondary Chinese lifecycle text uses Source Han 16 | Medium, 4 bpp custom bitmap; no kerning on status font | Centered 250 px warning label near y=55; distance/unit are hidden while warning is active. Text is inside the circle. |
| Arrived | `ARRIVED`: generated Montserrat Medium 32; road: Source Han Sans SC Normal 28; maneuver arrow is vector drawn | Medium heading; regular CJK | Status at y=205 and road at y=250, center aligned. Distance is hidden. |
| Speed | Generated Montserrat Medium 96 digits; built-in Montserrat 20 `km/h` | Native 96 px glyph bitmap, 4 bpp; no run-time scaling. Digit advance is normalized by the UI wrapper; kerning off | Fixed 250 px label centered at the canvas center plus optical y offset; unknown `--` uses its own small optical correction. Arc and ticks remain behind text. |
| Compass | Generated Montserrat Medium 56 degree digits; generated Medium 36 cardinal; built-in 16 compass ring letters; Montserrat 20 speed | Native bitmap sizes; cardinal/numeric kerning off | Heading/cardinal are centered as separate rows with a shared optical stack offset. Ring letters are positioned independently around a 112 px radius. The ring is secondary to the central text. |
| Media | Built-in Montserrat 28 title with Source Han Sans SC 28 fallback; Source Han Sans SC 16 artist; Montserrat 16 source and Montserrat 20 controls | Built-in and custom bitmap fonts; CJK fallback is normal weight | Title has a fixed 280 × 32 px centered one-line box and LVGL dot truncation; artist 260 × 24 px. These widths are safe inside the round display, but a long title can truncate instead of wrapping. |

### Existing font sources and raster settings

- Latin text comes from LVGL's bundled Montserrat faces. The large numeric/status/cardinal assets use `third_party/lvgl/scripts/built_in_font/Montserrat-Medium.ttf`; Chinese comes from `SourceHanSansSC-Normal.otf`.
- Enabled built-ins are 16, 20, 28, and 48 px in `config/lv_conf.h`; built-in Source Han CJK 16 is disabled. There is no bitmap enlargement in the current UI. The generated 32/36/56/96 px C assets were rasterized at those target sizes.
- `scripts/generate_fonts.sh` invokes LVGL `lv_font_conv`, `--bpp 4`, `--format lvgl`, `--no-compress`, and explicit glyph subsets. This is grayscale antialiasing, not RGB subpixel antialiasing. Built-in LVGL font C resources are also native size bitmaps.
- Current custom Latin and CJK files have 4 bpp bitmap data. `moto_font_nav_56` and `moto_font_speed_96` turn kerning off for numeric alignment. Cardinal/status wrappers also turn it off. CJK road/text wrappers retain the generated font's default kerning behavior.
- The Chinese source is Source Han Sans SC, not Noto Sans SC. Product resources are glyph subsets, not the full CJK family. Existing generator covers current route/state vocabulary but did not include `星湖街` and every requested QA phrase. The new Noto candidate samples explicitly cover `星湖街`, `正在重新规划`, `已到达`, and `手机已断开`.

## Candidate setup

The three sheets use the same Stage C LVGL page captures as geometry and replace only the sample text with direct-size font rasterization. This keeps route, arc, symbol, control, and label positions identical across A/B/C. Candidate glyphs are rasterized at their target pixel size with Pillow/FreeType; the circle mask and LVGL capture remain at 466 × 466. The previews are useful for comparing face shape and relative width, but are not a substitute for a final LVGL firmware preview because LVGL's font converter can produce different hinting and line metrics.

Noto Sans SC Medium is the common Chinese fallback for all three candidates. It is generated as a static weight-500 instance for previews. Candidate Latin target weights are:

| Scheme | Hero digits / cardinal | Primary | Secondary |
|---|---|---|---|
| A — Inter | SemiBold 600 | SemiBold 600 | Medium 500 |
| B — Roboto Condensed | Bold 700 | SemiBold 600 | Medium 500 |
| C — IBM Plex Sans | SemiBold 600 | SemiBold 600 | Medium 500 |

For all candidate images the text is centered at its Stage C anchor. A circle-chord safe-width check is applied to each newly drawn label; the check aborts export if the glyph run exceeds the available circular width with a 12 px inset. The long source screenshots for 1.2 km were replaced by the same clean 320 m navigation backdrop before the 1.2 km candidate was composed, so no previous digits can show through.

## Chinese fallback samples

`Chinese-Fallback-Samples.png` renders these strings in 28 px Noto Sans SC Medium and pairs each with the Latin candidate in the same row: `星湖街`, `正在重新规划`, `已到达`, `手机已断开`. The Noto glyphs have a consistent line box and are not downscaled. A Latin/CJK baseline tweak is still best confirmed after LVGL font conversion; the sample image uses a shared host baseline.

## Open font licenses

All four source families use the SIL Open Font License 1.1. OFL permits modification and bundling with software, with the license/copyright retained and reserved-name restrictions observed. The font files themselves are not copied into product resources by this comparison. Candidate preview source URLs and official license texts:

- Inter: [font source](https://github.com/google/fonts/blob/main/ofl/inter/Inter%5Bopsz%2Cwght%5D.ttf), [OFL](https://github.com/google/fonts/blob/main/ofl/inter/OFL.txt)
- Roboto Condensed: [font source](https://github.com/google/fonts/blob/main/ofl/robotocondensed/RobotoCondensed%5Bwght%5D.ttf), [OFL](https://github.com/google/fonts/blob/main/ofl/robotocondensed/OFL.txt)
- IBM Plex Sans: [font source](https://github.com/google/fonts/blob/main/ofl/ibmplexsans/IBMPlexSans%5Bwdth%2Cwght%5D.ttf), [OFL](https://github.com/google/fonts/blob/main/ofl/ibmplexsans/OFL.txt)
- Noto Sans SC: [font source](https://github.com/google/fonts/blob/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf), [OFL](https://github.com/google/fonts/blob/main/ofl/notosanssc/OFL.txt)

The checked Inter and Roboto Condensed notices list no reserved font name. IBM Plex reserves `Plex`; Noto Sans SC's notice reserves `Source`. If either modified font software is ever shipped, keep the OFL notices and use a non-reserved primary name for the generated font resource. The current preview assets are rendered images, not redistributed font software.

## Flash and RAM estimate

LVGL C resources were generated in `/tmp` for sizes 16/20/28/32/36/48/56/96, plus Noto Sans SC 16/28, at 4 bpp, no compression, with the documented UI glyph subsets. They were compiled as host objects to compare constant font data; these are estimates and no candidate object was linked to the firmware.

| Candidate resource set | Host `.const` bytes | Difference against current font set |
|---|---:|---:|
| Current six custom Stage C resources + current Montserrat built-ins 16/20/28/48 | 255,139 | baseline |
| A — Inter + Noto Sans SC | 157,130 | −98,009 |
| B — Roboto Condensed + Noto Sans SC | 129,051 | −126,088 |
| C — IBM Plex Sans + Noto Sans SC | 142,351 | −112,788 |

Candidate resources are smaller in this estimate because the current LVGL Montserrat 16/20/28/48 built-ins contain broad glyph sets. Replacing those with subsets offsets the added custom sizes. LVGL font bitmaps remain read-only constant data; no full font is loaded into RAM. These figures exclude LVGL object/text buffers and the separate LVGL icon font required for the music symbol. Static font descriptors add only a small amount of data/BSS; the measured generated font objects had no `.bss`. ESP32 linker totals could differ slightly from host object totals. Since candidates are preview-only, the existing firmware's measured build remains unchanged: image `0x14ca10` bytes, 84% of the 8 MiB app partition free.

## Visual reading

- **A — Inter:** best overall balance for a product UI; broad, open numerals and familiar text proportions. It reads as a contemporary companion display and keeps mixed English/Chinese calm. Wider word shapes can use more line width than B.
- **B — Roboto Condensed:** clearest space saver for 108 and long English labels; the compact forms make distance and status groups feel more instrument-like. It approaches the vehicle-display look the brief warns against, and some small lowercase text is denser.
- **C — IBM Plex Sans:** restrained, slightly technical voice with clear digits; it gives the UI a more engineered character than A without B's strong condensation. Small lowercase and mixed Chinese/Latin feel a little more utilitarian.

Small-size legibility should be judged from the 466 px files opened at actual screen size; contact sheets are reduced. The preview uses target-size faces directly, never a scaled-up small bitmap.

The export completed with zero circle-safe-width failures. The 1.2 km study uses a clean shared navigation background, and the Chinese mixed-title study clears the previous text before drawing, so no old glyph fragments remain under candidate text.
