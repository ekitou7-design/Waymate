# Waymate Round Display Typography — Stage C.2

Date: 2026-10-06  
Decision: **A — Inter + Noto Sans SC**

## Final Typography

- Inter Medium: tertiary 16 px, secondary 20 px.
- Inter SemiBold: primary 28 px, connection/status 32 px, compass cardinal 36 px, maneuver distance/compass degrees 56 px, speed 96 px.
- Noto Sans SC Medium: Chinese 16 px fallback and 28 px road/title fallback. Its line-height and baseline metrics are normalized to the matching Inter tier.
- The speed digits use target-size 96 px bitmaps; the maneuver distance uses 56 px. No smaller glyph bitmap is scaled up. Digit kerning is disabled only for the numeric readouts where fixed advance is needed; kerning remains enabled in other Inter runs.

## Font Resources

- `scripts/generate_fonts.sh` pins `lv_font_conv@1.5.3` and produces static LVGL C resources at their display sizes, 4 bpp, without compression. Generation was run twice and produced identical resource hashes.
- Latin subsets cover A–Z, a–z, 0–9 and the punctuation/units used by the round-display UI, including `: . - / % ° →`, `km`, `m`, and `km/h`.
- Each Noto Sans SC size currently contains 107 reviewed glyphs. This includes the tested road name `星湖街`, mixed `星湖街 West`, and current fixed Chinese UI samples. The existing Source Han Sans 16 px resource remains linked as a compatibility fallback for smaller fixed text.
- Only generated C bitmap objects are linked. TTFs are retained as generator sources, not placed in the firmware or app partition. Full Inter and Noto SIL OFL 1.1 notices and copyright holders are in `shared/nav_ui/assets/fonts/licenses/`. Generated symbols use Waymate names; the Noto reserved name `Source` is not used for the derivative resources.
- The CJK bitmap is a curated subset, not a full dynamic Chinese font. Arbitrary road names or media strings can contain missing glyphs; those are not represented as full CJK coverage.

## Page Changes

- **Speed:** 96 px SemiBold digits; 48, 108, and `--` previews. Unit remains 16 px and secondary. Two/three-digit values use fixed advances and the numeric center anchor; no digit enlargement or map/arc changes.
- **Navigation:** 56 px distance values, 28 px road/instruction text, and the existing map context hierarchy. 320 m and 1.2 km previews are included. The bottom road label is a 230 design-pixel label, top-middle aligned with centered text and dot truncation. Its CJK run resolves to the 28 px Noto resource, not the smaller 16 px fallback.
- **Compass:** 36 px cardinal and 56 px degree readout; N, NE, SW, and W cases are rendered. Ring/tick drawing is unchanged.
- **Media:** 28 px title and 20 px artist; English and Chinese/mixed samples are rendered. Existing controls and their interaction are unchanged.
- **Ready/connection:** Inter SemiBold 32 px for the primary status; secondary engineering copy remains lower in hierarchy. Boot keeps the Waymate W mark.

## Optical Centering

- The road label's text center is checked against the display center to within one pixel of integer raster rounding; its rendered run is checked against the round-screen chord with a 12 px inset. Its label position and page structure are unchanged.
- Inter/Noto 28 px line-height and baseline are matched. Native tests verify identical metrics for the road title fallback and mixed English/Chinese resolution. The Chinese glyphs are rasterized at 28 px; there is no bitmap scaling step.
- The renderer keeps a small named set of existing optical offsets: boot mark +5 px, speed unknown −5 px, and the compass stack −34 px. Speed 48/108 use a zero optical Y offset. No scattered alignment edits were added for the road name.
- The C2 renderer preview is 466 × 466 with the nominal circle mask. Hardware panel optics are not verified in this host render.

## Chinese Road-Name Check

The prior Navigation road label used a small CJK resource in the fallback chain, which could make Chinese appear undersized beside Latin. The C2 road chain is Inter 28 → Noto Sans SC 28, with matching baseline metrics. `星湖街` and `星湖街 West` are covered at 28 px, centered, and fully inside the circle's safe chord. The preview shows crisp glyph edges at native bitmap size. Other Chinese characters remain subject to the documented 107-glyph subset.

## Firmware Impact

| Measurement | Before | After | Delta / scope |
|---|---:|---:|---|
| ESP32 app binary | 1,362,448 B immediate pre-font build artifact | 1,409,520 B | +47,072 B across this already-dirty working-tree build; this is not an isolated typography-only delta |
| Formal Stage C binary reference | 1,292,896 B | 1,409,520 B | +116,624 B across all changes since that reference; not a font-only comparison |
| App-specific font `.rodata` linked from `libmain.a` | 13,154 B Source Han 16 asset in the pre-change font set | 129,546 B | +116,392 B; after includes Source Han 16 plus the Inter/Noto resources, and excludes LVGL's built-in fonts |
| 8 MiB app partition remaining | — | 6,979,088 B (about 83.2% free) | After full ESP-IDF build |
| Board-parity LVGL pool | — | 54,504 B used / 62,832 B measured peak in 64 KiB internal + 2 MiB external host pool | Two board-memory render configurations passed; this is a host simulation, not live device heap telemetry |

Static generated glyph data is in flash rodata; the font wrappers are static and configured during UI creation. No per-frame font allocation was introduced. The current board-parity render suite passes at 64 KiB internal and 2 MiB external pools. No physical-device PSRAM or redraw-performance measurement was made in this run.

## Visual Review

- [Stage C.2 Inter contact sheet](stage-c2-inter/Stage-C2-Inter-Contact-Sheet.png)
- [Stage C vs C.2 comparison](stage-c2-inter/Stage-C-vs-C2-Inter.png)
- [Chinese road `星湖街`](stage-c2-inter/navigation-chinese-road.png)
- [Mixed Chinese/Latin road `星湖街 West`](stage-c2-inter/navigation-chinese-road-mixed.png)
- [1.2 km distance](stage-c2-inter/navigation-1_2-km.png)
- [Speed 48 / 108 / unavailable](stage-c2-inter/speed-48-kmh.png), [108](stage-c2-inter/speed-108-kmh.png), [--](stage-c2-inter/speed-unknown.png)

Thirty Stage C.2 frames were rendered from the shared LVGL renderer and test fixtures. Preview fixtures are not live-device validation.

## Validation

- Native C++ tests: **9/9 passed**.
- Board-memory rendering: **320-row and 40-row cases passed** with 64 KiB internal LVGL and 2 MiB external pools.
- LVGL render checks: passed; the latest 40-row run measured 54,504 B used and 62,832 B peak.
- Full ESP-IDF build: **passed**; generated `moto_gps_esp32.bin` is 1,409,520 B. No flash operation was performed.
- Swift package regression: **19/19 passed**.
- iOS AppTests on iPhone 16 Pro / iOS 18.6 simulator: XCTest completed; gateway/UI unit tests passed, while **7 of 16 UI tests failed** in live map/place/route search paths because expected search results did not appear (`place-result-0` / city search). The other 9 UI tests passed. This does not validate or implicate round-display font rendering. Result bundle: `/private/tmp/Waymate-StageC2-AppTests.xcresult`.
- Font generator: pinned source and repeated output hash check passed.
- `git diff --check`: passed at report preparation.

## Architecture Check

The typography implementation is in `shared/nav_ui`, generated font assets, the ESP32 source list, and renderer tests/previews. It does not change BLE protocol, NavCore, route geometry, coordinate systems, PresentationCoordinator, RideSession, Ride Tracking, iPhone page selection, media protocol, or interaction semantics. Map drawing and page structure are unchanged by the typography edits. Other iOS, presenter, design, and documentation changes were already present in the shared dirty working tree and were not edited as part of the typography work. No commit or push was made.

## Git Status

Complete `git status --short --branch` output at handoff:

```text
## main...origin/main
 M platforms/esp32/main/CMakeLists.txt
 M platforms/ios/App/AppModel.swift
 M platforms/ios/App/ContentView.swift
 M platforms/ios/App/MapDownloadsView.swift
 M platforms/ios/App/RouteOverviewMap.swift
 M platforms/ios/UITests/WaymateUITests.swift
 M scripts/generate_fonts.sh
 M shared/nav_presenter/src/moto_nav_presenter.cpp
 M shared/nav_ui/CMakeLists.txt
 M shared/nav_ui/include/moto_nav_ui.h
 M shared/nav_ui/src/moto_nav_ui.cpp
 M tests/native/nav_presenter_tests.cpp
 M tests/native/nav_ui_render_tests.cpp
?? design/
?? docs/ui/
?? platforms/ios/App/ActiveNavigationView.swift
?? platforms/ios/App/DeviceStatusView.swift
?? platforms/ios/App/MediaView.swift
?? platforms/ios/App/RideMetricsView.swift
?? platforms/ios/App/WaymatePrimaryButton.swift
?? platforms/ios/AppTests/NavigationReadoutTests.swift
?? scripts/ios/generate_waymate_brand.swift
?? scripts/render_round_display_previews.py
?? scripts/render_typography_candidates.py
?? shared/nav_ui/assets/fonts/
?? shared/nav_ui/assets/moto_font_cjk_16.c
?? shared/nav_ui/assets/moto_font_cjk_28.c
?? shared/nav_ui/assets/moto_font_inter_medium_16.c
?? shared/nav_ui/assets/moto_font_inter_medium_20.c
?? shared/nav_ui/assets/moto_font_inter_semibold_28.c
?? shared/nav_ui/assets/moto_font_inter_semibold_32.c
?? shared/nav_ui/assets/moto_font_inter_semibold_36.c
?? shared/nav_ui/assets/moto_font_inter_semibold_56.c
?? shared/nav_ui/assets/moto_font_inter_semibold_96.c
```
