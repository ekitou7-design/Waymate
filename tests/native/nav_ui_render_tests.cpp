// Deterministic host-side rendering tests for the LVGL navigation UI.
// A headless LVGL display renders the real moto_nav_ui into an RGB565
// framebuffer; frames are hashed to verify bit-exact determinism, clean page
// transitions and label/geometry residue cleanup.

#include "moto_nav_ui.h"

#include <lvgl.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <fstream>
#include <cmath>
#include <string>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::cerr << __FILE__ << ':' << __LINE__                             \
                << " CHECK failed: " #condition << '\n';                   \
      ++failures;                                                          \
    }                                                                      \
  } while (false)

constexpr int kWidth = MOTO_UI_CANVAS_WIDTH;
constexpr int kHeight = MOTO_UI_CANVAS_HEIGHT;
constexpr std::size_t kFrameBytes = static_cast<std::size_t>(kWidth) *
                                    static_cast<std::size_t>(kHeight) *
                                (LV_COLOR_DEPTH / 8);

std::vector<std::uint8_t> shadow_frame;
std::uint64_t flush_count = 0;

void flush_cb(lv_display_t* display, const lv_area_t* area,
              std::uint8_t* px_map) {
  // Partial rendering: stitch each flushed area into the shadow frame so a
  // complete deterministic frame is always available for hashing.
  const int bytes_per_pixel = LV_COLOR_DEPTH / 8;
  for (int y = area->y1; y <= area->y2; ++y) {
    const std::size_t row_bytes =
        static_cast<std::size_t>(area->x2 - area->x1 + 1) * bytes_per_pixel;
    const std::size_t src =
        static_cast<std::size_t>(y - area->y1) *
        static_cast<std::size_t>(area->x2 - area->x1 + 1) * bytes_per_pixel;
    const std::size_t dst =
        (static_cast<std::size_t>(y) * kWidth +
         static_cast<std::size_t>(area->x1)) * bytes_per_pixel;
    std::memcpy(shadow_frame.data() + dst, px_map + src, row_bytes);
  }
  ++flush_count;
  lv_display_flush_ready(display);
}

void init_display(int buffer_rows, int extra_pool_bytes) {
  lv_init();
  static std::vector<std::uint32_t> extra_pool;
  if(extra_pool_bytes > 0) {
    extra_pool.resize((static_cast<std::size_t>(extra_pool_bytes) + 3U) / 4U);
    const bool added = lv_mem_add_pool(extra_pool.data(), extra_pool.size() * 4U) != nullptr;
    CHECK(added);
    if(!added) std::exit(EXIT_FAILURE);
  }
  shadow_frame.assign(kFrameBytes, 0);
  // Exercise both small partial strips and the firmware's map-sized buffer.
  static std::vector<std::uint8_t> draw_buffer(
      static_cast<std::size_t>(kWidth) * buffer_rows * (LV_COLOR_DEPTH / 8));
  lv_display_t* display = lv_display_create(kWidth, kHeight);
  lv_display_set_flush_cb(display, flush_cb);
  lv_display_set_buffers(
      display, draw_buffer.data(), nullptr, draw_buffer.size(),
      LV_DISPLAY_RENDER_MODE_PARTIAL);
}

void pump(int cycles = 40) {
  for (int i = 0; i < cycles; ++i) {
    lv_tick_inc(5);
    lv_timer_handler();
  }
}

std::uint64_t frame_hash() {
  std::uint64_t hash = 1'469'598'103'934'665'603ULL;
  for (const std::uint8_t byte : shadow_frame) {
    hash ^= byte;
    hash *= 1'099'511'628'211ULL;
  }
  return hash;
}

struct Frame {
  std::uint64_t hash;
  std::vector<std::uint8_t> bytes;
};

Frame capture() {
  pump();
  return Frame{frame_hash(), shadow_frame};
}

moto_ui_state_t base_state() {
  moto_ui_state_t state{};
  state.page = MOTO_UI_PAGE_NAVIGATION;
  state.mode = MOTO_UI_NAVIGATING;
  state.maneuver = MOTO_MANEUVER_RIGHT;
  state.traffic = MOTO_TRAFFIC_SLOW;
  state.distance_to_maneuver_m = 120;
  state.remaining_distance_m = 1'500;
  state.remaining_time_s = 200;
  state.route_progress_percent = 40;
  state.gps_accuracy_m = 5;
  state.speed_available = 1;
  state.heading_available = 1;
  state.has_next_maneuver = 1;
  state.online = 1;
  state.has_destination = 1;
  state.route_identity = 77;
  state.route_generation = 1;
  state.map_scene_revision = 4;
  state.speed_kph = 48;
  state.speed_limit_kph = 50;
  state.heading_deg = 90;
  state.road_name = "经十路";
  state.next_road_name = "青年大街";
  return state;
}

void fill_route(moto_ui_state_t& state, int count) {
  count = count < 0 ? MOTO_UI_ROUTE_POINT_CAPACITY : count;
  state.route_point_count = static_cast<std::uint8_t>(count);
  for (int i = 0; i < count; ++i) {
    state.route_points[i] = {static_cast<std::int16_t>(40 + i * 16),
                             static_cast<std::int16_t>(233 + (i % 2) * 40)};
  }
}

void fill_streets(moto_ui_state_t& state) {
  state.road_point_count = 8;
  for (int i = 0; i < 8; ++i) {
    state.road_points[i] = {static_cast<std::int16_t>(10 + i * 55),
                            static_cast<std::int16_t>(30 + i * 60)};
  }
  state.road_polyline_count = 1;
  state.road_polylines[0] = {0, 8, 1};
  state.building_point_count = 6;
  for (int i = 0; i < 6; ++i) {
    state.building_points[i] = {
        static_cast<std::int16_t>(300 + (i % 3) * 40),
        static_cast<std::int16_t>(300 + (i / 3) * 40)};
  }
  state.building_footprint_count = 1;
  state.building_footprints[0] = {0, 6, 1};
}

void check_circle_text_bounds(lv_obj_t *object);

// Export the real LVGL framebuffer only when explicitly requested by a test
// runner. These fixtures never enter firmware, NavCore, or BLE production state.
void export_preview(const char *name) {
  const char *directory = std::getenv("MOTO_UI_PREVIEW_DIR");
  const auto frame = capture();
  check_circle_text_bounds(lv_screen_active());
  if(!directory) return;
  std::ofstream output(std::string(directory) + "/" + name + ".ppm", std::ios::binary);
  CHECK(output.good());
  output << "P6\n" << kWidth << ' ' << kHeight << "\n255\n";
  for(std::size_t i = 0; i < frame.bytes.size(); i += 2) {
    const unsigned pixel = frame.bytes[i] | (frame.bytes[i+1] << 8);
    const char rgb[] = {static_cast<char>(((pixel >> 11) & 31) * 255 / 31),
                        static_cast<char>(((pixel >> 5) & 63) * 255 / 63),
                        static_cast<char>((pixel & 31) * 255 / 31)};
    output.write(rgb, 3);
  }
}

void check_circle_text_bounds(lv_obj_t *object) {
  if(lv_obj_has_flag(object, LV_OBJ_FLAG_HIDDEN)) return;
  if(lv_obj_check_type(object, &lv_label_class) &&
     lv_label_get_text(object)[0] != '\0') {
    lv_area_t area;
    lv_obj_get_coords(object, &area);
    const auto *font = lv_obj_get_style_text_font(object, LV_PART_MAIN);
    const int letter_space = lv_obj_get_style_text_letter_space(object, LV_PART_MAIN);
    const int line_space = lv_obj_get_style_text_line_space(object, LV_PART_MAIN);
    lv_point_t text_size{};
    lv_text_get_size(&text_size, lv_label_get_text(object), font,
                     letter_space, line_space, LV_COORD_MAX,
                     LV_TEXT_FLAG_NONE);
    const int object_width = area.x2 - area.x1 + 1;
    const int visible_width = std::min<int>(text_size.x, object_width);
    int text_x1 = area.x1;
    if(lv_obj_get_style_text_align(object, LV_PART_MAIN) == LV_TEXT_ALIGN_CENTER)
      text_x1 += (object_width - visible_width) / 2;
    const int text_x2 = text_x1 + visible_width - 1;
    const int text_y2 = std::min<int>(area.y2, area.y1 + text_size.y - 1);
    const int radius = kWidth / 2 - 12;
    const int farthest_y = std::max(std::abs(area.y1 - kHeight / 2),
                                    std::abs(text_y2 - kHeight / 2));
    const double half_chord = farthest_y >= radius
        ? 0.0 : std::sqrt(radius * radius - farthest_y * farthest_y);
    if(!(text_x1 >= kWidth / 2 - half_chord &&
         text_x2 <= kWidth / 2 + half_chord)) {
      std::cerr << "circle-safe label '" << lv_label_get_text(object)
                << "' at " << text_x1 << ',' << area.y1 << "-"
                << text_x2 << ',' << text_y2 << '\n';
      CHECK(false);
    }
  }
  for(unsigned i = 0; i < lv_obj_get_child_count(object); ++i)
    check_circle_text_bounds(lv_obj_get_child(object, i));
}

bool has_visible_label(lv_obj_t *object, const char *text) {
  if(lv_obj_has_flag(object, LV_OBJ_FLAG_HIDDEN)) return false;
  if(lv_obj_check_type(object, &lv_label_class) &&
     std::strcmp(lv_label_get_text(object), text) == 0) return true;
  for(unsigned i = 0; i < lv_obj_get_child_count(object); ++i)
    if(has_visible_label(lv_obj_get_child(object, i), text)) return true;
  return false;
}

lv_obj_t *find_visible_label(lv_obj_t *object, const char *text) {
  if(lv_obj_has_flag(object, LV_OBJ_FLAG_HIDDEN)) return nullptr;
  if(lv_obj_check_type(object, &lv_label_class) &&
     std::strcmp(lv_label_get_text(object), text) == 0) return object;
  for(unsigned i = 0; i < lv_obj_get_child_count(object); ++i) {
    if(auto *found = find_visible_label(lv_obj_get_child(object, i), text))
      return found;
  }
  return nullptr;
}

void check_font_glyphs(const lv_font_t *font, const std::uint32_t *glyphs,
                       std::size_t count) {
  for(std::size_t i = 0; i < count; ++i) {
    lv_font_glyph_dsc_t glyph{};
    if(!lv_font_get_glyph_dsc(font, &glyph, glyphs[i], 0)) {
      std::cerr << "missing glyph U+" << std::hex << glyphs[i] << std::dec
                << '\n';
      CHECK(false);
    }
  }
}

void check_visible_utf8(lv_obj_t *object) {
  if(lv_obj_has_flag(object, LV_OBJ_FLAG_HIDDEN)) return;
  if(lv_obj_check_type(object, &lv_label_class)) {
    const auto *p = reinterpret_cast<const unsigned char *>(lv_label_get_text(object));
    const auto *font = lv_obj_get_style_text_font(object, LV_PART_MAIN);
    while(*p) {
      const unsigned count = *p < 0x80 ? 1 : *p >= 0xF0 ? 4 : *p >= 0xE0 ? 3 : *p >= 0xC0 ? 2 : 0;
      CHECK(count > 0);
      if(!count) break;
      std::uint32_t scalar = count == 1 ? p[0] : p[0] & (0x7FU >> count);
      for(unsigned i = 1; i < count; ++i) {
        CHECK(p[i] != 0 && (p[i] & 0xC0) == 0x80);
        if(!p[i]) return;
        scalar = (scalar << 6) | (p[i] & 0x3FU);
      }
      if(scalar > 0x7F) {
        lv_font_glyph_dsc_t glyph{};
        if(!lv_font_get_glyph_dsc(font, &glyph, scalar, 0)) {
          std::cerr << "label '" << lv_label_get_text(object)
                    << "' missing U+" << std::hex << scalar << std::dec
                    << " in its runtime font chain\n";
          CHECK(false);
        }
      }
      p += count;
    }
  }
  for(unsigned i = 0; i < lv_obj_get_child_count(object); ++i)
    check_visible_utf8(lv_obj_get_child(object, i));
}

void check_tabular_number(lv_obj_t *object, const char *text) {
  if(lv_obj_has_flag(object, LV_OBJ_FLAG_HIDDEN)) return;
  if(lv_obj_check_type(object, &lv_label_class) && std::strcmp(lv_label_get_text(object), text) == 0) {
    const auto *font = lv_obj_get_style_text_font(object, LV_PART_MAIN);
    std::uint16_t digit_advance = 0;
    for(unsigned digit = '0'; digit <= '9'; ++digit) {
      lv_font_glyph_dsc_t glyph;
      CHECK(lv_font_get_glyph_dsc(font, &glyph, digit, 0));
      if(digit == '0') digit_advance = glyph.adv_w;
      else CHECK(glyph.adv_w == digit_advance);
    }
  }
  for(unsigned i = 0; i < lv_obj_get_child_count(object); ++i)
    check_tabular_number(lv_obj_get_child(object, i), text);
}

void test_stage_c_product_states() {
  moto_nav_ui_show_boot_screen();
  pump(65);
  export_preview("boot");
  moto_nav_ui_create();
  moto_nav_ui_set_reduce_motion(1);
  auto state = base_state();
  state.has_destination = 0;
  state.mode = MOTO_UI_ACQUIRING_FIX;
  state.page = MOTO_UI_PAGE_NAVIGATION;
  moto_nav_ui_set_state(&state);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  check_visible_utf8(lv_screen_active());
  export_preview("disconnected");
  CHECK(has_visible_label(lv_screen_active(), "PHONE LOST"));
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_CONNECTING);
  check_visible_utf8(lv_screen_active());
  export_preview("connecting-protocol-not-ready");
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  check_visible_utf8(lv_screen_active());
  export_preview("connected");
  pump(210); // Let the existing transient Connected hold expire.
  CHECK(has_visible_label(lv_screen_active(), "READY"));
  check_visible_utf8(lv_screen_active());
  export_preview("idle-ready");

  state = base_state();
  state.route_request_in_flight = 1;
  moto_nav_ui_set_state(&state);
  check_visible_utf8(lv_screen_active());

  state = base_state();
  state.distance_to_maneuver_m = 320;
  state.speed_limit_kph = 0;
  // Rider stays at the production presenter's fixed pixel (233,254).
  state.route_point_count = 5;
  state.route_points[0] = {233,350}; state.route_points[1] = {233,254};
  state.route_points[2] = {233,205}; state.route_points[3] = {310,205};
  state.route_points[4] = {410,130};
  state.road_point_count = 8;
  state.road_polyline_count = 4;
  state.road_points[0] = {40,205}; state.road_points[1] = {430,205};
  state.road_points[2] = {140,140}; state.road_points[3] = {140,375};
  state.road_points[4] = {325,145}; state.road_points[5] = {325,365};
  state.road_points[6] = {40,310}; state.road_points[7] = {430,310};
  for(int i=0;i<4;++i) state.road_polylines[i] = {static_cast<uint8_t>(i*2),2,3};
  state.next_road_name = "建国路";
  moto_nav_ui_set_state(&state);
  check_visible_utf8(lv_screen_active());
  export_preview("navigation-normal");
  state.online = 0;
  moto_nav_ui_set_state(&state);
  auto *status_label = find_visible_label(lv_screen_active(), "NETWORK OFFLINE");
  CHECK(status_label != nullptr);
  if(status_label) {
    const auto *font = lv_obj_get_style_text_font(status_label, LV_PART_MAIN);
    lv_font_glyph_dsc_t front{};
    CHECK(lv_font_get_glyph_dsc(font, &front, 0x524D, 0));
    CHECK(front.resolved_font != nullptr);
    CHECK(front.resolved_font != font);
  }
  state.online = 1;
  moto_nav_ui_set_state(&state);
  state.distance_to_maneuver_m = 1200;
  moto_nav_ui_set_state(&state); export_preview("navigation-1_2-km");
  state.distance_to_maneuver_m = 320;
  state.next_road_name = "星湖街";
  moto_nav_ui_set_state(&state); export_preview("navigation-chinese-road");
  auto *road_label = find_visible_label(lv_screen_active(), "星湖街");
  CHECK(road_label != nullptr);
  if(road_label) {
    const std::uint32_t road_glyphs[] = {0x661F, 0x6E56, 0x8857};
    check_font_glyphs(lv_obj_get_style_text_font(road_label, LV_PART_MAIN),
                      road_glyphs, 3);
  }
  state.next_road_name = "星湖街 West";
  moto_nav_ui_set_state(&state); export_preview("navigation-chinese-road-mixed");
  road_label = find_visible_label(lv_screen_active(), "星湖街 West");
  CHECK(road_label != nullptr);
  if(road_label) {
    const auto *font = lv_obj_get_style_text_font(road_label, LV_PART_MAIN);
    lv_area_t bounds;
    lv_obj_get_coords(road_label, &bounds);
    CHECK(lv_obj_get_style_text_align(road_label, LV_PART_MAIN) ==
          LV_TEXT_ALIGN_CENTER);
    CHECK(std::abs(bounds.x1 + bounds.x2 - 2 * (kWidth / 2)) <= 2);
    CHECK(font->line_height == 29);
    lv_font_glyph_dsc_t cjk{};
    CHECK(lv_font_get_glyph_dsc(font, &cjk, 0x661F, 0x6E56));
    CHECK(cjk.resolved_font != nullptr);
    lv_font_glyph_dsc_t latin{};
    CHECK(lv_font_get_glyph_dsc(font, &latin, 'W', 'e'));
    CHECK(latin.resolved_font == font);
  }
  state.next_road_name = "向前行驶";
  moto_nav_ui_set_state(&state);
  auto *instruction_label = find_visible_label(lv_screen_active(), "向前行驶");
  CHECK(instruction_label != nullptr);
  if(instruction_label) {
    const auto *font = lv_obj_get_style_text_font(instruction_label, LV_PART_MAIN);
    const std::uint32_t instruction_glyphs[] = {0x5411, 0x524D, 0x884C, 0x9A76};
    check_font_glyphs(font, instruction_glyphs, 4);
    lv_font_glyph_dsc_t front{};
    CHECK(lv_font_get_glyph_dsc(font, &front, 0x524D, 0));
    CHECK(front.resolved_font != nullptr);
    CHECK(front.resolved_font != font);
  }
  check_visible_utf8(lv_screen_active());
  state.next_road_name = "建国路";
  moto_nav_ui_set_state(&state);
  check_tabular_number(lv_screen_active(), "320");
  CHECK(has_visible_label(lv_screen_active(), "建国路"));
  state.distance_to_maneuver_m = 25;
  moto_nav_ui_set_state(&state); export_preview("maneuver-near");
  state.distance_to_maneuver_m = 12300;
  state.next_road_name = "建国路朝阳门外大街建国路朝阳门外大街";
  moto_nav_ui_set_state(&state); export_preview("navigation-long-text-km");
  state.mode = MOTO_UI_REROUTING;
  moto_nav_ui_set_state(&state); export_preview("rerouting");
  CHECK(has_visible_label(lv_screen_active(), "REROUTING"));
  CHECK(!has_visible_label(lv_screen_active(), "25"));
  state.mode = MOTO_UI_NAVIGATING; state.off_route = 1;
  moto_nav_ui_set_state(&state); export_preview("off-route");
  CHECK(has_visible_label(lv_screen_active(), "OFF ROUTE"));
  state.off_route = 0; state.gnss_stale = 1;
  moto_nav_ui_set_state(&state); export_preview("location-stale");
  CHECK(has_visible_label(lv_screen_active(), "LOCATION STALE"));
  state.gnss_stale = 0; state.mode = MOTO_UI_ARRIVED;
  moto_nav_ui_set_state(&state); export_preview("arrived");
  CHECK(has_visible_label(lv_screen_active(), "ARRIVED"));
  CHECK(!has_visible_label(lv_screen_active(), "0"));
  CHECK(!has_visible_label(lv_screen_active(), "RIDE COMPLETE"));
  state.mode = MOTO_UI_NAVIGATING; state.page = MOTO_UI_PAGE_SPEED;
  state.speed_available = 1; state.speed_kph = 48;
  moto_nav_ui_set_state(&state); export_preview("speed");
  export_preview("speed-48-kmh");
  state.speed_kph = 108;
  moto_nav_ui_set_state(&state); export_preview("speed-three-digits");
  export_preview("speed-108-kmh");
  check_tabular_number(lv_screen_active(), "108");
  state.speed_available = 0;
  moto_nav_ui_set_state(&state); export_preview("speed-unknown");
  CHECK(has_visible_label(lv_screen_active(), "--"));
  state.speed_available = 1; state.speed_kph = 48;
  state.page = MOTO_UI_PAGE_COMPASS; state.heading_deg = 45;
  moto_nav_ui_set_state(&state); export_preview("compass");
  CHECK(has_visible_label(lv_screen_active(), "NE"));
  state.heading_available = 0;
  moto_nav_ui_set_state(&state); export_preview("compass-heading-unavailable");
  CHECK(!has_visible_label(lv_screen_active(), "NE"));
  CHECK(has_visible_label(lv_screen_active(), "--"));
  state.heading_available = 1;
  state.heading_deg = 0; moto_nav_ui_set_state(&state); export_preview("compass-n");
  state.heading_deg = 225; moto_nav_ui_set_state(&state); export_preview("compass-sw");
  state.heading_deg = 270; moto_nav_ui_set_state(&state); export_preview("compass-w");

  moto_nav_ui_set_music_page_enabled(1);
  moto_nav_ui_set_page(MOTO_UI_PAGE_MUSIC);
  moto_music_state_t music{};
  music.connected = 1; music.playing = 1;
  music.source_name = "APPLE MUSIC"; music.track_title = "NIGHTCALL";
  music.artist_name = "Kavinsky";
  moto_nav_ui_set_music_state(&music); export_preview("media-playing");
  auto *source_label = find_visible_label(lv_screen_active(), "APPLE MUSIC");
  CHECK(source_label != nullptr);
  if(source_label) {
    const auto *font = lv_obj_get_style_text_font(source_label, LV_PART_MAIN);
    for(std::uint32_t cp = 'A'; cp <= 'Z'; ++cp) check_font_glyphs(font, &cp, 1);
    for(std::uint32_t cp = 'a'; cp <= 'z'; ++cp) check_font_glyphs(font, &cp, 1);
    for(std::uint32_t cp = '0'; cp <= '9'; ++cp) check_font_glyphs(font, &cp, 1);
    const std::uint32_t symbols[] = {':', '.', '-', '/', '%', 0x00B0, 0x2192};
    check_font_glyphs(font, symbols, sizeof(symbols) / sizeof(symbols[0]));
  }
  music.playing = 0;
  moto_nav_ui_set_music_state(&music); export_preview("media-paused");
  pump(1200);
  CHECK(moto_nav_ui_get_page() == MOTO_UI_PAGE_MUSIC); // Active Media has no 5s expiry.
  music.connected = 0;
  moto_nav_ui_set_music_state(&music); export_preview("media-unavailable");
  CHECK(!has_visible_label(lv_screen_active(), "NIGHTCALL"));
  music.connected = 1;
  music.track_title = "A建国路建国路建国路建国路建国路建国路建国路建国路";
  moto_nav_ui_set_music_state(&music); export_preview("media-long-utf8");
  music.track_title = "星湖街 City Lights";
  music.artist_name = "星湖街 Kavinsky";
  moto_nav_ui_set_music_state(&music); export_preview("media-chinese-mixed");
  auto *mixed_title = find_visible_label(lv_screen_active(),
                                         "星湖街 City Lights");
  CHECK(mixed_title != nullptr);
  if(mixed_title) {
    const auto *font = lv_obj_get_style_text_font(mixed_title, LV_PART_MAIN);
    lv_font_glyph_dsc_t cjk{};
    CHECK(lv_font_get_glyph_dsc(font, &cjk, 0x661F, 0x6E56));
    CHECK(cjk.resolved_font != nullptr);
  }
  check_visible_utf8(lv_screen_active());
  auto *mixed_artist = find_visible_label(lv_screen_active(),
                                          "星湖街 Kavinsky");
  CHECK(mixed_artist != nullptr);
  if(mixed_artist) {
    const auto *font = lv_obj_get_style_text_font(mixed_artist, LV_PART_MAIN);
    lv_font_glyph_dsc_t cjk{};
    CHECK(lv_font_get_glyph_dsc(font, &cjk, 0x661F, 0x6E56));
    CHECK(cjk.resolved_font != nullptr);
  }
  check_visible_utf8(lv_screen_active());
  const unsigned objects = lv_obj_get_child_count(lv_screen_active());
  pump(400);
  CHECK(objects == lv_obj_get_child_count(lv_screen_active()));
  lv_mem_monitor_t memory;
  lv_mem_monitor(&memory);
  std::cout << "Stage C.2 LVGL used=" << memory.total_size - memory.free_size
            << " max=" << memory.max_used << " bytes\n";
}

void test_frames_are_deterministic() {
  // Identical UI state must produce a bit-identical frame every time.
  moto_nav_ui_create();
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);

  moto_ui_state_t state = base_state();
  fill_route(state, 12);
  fill_streets(state);
  moto_nav_ui_set_state(&state);
  const Frame first = capture();

  moto_nav_ui_set_state(&state);
  const Frame second = capture();
  CHECK(first.hash == second.hash);
  CHECK(first.bytes == second.bytes);

  // Perturb the UI with an unrelated page, then come back: the restored
  // navigation frame must be identical to the original (no residue).
  moto_nav_ui_set_page(MOTO_UI_PAGE_SPEED);
  const Frame speed_page = capture();
  moto_nav_ui_set_page(MOTO_UI_PAGE_NAVIGATION);
  const Frame restored = capture();
  CHECK(restored.hash == first.hash);

  // The speed page must actually render different pixels.
  CHECK(speed_page.hash != first.hash);

  // Determinism holds across repeated renders of the same page as well.
  moto_nav_ui_set_page(MOTO_UI_PAGE_SPEED);
  const Frame speed_again = capture();
  CHECK(speed_again.hash == speed_page.hash);
}

void test_clearing_geometry_leaves_no_residue() {
  moto_ui_state_t with_route = base_state();
  fill_route(with_route, 18);
  fill_streets(with_route);
  moto_nav_ui_set_state(&with_route);
  const Frame route_frame = capture();

  moto_ui_state_t without_route = with_route;
  without_route.route_point_count = 0;
  without_route.road_point_count = 0;
  without_route.road_polyline_count = 0;
  without_route.building_point_count = 0;
  without_route.building_footprint_count = 0;
  moto_nav_ui_set_state(&without_route);
  const Frame cleared_frame = capture();
  CHECK(route_frame.hash != cleared_frame.hash);

  // Re-drawing the geometry must restore the exact original frame: nothing
  // was left behind by the clear, and nothing accumulated by the redraw.
  moto_nav_ui_set_state(&with_route);
  const Frame redrawn = capture();
  CHECK(redrawn.hash == route_frame.hash);
}

void test_music_page_state_and_fallback() {
  moto_nav_ui_set_music_page_enabled(1);
  moto_nav_ui_set_page(MOTO_UI_PAGE_MUSIC);
  CHECK(moto_nav_ui_get_page() == MOTO_UI_PAGE_MUSIC);

  moto_music_state_t music{};
  music.connected = 1;
  music.playing = 1;
  music.like_available = 1;
  music.source_name = "NetEase";
  music.track_title = "公路之歌";
  music.artist_name = "新裤子";
  moto_nav_ui_set_music_state(&music);
  const Frame titled = capture();

  // Emptying the strings must visibly clear the labels (no stale text).
  moto_music_state_t empty_state{};
  empty_state.connected = 1;
  moto_nav_ui_set_music_state(&empty_state);
  const Frame emptied = capture();
  CHECK(titled.hash != emptied.hash);

  // Disabling the music page while it is on screen must fall back to the
  // navigation page; re-enabling must not restore it by itself.
  moto_nav_ui_set_music_page_enabled(0);
  pump();
  CHECK(moto_nav_ui_get_page() != MOTO_UI_PAGE_MUSIC);
}

void test_phone_lifecycle_renders_deterministically() {
  // The connection lifecycle is a full-screen overlay for the empty
  // navigation page; cycle it there and require visually distinct terminal
  // states plus deterministic repetition (no accumulated residue).
  moto_ui_state_t empty = base_state();
  empty.mode = MOTO_UI_ACQUIRING_FIX;
  empty.has_destination = 0;
  empty.route_point_count = 0;
  empty.road_name = nullptr;
  empty.next_road_name = nullptr;
  moto_nav_ui_set_state(&empty);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  const Frame offline = capture();
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  const Frame online = capture();
  CHECK(offline.hash != online.hash);

  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  const Frame offline_again = capture();
  CHECK(offline_again.hash == offline.hash);

  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_CONNECTING);
  const Frame connecting = capture();
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE); CHECK(capture().hash == offline.hash);
}

void test_demo_mode_visual_contract() {
  // Demo mode suppresses the full-screen connection lifecycle and labels the
  // status line "DEMO RIDE"; toggling it must be perfectly reversible.
  moto_ui_state_t empty = base_state();
  empty.mode = MOTO_UI_ACQUIRING_FIX;
  empty.has_destination = 0;
  empty.route_point_count = 0;
  empty.road_name = nullptr;
  empty.next_road_name = nullptr;
  moto_nav_ui_set_state(&empty);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  moto_nav_ui_set_demo_active(0);
  const Frame without_demo = capture();

  moto_nav_ui_set_demo_active(1);
  const Frame with_demo = capture();
  CHECK(with_demo.hash != without_demo.hash);

  moto_nav_ui_set_demo_active(0);
  CHECK(capture().hash == without_demo.hash);

  // Contract: demo mode is connection-independent. The lifecycle surface is
  // hidden while demo is active, so connecting the phone must not change a
  // single pixel of the demo frame.
  moto_nav_ui_set_demo_active(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  CHECK(capture().hash == with_demo.hash);
  moto_nav_ui_set_demo_active(0);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
}

void test_capacity_payloads_render_stably() {
  // Maximum-capacity geometry must render identically across repeats.
  moto_ui_state_t max_state = base_state();
  fill_route(max_state, -1);
  fill_streets(max_state);
  max_state.road_point_count = MOTO_UI_ROAD_POINT_CAPACITY;
  for (int i = 0; i < MOTO_UI_ROAD_POINT_CAPACITY; ++i) {
    max_state.road_points[i] = {
        static_cast<std::int16_t>((i * 7) % kWidth),
        static_cast<std::int16_t>((i * 13) % kHeight)};
  }
  max_state.road_polyline_count = 4;
  for (int i = 0; i < 4; ++i) {
    max_state.road_polylines[i] = {
        static_cast<std::uint8_t>(i * 48),
        48,
        static_cast<std::uint8_t>(i % 6)};
  }
  moto_nav_ui_set_state(&max_state);
  const Frame max_first = capture();
  moto_nav_ui_set_state(&max_state);
  const Frame max_second = capture();
  CHECK(max_first.hash == max_second.hash);
}

void test_motion_frames_interpolate_then_settle_without_residue() {
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  moto_ui_state_t state = base_state();
  state.route_point_count = 3;
  state.route_points[0] = {233, 254};
  state.route_points[1] = {233, 150};
  state.route_points[2] = {233, 30};
  state.road_point_count = 2;
  state.road_points[0] = {110, 280};
  state.road_points[1] = {110, 30};
  state.road_polyline_count = 1;
  state.road_polylines[0] = {0, 2, 1};
  state.building_point_count = 4;
  state.building_points[0] = {300, 80};
  state.building_points[1] = {350, 80};
  state.building_points[2] = {350, 130};
  state.building_points[3] = {300, 130};
  state.building_footprint_count = 1;
  state.building_footprints[0] = {0, 4, 1};
  moto_nav_ui_set_state(&state);
  pump(260);  // finish the transient connected indication before comparing
  const auto before = capture().hash;

  // One heading frame moves all retained arrays through the ordinary motion
  // path, preserving the anchor and topology while the map turns under it.
  for (int index = 1; index < 3; ++index) state.route_points[index].x -= 130;
  for (int index = 0; index < 2; ++index) state.road_points[index].x += 110;
  for (int index = 0; index < 4; ++index) state.building_points[index].x -= 90;
  moto_nav_ui_set_reduce_motion(0);
  moto_nav_ui_set_motion_state(&state);
  pump(10);  // 50 ms contains two 25 ms interpolation opportunities.
  const auto intermediate = frame_hash();
  CHECK(intermediate != before);
  pump(200);
  const auto settled = frame_hash();
  const auto settled_bytes = shadow_frame;
  CHECK(settled != intermediate);

  // The eventual animated frame must match a direct render exactly, including
  // clearing the old road/building pixels in the shared invalidated region.
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_state(&state);
  const auto direct = capture();
  // Compare the map viewport. The page dots below it expire independently at
  // five seconds, which may fall between the two captured frames.
  constexpr int map_height = (232 * kWidth + 180) / 360;
  constexpr std::size_t map_bytes = kWidth * map_height * (LV_COLOR_DEPTH / 8);
  CHECK(std::equal(direct.bytes.begin(), direct.bytes.begin() + map_bytes,
                   settled_bytes.begin()));
}

void test_diagonal_map_pixels_are_independent_of_partial_buffer_height() {
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  auto state = base_state();
  fill_route(state, -1);
  fill_streets(state);
  state.road_point_count = MOTO_UI_ROAD_POINT_CAPACITY;
  state.road_polyline_count = MOTO_UI_ROAD_POLYLINE_CAPACITY;
  for (int i = 0; i < state.road_point_count; ++i) {
    // Long crossing diagonals, partially outside the viewport, exercise
    // band borders, both slope signs and the different road stroke widths.
    state.road_points[i] = {
        static_cast<std::int16_t>((i * 83) % 780 - 160),
        static_cast<std::int16_t>((i * 127) % 590 - 110)};
  }
  for (int i = 0; i < state.road_polyline_count; ++i) {
    state.road_polylines[i] = {
        static_cast<std::uint8_t>(i * 8), 8,
        static_cast<std::uint8_t>(i % 6)};
  }
  moto_nav_ui_set_state(&state);
  pump(260);
  auto* display = lv_display_get_default();
  static std::vector<std::uint8_t> short_buffer(kWidth * 40 * 2);
  static std::vector<std::uint8_t> tall_buffer(kWidth * 320 * 2);
  const auto draw_with_buffer = [display](std::vector<std::uint8_t>& buffer) {
    lv_display_set_buffers(display, buffer.data(), nullptr, buffer.size(),
                            LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(display);
    return shadow_frame;
  };
  const auto short_frame = draw_with_buffer(short_buffer);
  const auto tall_frame = draw_with_buffer(tall_buffer);
  CHECK(tall_frame == short_frame);
  CHECK(draw_with_buffer(short_buffer) == tall_frame);
}

}  // namespace

int main(int argc, char **argv) {
  const int buffer_rows = argc > 1 ? std::atoi(argv[1]) : 40;
  const int extra_pool_bytes = argc > 2 ? std::atoi(argv[2]) : 0;
  if(buffer_rows < 1 || buffer_rows > kHeight) return EXIT_FAILURE;
  if(extra_pool_bytes < 0) return EXIT_FAILURE;
  init_display(buffer_rows, extra_pool_bytes);

  // Production cadence: the boot animation completes before the full UI is
  // created, so settle it before moto_nav_ui_create().
  moto_nav_ui_show_boot_screen();
  pump(260);
  const Frame settled_boot = capture();
  const bool all_black = std::all_of(
      settled_boot.bytes.begin(), settled_boot.bytes.end(),
      [](std::uint8_t byte) { return byte == 0x00; });
  CHECK(all_black);

  test_frames_are_deterministic();
  test_clearing_geometry_leaves_no_residue();
  test_music_page_state_and_fallback();
  test_phone_lifecycle_renders_deterministically();
  test_demo_mode_visual_contract();
  test_capacity_payloads_render_stably();
  test_motion_frames_interpolate_then_settle_without_residue();
  test_diagonal_map_pixels_are_independent_of_partial_buffer_height();

  test_stage_c_product_states();

  // Terminal screens run last: they tear the full UI down.
  moto_nav_ui_show_boot_screen();
  pump(260);
  const Frame boot_again = capture();
  CHECK(std::all_of(boot_again.bytes.begin(), boot_again.bytes.end(),
                    [](std::uint8_t byte) { return byte == 0x00; }));

  moto_nav_ui_show_power_off_screen();
  pump(260);
  const Frame power_off = capture();
  moto_nav_ui_show_power_off_screen();
  pump(260);
  CHECK(power_off.hash == capture().hash);
  CHECK(power_off.hash != settled_boot.hash);

  if (failures != 0) {
    std::cerr << failures << " nav_ui render checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "All nav_ui render checks passed\n";
  return EXIT_SUCCESS;
}
