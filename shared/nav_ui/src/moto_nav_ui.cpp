#include "moto_nav_ui.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <type_traits>

#include "lvgl.h"

LV_FONT_DECLARE(waymate_a_16_84851);
LV_FONT_DECLARE(waymate_a_20_91119);
LV_FONT_DECLARE(waymate_a_28_40830);
LV_FONT_DECLARE(waymate_a_32_74884);
LV_FONT_DECLARE(waymate_a_36_34158);
LV_FONT_DECLARE(waymate_a_56_90603);
LV_FONT_DECLARE(waymate_a_96_58825);
LV_FONT_DECLARE(waymate_noto_16_75639);
LV_FONT_DECLARE(waymate_noto_28_75038);
LV_FONT_DECLARE(moto_font_nav_16);

namespace {

lv_font_t nav_text_font;
lv_font_t navigation_road_font;
lv_font_t media_title_font;
lv_font_t primary_font;
lv_font_t secondary_font;
lv_font_t tertiary_font;
lv_font_t cjk_fallback_font;
lv_font_t cjk_title_font;
lv_font_t cjk_legacy_font;
lv_font_t arrow_fallback_font;
lv_font_t numeric_font;
lv_font_t speed_font;
lv_font_t navigation_status_font;
lv_font_t compass_cardinal_font;

constexpr lv_color_t kBlack = LV_COLOR_MAKE(0x00, 0x00, 0x00);
constexpr lv_color_t kWhite = LV_COLOR_MAKE(0xF3, 0xF4, 0xEF);
constexpr lv_color_t kIce = LV_COLOR_MAKE(0xB8, 0xED, 0xF5);
constexpr lv_color_t kGraphite = LV_COLOR_MAKE(0x30, 0x35, 0x39);
// Real surrounding roads need to remain legible on the AMOLED's true-black
// background.  LV_OPA_70 is 70/255 (not 70 percent), which made the previous
// road layer effectively disappear on the physical display.
constexpr lv_color_t kRoadGray = LV_COLOR_MAKE(0x42, 0x47, 0x4B);
constexpr lv_color_t kRoadMajor = LV_COLOR_MAKE(0x62, 0x69, 0x6D);
constexpr lv_color_t kRoadMinor = LV_COLOR_MAKE(0x2B, 0x30, 0x33);
constexpr lv_color_t kBuildingGray = LV_COLOR_MAKE(0x24, 0x29, 0x2C);
constexpr lv_color_t kBuildingLandmark = LV_COLOR_MAKE(0x38, 0x40, 0x44);
constexpr lv_color_t kQuiet = LV_COLOR_MAKE(0x78, 0x7E, 0x7F);
constexpr lv_color_t kSoft = LV_COLOR_MAKE(0xAE, 0xB2, 0xB0);
constexpr lv_color_t kAmber = LV_COLOR_MAKE(0xE6, 0xC8, 0x4F);
constexpr lv_color_t kRed = LV_COLOR_MAKE(0xFF, 0x4B, 0x43);
constexpr lv_color_t kGreen = LV_COLOR_MAKE(0x69, 0xD4, 0x94);
constexpr double kPi = 3.14159265358979323846;
constexpr int kCompassTickCount = 24;
constexpr int kSpeedTickCount = 6;
constexpr int kDesignWidth = 360;
// The W's visible ink centroid is 5 design px above the midpoint of its
// path box; lower the boot mark by that amount on the round display.
constexpr int kBootMarkOpticalYOffset = 5;
constexpr int kSpeedHeroOpticalYOffset = 0;
constexpr int kSpeedUnknownOpticalYOffset = -5;
constexpr int kCompassStackOpticalYOffset = -34;
constexpr std::uint32_t kPageDotsVisibleMs = 5'000;
// Keep LVGL, the UI interpolation timer and IMU presentation on the same
// 40 Hz cadence. The previous 40/33 ms mismatch periodically produced a
// 66 ms visual gap even when both tasks were otherwise keeping up.
constexpr std::uint32_t kRouteMotionFrameMs = 25;
static_assert(LV_DEF_REFR_PERIOD == kRouteMotionFrameMs,
              "LVGL refresh and map motion must use the same cadence");
constexpr std::uint32_t kConnectionSuccessHoldMs = 920;

enum class LifecycleVisual : std::uint8_t {
    Hidden = 0,
    PhoneOffline,
    PhoneConnecting,
    Connected,
    Ready,
    Planning,
};

constexpr int px(int value) {
    return value >= 0
               ? (value * MOTO_UI_CANVAS_WIDTH + kDesignWidth / 2) /
                     kDesignWidth
               : -((-value * MOTO_UI_CANVAS_WIDTH + kDesignWidth / 2) /
                   kDesignWidth);
}

constexpr double px(double value) {
    return value * static_cast<double>(MOTO_UI_CANVAS_WIDTH) /
           static_cast<double>(kDesignWidth);
}

struct MapPolyline {
    const lv_point_precise_t *points = nullptr;
    std::uint16_t count = 0;
};

struct Ui {
    lv_obj_t *screen = nullptr;
    lv_obj_t *pages[MOTO_UI_PAGE_COUNT]{};
    lv_obj_t *page_dots[MOTO_UI_PAGE_COUNT]{};
    lv_timer_t *page_dots_timer = nullptr;
    moto_ui_page_t page = MOTO_UI_PAGE_NAVIGATION;
    bool page_dots_visible = true;

    lv_obj_t *nav_map = nullptr;
    lv_obj_t *nav_buildings[MOTO_UI_BUILDING_FOOTPRINT_CAPACITY]{};
    MapPolyline nav_building_lines[MOTO_UI_BUILDING_FOOTPRINT_CAPACITY]{};
    lv_point_precise_t nav_building_points[
        MOTO_UI_BUILDING_POINT_CAPACITY +
        MOTO_UI_BUILDING_FOOTPRINT_CAPACITY]{};
    float nav_building_x[MOTO_UI_BUILDING_POINT_CAPACITY]{};
    float nav_building_y[MOTO_UI_BUILDING_POINT_CAPACITY]{};
    float nav_building_target_x[MOTO_UI_BUILDING_POINT_CAPACITY]{};
    float nav_building_target_y[MOTO_UI_BUILDING_POINT_CAPACITY]{};
    moto_ui_building_span_t
        nav_building_spans[MOTO_UI_BUILDING_FOOTPRINT_CAPACITY]{};
    std::uint8_t nav_building_point_count = 0;
    std::uint8_t nav_building_footprint_count = 0;
    std::uint32_t nav_building_scene_revision = 0;
    lv_obj_t *nav_roads[MOTO_UI_ROAD_POLYLINE_CAPACITY]{};
    MapPolyline nav_road_lines[MOTO_UI_ROAD_POLYLINE_CAPACITY]{};
    lv_point_precise_t nav_road_points[MOTO_UI_ROAD_POINT_CAPACITY]{};
    float nav_road_x[MOTO_UI_ROAD_POINT_CAPACITY]{};
    float nav_road_y[MOTO_UI_ROAD_POINT_CAPACITY]{};
    float nav_road_target_x[MOTO_UI_ROAD_POINT_CAPACITY]{};
    float nav_road_target_y[MOTO_UI_ROAD_POINT_CAPACITY]{};
    moto_ui_polyline_span_t
        nav_road_spans[MOTO_UI_ROAD_POLYLINE_CAPACITY]{};
    std::uint8_t nav_road_point_count = 0;
    std::uint8_t nav_road_polyline_count = 0;
    std::uint32_t nav_road_scene_revision = 0;
    lv_obj_t *nav_route_shadow = nullptr;
    lv_obj_t *nav_route = nullptr;
    MapPolyline nav_route_shadow_line{};
    MapPolyline nav_route_line{};
    lv_point_precise_t nav_route_points[MOTO_UI_ROUTE_POINT_CAPACITY]{};
    float nav_route_x[MOTO_UI_ROUTE_POINT_CAPACITY]{};
    float nav_route_y[MOTO_UI_ROUTE_POINT_CAPACITY]{};
    float nav_route_target_x[MOTO_UI_ROUTE_POINT_CAPACITY]{};
    float nav_route_target_y[MOTO_UI_ROUTE_POINT_CAPACITY]{};
    std::uint8_t nav_route_point_count = 0;
    std::uint8_t nav_route_target_count = 0;
    std::uint32_t nav_route_identity = 0;
    std::uint32_t nav_route_generation = 0;
    lv_timer_t *nav_route_motion_timer = nullptr;
    lv_obj_t *nav_marker = nullptr;
    lv_obj_t *nav_status = nullptr;
    lv_obj_t *nav_road = nullptr;
    lv_obj_t *connection_status[MOTO_UI_PAGE_COUNT]{};
    lv_obj_t *nav_distance = nullptr;
    lv_obj_t *nav_unit = nullptr;
    lv_obj_t *nav_maneuver = nullptr;
    moto_maneuver_t nav_maneuver_type = MOTO_MANEUVER_STRAIGHT;
    lv_obj_t *nav_limit = nullptr;
    lv_obj_t *nav_limit_value = nullptr;
    lv_obj_t *nav_progress = nullptr;

    // A full-screen empty-state surface replaces the old tiny
    // WAITING FOR PHONE / WAITING FOR ROUTE caption. It is kept inside the
    // navigation page so the speed and compass tools remain independently
    // usable while the phone is disconnected.
    lv_obj_t *nav_lifecycle = nullptr;
    lv_obj_t *nav_lifecycle_symbol = nullptr;
    lv_obj_t *nav_lifecycle_title = nullptr;
    lv_obj_t *nav_lifecycle_subtitle = nullptr;
    lv_obj_t *nav_lifecycle_kicker = nullptr;
    lv_timer_t *nav_lifecycle_timer = nullptr;
    lv_timer_t *nav_success_timer = nullptr;
    moto_ui_phone_connection_t phone_connection = MOTO_UI_PHONE_OFFLINE;
    LifecycleVisual lifecycle_visual = LifecycleVisual::Hidden;
    LifecycleVisual lifecycle_target = LifecycleVisual::Hidden;
    std::uint16_t lifecycle_phase_deg = 0;
    bool lifecycle_success_active = false;
    bool navigation_has_guidance = false;
    bool navigation_route_request_in_flight = false;

    lv_obj_t *speed_arc = nullptr;
    lv_obj_t *speed_value = nullptr;
    lv_obj_t *speed_ticks[kSpeedTickCount]{};
    lv_point_precise_t speed_tick_points[kSpeedTickCount][2]{};

    lv_obj_t *compass_heading = nullptr;
    lv_obj_t *compass_cardinal = nullptr;
    lv_obj_t *compass_speed = nullptr;
    lv_obj_t *compass_ticks[kCompassTickCount]{};
    lv_point_precise_t compass_tick_points[kCompassTickCount][2]{};
    lv_obj_t *compass_letters[4]{};

    lv_obj_t *music_source = nullptr;
    lv_obj_t *music_title = nullptr;
    lv_obj_t *music_artist = nullptr;
    lv_obj_t *music_symbol = nullptr;
    lv_obj_t *music_buttons[4]{};
    lv_obj_t *music_button_labels[4]{};
    moto_music_state_t music{};
    char music_source_text[32]{};
    char music_title_text[64]{};
    char music_artist_text[48]{};

    moto_music_command_callback_t music_callback = nullptr;
    void *music_callback_context = nullptr;
    moto_page_change_callback_t page_callback = nullptr;
    void *page_callback_context = nullptr;
    moto_demo_change_callback_t demo_callback = nullptr;
    void *demo_callback_context = nullptr;
    lv_obj_t *backtrack_title = nullptr, *backtrack_distance = nullptr;
    lv_obj_t *backtrack_hint = nullptr, *backtrack_remaining = nullptr;
    lv_obj_t *backtrack_basis = nullptr, *backtrack_map = nullptr, *backtrack_arrow = nullptr;
    lv_point_precise_t backtrack_arrow_points[5]{};
    moto_ui_backtrack_state_t backtrack{};
    bool music_page_enabled = true;
    bool demo_active = false;
    bool reduce_motion = false;
} ui;

void reset_ui_state() {
    static_assert(std::is_trivially_copyable_v<Ui>,
                  "Ui must remain safe to reset without a stack temporary");

    // `ui = {}` materializes the complete aggregate as a temporary.  The
    // offline map buffers make Ui about 15 KiB, so that temporary can consume
    // nearly the whole ESP-IDF main-task stack before LVGL is called.  Clear
    // the retained instance in place and restore the two non-zero defaults.
    std::memset(&ui, 0, sizeof(ui));
    ui.page = MOTO_UI_PAGE_NAVIGATION;
    ui.page_dots_visible = true;
    ui.nav_maneuver_type = MOTO_MANEUVER_STRAIGHT;
    ui.phone_connection = MOTO_UI_PHONE_OFFLINE;
    ui.lifecycle_visual = LifecycleVisual::Hidden;
    ui.lifecycle_target = LifecycleVisual::Hidden;
    ui.music_page_enabled = true;
    // Force the first geometry payload to bind every mutable LVGL line even
    // when its protocol revision happens to start at zero.
    ui.nav_route_generation = ~std::uint32_t{0};
    ui.nav_route_identity = ~std::uint32_t{0};
    ui.nav_road_scene_revision = ~std::uint32_t{0};
    ui.nav_building_scene_revision = ~std::uint32_t{0};
}

lv_obj_t *make_layer(lv_obj_t *parent) {
    lv_obj_t *layer = lv_obj_create(parent);
    lv_obj_remove_style_all(layer);
    lv_obj_set_size(layer, MOTO_UI_CANVAS_WIDTH, MOTO_UI_CANVAS_HEIGHT);
    lv_obj_set_pos(layer, 0, 0);
    lv_obj_remove_flag(layer, LV_OBJ_FLAG_SCROLLABLE);
    return layer;
}

lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font,
                     lv_color_t color, const char *text) {
    lv_obj_t *label = lv_label_create(parent);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, color, 0);
    lv_label_set_text(label, text);
    return label;
}

struct TabularFontMetrics {
    const lv_font_t *source = nullptr;
    std::uint16_t digit_advance = 0;
};

constexpr std::uint8_t kRightArrowA4[] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0xFF,
    0x00, 0x00, 0x00, 0x00, 0x0F, 0xFF, 0xFF,
    0x00, 0x00, 0x00, 0x0F, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x00, 0x00, 0x00, 0x0F, 0xFF, 0xFF, 0xFF,
    0x00, 0x00, 0x00, 0x00, 0x0F, 0xFF, 0xFF,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0xFF,
};

bool arrow_glyph_descriptor(const lv_font_t *, lv_font_glyph_dsc_t *glyph,
                            std::uint32_t codepoint, std::uint32_t) {
    if(codepoint != 0x2192) return false;
    glyph->adv_w = 16;
    glyph->box_w = 14;
    glyph->box_h = 8;
    glyph->ofs_x = 0;
    glyph->ofs_y = 0;
    glyph->stride = 7;
    glyph->format = LV_FONT_GLYPH_FORMAT_A4;
    glyph->req_raw_bitmap = 1;
    glyph->gid.src = kRightArrowA4;
    return true;
}

const void *arrow_glyph_bitmap(lv_font_glyph_dsc_t *glyph, lv_draw_buf_t *) {
    return glyph->gid.src;
}

TabularFontMetrics navigation_digit_metrics;
TabularFontMetrics speed_digit_metrics;

bool tabular_digit_metrics(const lv_font_t *font,
                           lv_font_glyph_dsc_t *glyph,
                           std::uint32_t letter, std::uint32_t next) {
    const auto *metrics = static_cast<const TabularFontMetrics *>(font->user_data);
    if(metrics == nullptr || metrics->source == nullptr) return false;
    const bool found = metrics->source->get_glyph_dsc(
        metrics->source, glyph, letter, next);
    if(found && letter >= '0' && letter <= '9') {
        const int inset = (metrics->digit_advance - glyph->adv_w) / 2;
        glyph->ofs_x += static_cast<lv_coord_t>(inset);
        glyph->adv_w = metrics->digit_advance;
    }
    return found;
}

void set_tabular_digits(lv_font_t &font, const lv_font_t &source,
                        TabularFontMetrics &metrics) {
    metrics.source = &source;
    metrics.digit_advance = 0;
    for(std::uint32_t digit = '0'; digit <= '9'; ++digit) {
        lv_font_glyph_dsc_t glyph{};
        if(source.get_glyph_dsc(&source, &glyph, digit, 0)) {
            metrics.digit_advance = std::max<std::uint16_t>(
                metrics.digit_advance, glyph.adv_w);
        }
    }
    font.get_glyph_dsc = tabular_digit_metrics;
    font.user_data = &metrics;
}

void configure_typography() {
    primary_font = waymate_a_28_40830;
    primary_font.fallback = &lv_font_montserrat_28;
    secondary_font = waymate_a_20_91119;
    secondary_font.fallback = &lv_font_montserrat_20;
    tertiary_font = waymate_a_16_84851;
    arrow_fallback_font = {};
    arrow_fallback_font.get_glyph_dsc = arrow_glyph_descriptor;
    arrow_fallback_font.get_glyph_bitmap = arrow_glyph_bitmap;
    arrow_fallback_font.line_height = tertiary_font.line_height;
    arrow_fallback_font.base_line = tertiary_font.base_line;
    arrow_fallback_font.static_bitmap = 1;
    arrow_fallback_font.fallback = &lv_font_montserrat_16;
    tertiary_font.fallback = &arrow_fallback_font;
    cjk_fallback_font = waymate_noto_16_75639;
    cjk_legacy_font = moto_font_nav_16;
    cjk_fallback_font.fallback = &cjk_legacy_font;
    cjk_legacy_font.fallback = &lv_font_montserrat_16;
    arrow_fallback_font.fallback = &cjk_fallback_font;
    cjk_title_font = waymate_noto_28_75038;
    nav_text_font = waymate_a_16_84851;
    nav_text_font.line_height = cjk_fallback_font.line_height;
    nav_text_font.base_line = cjk_fallback_font.base_line;
    nav_text_font.fallback = &cjk_fallback_font;
    // Keep road labels on Noto's actual 28 px line box and baseline. This
    // instance is used only by the navigation road label; global Inter fonts
    // retain their original metrics on every other page.
    navigation_road_font = waymate_a_28_40830;
    navigation_road_font.line_height = cjk_title_font.line_height;
    navigation_road_font.base_line = cjk_title_font.base_line;
    navigation_road_font.fallback = &cjk_title_font;
    media_title_font = waymate_a_28_40830;
    media_title_font.fallback = &cjk_title_font;
    numeric_font = waymate_a_56_90603;
    numeric_font.kerning = LV_FONT_KERNING_NONE;
    set_tabular_digits(numeric_font, waymate_a_56_90603,
                       navigation_digit_metrics);
    speed_font = waymate_a_96_58825;
    speed_font.kerning = LV_FONT_KERNING_NONE;
    set_tabular_digits(speed_font, waymate_a_96_58825, speed_digit_metrics);
    navigation_status_font = waymate_a_32_74884;
    navigation_status_font.fallback = &cjk_title_font;
    navigation_status_font.kerning = LV_FONT_KERNING_NONE;
    compass_cardinal_font = waymate_a_36_34158;
    compass_cardinal_font.kerning = LV_FONT_KERNING_NONE;
}

void copy_text(char *destination, std::size_t capacity, const char *source,
               const char *fallback) {
    if(capacity == 0) return;
    const char *value = source != nullptr && source[0] != '\0' ? source : fallback;
    std::snprintf(destination, capacity, "%s", value != nullptr ? value : "");
    // Drop an incomplete UTF-8 codepoint when a fixed BLE text buffer fills.
    const std::size_t length = std::strlen(destination);
    if(length == capacity - 1) {
        std::size_t start = length;
        while(start > 0 && (static_cast<unsigned char>(destination[start - 1]) & 0xC0) == 0x80) --start;
        if(start > 0) {
            --start;
            const unsigned char lead = destination[start];
            const std::size_t expected = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
            if(length - start < expected) destination[start] = '\0';
        }
    }
}

lv_color_t traffic_color(moto_traffic_t traffic) {
    switch(traffic) {
        case MOTO_TRAFFIC_CLEAR: return kGreen;
        case MOTO_TRAFFIC_SLOW: return kAmber;
        case MOTO_TRAFFIC_CONGESTED:
        case MOTO_TRAFFIC_SEVERE: return kRed;
        default: return kQuiet;
    }
}

const char *cardinal_name(std::uint16_t heading) {
    static const char *names[] = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"};
    return names[((heading + 22U) / 45U) % 8U];
}

void draw_vehicle_marker(lv_event_t *event) {
    lv_obj_t *object = lv_event_get_target_obj(event);
    lv_area_t area;
    lv_obj_get_coords(object, &area);
    lv_layer_t *layer = lv_event_get_layer(event);

    lv_draw_triangle_dsc_t triangle;
    lv_draw_triangle_dsc_init(&triangle);
    triangle.color = kBlack;
    triangle.opa = LV_OPA_COVER;
    triangle.p[0] = {static_cast<lv_value_precise_t>(area.x1 + px(17)),
                     static_cast<lv_value_precise_t>(area.y1)};
    triangle.p[1] = {static_cast<lv_value_precise_t>(area.x1),
                     static_cast<lv_value_precise_t>(area.y1 + px(36))};
    triangle.p[2] = {static_cast<lv_value_precise_t>(area.x1 + px(34)),
                     static_cast<lv_value_precise_t>(area.y1 + px(36))};
    lv_draw_triangle(layer, &triangle);

    triangle.color = kWhite;
    triangle.p[0] = {static_cast<lv_value_precise_t>(area.x1 + px(17)),
                     static_cast<lv_value_precise_t>(area.y1 + px(5))};
    triangle.p[1] = {static_cast<lv_value_precise_t>(area.x1 + px(6)),
                     static_cast<lv_value_precise_t>(area.y1 + px(30))};
    triangle.p[2] = {static_cast<lv_value_precise_t>(area.x1 + px(28)),
                     static_cast<lv_value_precise_t>(area.y1 + px(30))};
    lv_draw_triangle(layer, &triangle);
}

void update_page_dots() {
    for(int i = 0; i < MOTO_UI_PAGE_COUNT; ++i) {
        const bool active = i == static_cast<int>(ui.page);
        lv_obj_set_size(ui.page_dots[i], px(active ? 16 : 5), px(5));
        lv_obj_set_style_radius(ui.page_dots[i], px(3), 0);
        lv_obj_set_style_bg_color(ui.page_dots[i], active ? kWhite : kGraphite, 0);
        lv_obj_set_x(ui.page_dots[i], px(145 + (i == MOTO_UI_PAGE_BACKTRACK ? 0 : i) * 22 - (active ? 5 : 0)));
        const bool available = (i != MOTO_UI_PAGE_MUSIC || ui.music_page_enabled) &&
            (i != MOTO_UI_PAGE_BACKTRACK || ui.backtrack.active) &&
            (i != MOTO_UI_PAGE_NAVIGATION || !ui.backtrack.active);
        if(ui.page_dots_visible && available) {
            lv_obj_remove_flag(ui.page_dots[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(ui.page_dots[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
}

void hide_page_dots(lv_timer_t *) {
    ui.page_dots_visible = false;
    update_page_dots();
    if(ui.page_dots_timer != nullptr) lv_timer_pause(ui.page_dots_timer);
}

void reveal_page_dots() {
    if(ui.screen == nullptr || ui.page_dots[0] == nullptr) return;
    ui.page_dots_visible = true;
    update_page_dots();
    if(ui.page_dots_timer != nullptr) {
        lv_timer_set_period(ui.page_dots_timer, kPageDotsVisibleMs);
        lv_timer_reset(ui.page_dots_timer);
        lv_timer_resume(ui.page_dots_timer);
    }
}

void interaction_event(lv_event_t *) {
    reveal_page_dots();
}

void install_interaction_wake(lv_obj_t *object) {
    if(object == nullptr) return;
    lv_obj_add_event_cb(object, interaction_event, LV_EVENT_PRESSED, nullptr);
    const std::uint32_t child_count = lv_obj_get_child_count(object);
    for(std::uint32_t index = 0; index < child_count; ++index) {
        install_interaction_wake(lv_obj_get_child(object,
                                                  static_cast<int32_t>(index)));
    }
}

void show_page(moto_ui_page_t page, bool reveal_on_same_page = false) {
    if(page < MOTO_UI_PAGE_NAVIGATION || page >= MOTO_UI_PAGE_COUNT) return;
    if(page == MOTO_UI_PAGE_MUSIC && !ui.music_page_enabled) {
        page = MOTO_UI_PAGE_NAVIGATION;
    }
    if(page == MOTO_UI_PAGE_BACKTRACK && !ui.backtrack.active) page = MOTO_UI_PAGE_NAVIGATION;
    const bool changed = page != ui.page;
    ui.page = page;
    for(int i = 0; i < MOTO_UI_PAGE_COUNT; ++i) {
        if(i == static_cast<int>(page)) {
            lv_obj_remove_flag(ui.pages[i], LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(ui.pages[i], LV_OBJ_FLAG_HIDDEN);
        }
    }
    update_page_dots();
    // Navigation state arrives continuously. Only a real page transition or
    // user action may restart the five-second affordance timer.
    if(changed || reveal_on_same_page) reveal_page_dots();
}

void gesture_event(lv_event_t *) {
    lv_indev_t *indev = lv_indev_active();
    if(indev == nullptr) return;
    const lv_dir_t direction = lv_indev_get_gesture_dir(indev);
    if(direction != LV_DIR_LEFT && direction != LV_DIR_RIGHT) return;
    const moto_ui_page_t order[] = {
        ui.backtrack.active ? MOTO_UI_PAGE_BACKTRACK : MOTO_UI_PAGE_NAVIGATION,
        MOTO_UI_PAGE_SPEED, MOTO_UI_PAGE_COMPASS, MOTO_UI_PAGE_MUSIC};
    int index = 0;
    for(int i = 0; i < 4; ++i) if(order[i] == ui.page) index = i;
    const int step = direction == LV_DIR_LEFT ? 1 : -1;
    int next = (index + step + 4) % 4;
    if(order[next] == MOTO_UI_PAGE_MUSIC && !ui.music_page_enabled) next = (next + step + 4) % 4;
    const auto requested = order[next];
    if(ui.page_callback != nullptr) {
        ui.page_callback(requested, ui.page_callback_context);
    } else {
        show_page(requested, true);
    }
    reveal_page_dots();
    lv_indev_wait_release(indev);
}

void draw_map_line(lv_layer_t *layer, const lv_draw_line_dsc_t &line) {
    const lv_area_t original_clip = layer->_clip_area;
    lv_area_t visible{
        std::max(original_clip.x1, static_cast<int32_t>(
            std::min(line.p1.x, line.p2.x) - line.width)),
        std::max(original_clip.y1, static_cast<int32_t>(
            std::min(line.p1.y, line.p2.y) - line.width)),
        std::min(original_clip.x2, static_cast<int32_t>(
            std::max(line.p1.x, line.p2.x) + line.width)),
        std::min(original_clip.y2, static_cast<int32_t>(
            std::max(line.p1.y, line.p2.y) + line.width)),
    };
    if(visible.x1 > visible.x2 || visible.y1 > visible.y2) return;
    const float dx = static_cast<float>(line.p2.x - line.p1.x);
    const float dy = static_cast<float>(line.p2.y - line.p1.y);
    constexpr int32_t band_height = 32;
    if(std::abs(dy) <= band_height || std::abs(dx) <= 64.0F ||
       visible.y2 - visible.y1 < band_height) {
        lv_draw_line(layer, &line);
        return;
    }

    // LVGL masks every pixel in a diagonal's bounding rectangle, including
    // the empty space beside a long thin street. Narrow that rectangle per
    // non-overlapping band. Keep the original endpoints so antialiasing and
    // round caps remain identical, including where adjacent bands meet.
    const float slope = dx / dy;
    const float padding = static_cast<float>(line.width) + 2.0F;
    const float minimum_y = static_cast<float>(std::min(line.p1.y, line.p2.y));
    const float maximum_y = static_cast<float>(std::max(line.p1.y, line.p2.y));
    for(int32_t y = visible.y1; y <= visible.y2; y += band_height) {
        lv_area_t band = visible;
        band.y1 = y;
        band.y2 = std::min(y + band_height - 1, visible.y2);
        const float low = std::clamp(static_cast<float>(band.y1) - padding,
                                     minimum_y, maximum_y);
        const float high = std::clamp(static_cast<float>(band.y2) + padding,
                                      minimum_y, maximum_y);
        const float a = line.p1.x + slope * (low - line.p1.y);
        const float b = line.p1.x + slope * (high - line.p1.y);
        band.x1 = std::max(band.x1, static_cast<int32_t>(
            std::floor(std::min(a, b) - padding)));
        band.x2 = std::min(band.x2, static_cast<int32_t>(
            std::ceil(std::max(a, b) + padding)));
        if(band.x1 > band.x2) continue;
        // lv_draw_line copies this clip into its task before dispatching.
        layer->_clip_area = band;
        lv_draw_line(layer, &line);
    }
    layer->_clip_area = original_clip;
}

void draw_map_polyline(lv_event_t *event) {
    lv_obj_t *object = lv_event_get_target_obj(event);
    const auto code = lv_event_get_code(event);
    if(code == LV_EVENT_REFR_EXT_DRAW_SIZE) {
        auto *size = static_cast<int32_t *>(lv_event_get_param(event));
        *size = std::max(*size, lv_obj_get_style_line_width(object, LV_PART_MAIN));
        return;
    }
    if(code != LV_EVENT_DRAW_MAIN) return;
    const auto *polyline = static_cast<const MapPolyline *>(
        lv_event_get_user_data(event));
    if(polyline->points == nullptr || polyline->count < 2) return;
    lv_layer_t *layer = lv_event_get_layer(event);
    lv_area_t object_area;
    lv_obj_get_coords(object, &object_area);
    lv_draw_line_dsc_t line;
    lv_draw_line_dsc_init(&line);
    line.base.layer = layer;
    lv_obj_init_draw_line_dsc(object, LV_PART_MAIN, &line);
    for(std::uint16_t index = 1; index < polyline->count; ++index) {
        line.p1 = polyline->points[index - 1];
        line.p2 = polyline->points[index];
        line.p1.x += object_area.x1;
        line.p2.x += object_area.x1;
        line.p1.y += object_area.y1;
        line.p2.y += object_area.y1;
        draw_map_line(layer, line);
        line.round_start = 0;
    }
}

lv_obj_t *create_map_polyline(lv_obj_t *parent, MapPolyline &polyline) {
    lv_obj_t *object = lv_obj_create(parent);
    lv_obj_remove_style_all(object);
    lv_obj_remove_flag(object, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(object, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_user_data(object, &polyline);
    lv_obj_add_event_cb(object, draw_map_polyline, LV_EVENT_ALL, &polyline);
    return object;
}

void set_map_polyline_points(lv_obj_t *object, const lv_point_precise_t *points,
                            std::uint16_t count) {
    auto *polyline = static_cast<MapPolyline *>(lv_obj_get_user_data(object));
    polyline->points = points;
    polyline->count = count;
    lv_obj_invalidate(object);
}

bool apply_route_geometry_frame(bool rebind_lines = true) {
    if(ui.nav_route_point_count < 2) return false;
    bool pixels_changed = false;
    for(std::uint8_t i = 0; i < ui.nav_route_point_count; ++i) {
        const auto x = static_cast<lv_value_precise_t>(
            std::lround(ui.nav_route_x[i]));
        const auto y = static_cast<lv_value_precise_t>(
            std::lround(ui.nav_route_y[i]));
        pixels_changed = pixels_changed || ui.nav_route_points[i].x != x ||
                         ui.nav_route_points[i].y != y;
        ui.nav_route_points[i] = {x, y};
    }
    if(rebind_lines) {
        set_map_polyline_points(ui.nav_route_shadow, ui.nav_route_points,
                                   ui.nav_route_point_count);
        set_map_polyline_points(ui.nav_route, ui.nav_route_points,
                                   ui.nav_route_point_count);
    }
    return pixels_changed || rebind_lines;
}

bool apply_road_geometry_frame(bool rebind_lines = true) {
    if(ui.nav_road_point_count < 2 || ui.nav_road_polyline_count == 0) {
        return false;
    }
    bool pixels_changed = false;
    for(std::uint8_t i = 0; i < ui.nav_road_point_count; ++i) {
        const auto x = static_cast<lv_value_precise_t>(
            std::lround(ui.nav_road_x[i]));
        const auto y = static_cast<lv_value_precise_t>(
            std::lround(ui.nav_road_y[i]));
        pixels_changed = pixels_changed || ui.nav_road_points[i].x != x ||
                         ui.nav_road_points[i].y != y;
        ui.nav_road_points[i] = {x, y};
    }
    if(rebind_lines) {
        for(std::uint8_t i = 0; i < ui.nav_road_polyline_count; ++i) {
            const moto_ui_polyline_span_t span = ui.nav_road_spans[i];
            set_map_polyline_points(
                ui.nav_roads[i],
                &ui.nav_road_points[span.first_point_index],
                span.point_count);
        }
    }
    return pixels_changed || rebind_lines;
}

bool apply_building_geometry_frame(bool rebind_lines = true) {
    if(ui.nav_building_point_count < 3 ||
       ui.nav_building_footprint_count == 0) return false;
    bool pixels_changed = false;
    std::size_t packed_index = 0;
    for(std::uint8_t footprint_index = 0;
        footprint_index < ui.nav_building_footprint_count;
        ++footprint_index) {
        const moto_ui_building_span_t span =
            ui.nav_building_spans[footprint_index];
        for(std::uint8_t point_index = 0; point_index < span.point_count;
            ++point_index) {
            const std::size_t source = span.first_point_index + point_index;
            const auto x = static_cast<lv_value_precise_t>(
                std::lround(ui.nav_building_x[source]));
            const auto y = static_cast<lv_value_precise_t>(
                std::lround(ui.nav_building_y[source]));
            pixels_changed = pixels_changed ||
                ui.nav_building_points[packed_index].x != x ||
                ui.nav_building_points[packed_index].y != y;
            ui.nav_building_points[packed_index++] = {x, y};
        }
        // BLE omits the duplicate closing point; LVGL needs it explicitly.
        const auto closing =
            ui.nav_building_points[packed_index - span.point_count];
        pixels_changed = pixels_changed ||
            ui.nav_building_points[packed_index].x != closing.x ||
            ui.nav_building_points[packed_index].y != closing.y;
        ui.nav_building_points[packed_index] = closing;
        if(rebind_lines) {
            set_map_polyline_points(
                ui.nav_buildings[footprint_index],
                &ui.nav_building_points[packed_index - span.point_count],
                span.point_count + 1U);
        }
        ++packed_index;
    }
    return pixels_changed || rebind_lines;
}

void route_motion_tick(lv_timer_t *) {
    if(ui.nav_route_target_count < 2 || ui.nav_route_point_count < 2) return;
    // 0.39 at 25 ms has approximately the same smoothing time constant as
    // the old 0.56 at 40 ms, but supplies smaller and more frequent steps.
    // Screen coordinates need subpixel precision, not geographic doubles.
    // Float uses the ESP32-S3 FPU for every point in this 40 Hz hot loop.
    const float blend = ui.reduce_motion ? 1.0F : 0.39F;
    bool route_moved = false;
    for(std::uint8_t i = 0; i < ui.nav_route_point_count; ++i) {
        const float dx = ui.nav_route_target_x[i] - ui.nav_route_x[i];
        const float dy = ui.nav_route_target_y[i] - ui.nav_route_y[i];
        if(std::abs(dx) < 0.08F && std::abs(dy) < 0.08F) {
            ui.nav_route_x[i] = ui.nav_route_target_x[i];
            ui.nav_route_y[i] = ui.nav_route_target_y[i];
            continue;
        }
        ui.nav_route_x[i] += dx * blend;
        ui.nav_route_y[i] += dy * blend;
        route_moved = true;
    }
    bool roads_moved = false;
    for(std::uint8_t i = 0; i < ui.nav_road_point_count; ++i) {
        const float dx = ui.nav_road_target_x[i] - ui.nav_road_x[i];
        const float dy = ui.nav_road_target_y[i] - ui.nav_road_y[i];
        if(std::abs(dx) < 0.08F && std::abs(dy) < 0.08F) {
            ui.nav_road_x[i] = ui.nav_road_target_x[i];
            ui.nav_road_y[i] = ui.nav_road_target_y[i];
            continue;
        }
        ui.nav_road_x[i] += dx * blend;
        ui.nav_road_y[i] += dy * blend;
        roads_moved = true;
    }
    bool buildings_moved = false;
    for(std::uint8_t i = 0; i < ui.nav_building_point_count; ++i) {
        const float dx = ui.nav_building_target_x[i] - ui.nav_building_x[i];
        const float dy = ui.nav_building_target_y[i] - ui.nav_building_y[i];
        if(std::abs(dx) < 0.08F && std::abs(dy) < 0.08F) {
            ui.nav_building_x[i] = ui.nav_building_target_x[i];
            ui.nav_building_y[i] = ui.nav_building_target_y[i];
            continue;
        }
        ui.nav_building_x[i] += dx * blend;
        ui.nav_building_y[i] += dy * blend;
        buildings_moved = true;
    }
    // The line objects retain pointers to the mutable point arrays. Ordinary
    // animation therefore only changes those arrays and invalidates the one
    // common map layer. Rebinding every road/building used to invalidate the
    // same 466x232 region dozens of times per frame.
    bool pixels_changed = false;
    if(buildings_moved) {
        pixels_changed = apply_building_geometry_frame(false) || pixels_changed;
    }
    if(roads_moved) {
        pixels_changed = apply_road_geometry_frame(false) || pixels_changed;
    }
    if(route_moved) {
        pixels_changed = apply_route_geometry_frame(false) || pixels_changed;
    }
    if(pixels_changed) lv_obj_invalidate(ui.nav_map);
}

void update_road_geometry(const moto_ui_state_t *state) {
    const std::uint8_t point_count = std::min<std::uint8_t>(
        state->road_point_count, MOTO_UI_ROAD_POINT_CAPACITY);
    const std::uint8_t polyline_count = std::min<std::uint8_t>(
        state->road_polyline_count, MOTO_UI_ROAD_POLYLINE_CAPACITY);
    if(point_count < 2 || polyline_count == 0) {
        ui.nav_road_point_count = 0;
        ui.nav_road_polyline_count = 0;
        ui.nav_road_scene_revision = state->map_scene_revision;
        for(lv_obj_t *road : ui.nav_roads) {
            lv_obj_add_flag(road, LV_OBJ_FLAG_HIDDEN);
        }
        return;
    }

    bool spans_changed =
        ui.nav_road_scene_revision != state->map_scene_revision ||
        ui.nav_road_point_count != point_count ||
        ui.nav_road_polyline_count != polyline_count;
    for(std::uint8_t i = 0; i < point_count; ++i) {
        ui.nav_road_target_x[i] = state->road_points[i].x;
        ui.nav_road_target_y[i] = state->road_points[i].y;
    }
    for(std::uint8_t i = 0; i < polyline_count; ++i) {
        const moto_ui_polyline_span_t next = state->road_polylines[i];
        spans_changed = spans_changed ||
                        ui.nav_road_spans[i].first_point_index !=
                            next.first_point_index ||
                        ui.nav_road_spans[i].point_count != next.point_count ||
                        ui.nav_road_spans[i].road_class != next.road_class;
        ui.nav_road_spans[i] = next;
    }

    // A wide point can move more than 96 px during a perfectly ordinary fast
    // yaw. Treating screen-space distance as a route replacement made the
    // whole map jump. Only topology/revision changes snap; motion interpolates.
    const bool snap = spans_changed || ui.reduce_motion;
    ui.nav_road_point_count = point_count;
    ui.nav_road_polyline_count = polyline_count;
    ui.nav_road_scene_revision = state->map_scene_revision;
    if(snap) {
        for(std::uint8_t i = 0; i < point_count; ++i) {
            ui.nav_road_x[i] = ui.nav_road_target_x[i];
            ui.nav_road_y[i] = ui.nav_road_target_y[i];
        }
    }
    if(spans_changed) {
        for(std::uint8_t i = 0; i < MOTO_UI_ROAD_POLYLINE_CAPACITY; ++i) {
            if(i < polyline_count) {
                const std::uint8_t road_class = ui.nav_road_spans[i].road_class;
                const bool major = road_class <= 2U;
                const bool service = road_class >= 4U;
                lv_obj_set_style_line_width(
                    ui.nav_roads[i], px(major ? 4 : (service ? 2 : 3)), 0);
                lv_obj_set_style_line_color(
                    ui.nav_roads[i],
                    major ? kRoadMajor : (service ? kRoadMinor : kRoadGray), 0);
                lv_obj_remove_flag(ui.nav_roads[i], LV_OBJ_FLAG_HIDDEN);
            } else {
                lv_obj_add_flag(ui.nav_roads[i], LV_OBJ_FLAG_HIDDEN);
            }
        }
    }
    if(snap) apply_road_geometry_frame();
}


void update_building_geometry(const moto_ui_state_t *state) {
    const std::uint8_t point_count = std::min<std::uint8_t>(
        state->building_point_count, MOTO_UI_BUILDING_POINT_CAPACITY);
    const std::uint8_t footprint_count = std::min<std::uint8_t>(
        state->building_footprint_count,
        MOTO_UI_BUILDING_FOOTPRINT_CAPACITY);
    if(point_count < 3 || footprint_count == 0) {
        ui.nav_building_point_count = 0;
        ui.nav_building_footprint_count = 0;
        ui.nav_building_scene_revision = state->map_scene_revision;
        for(lv_obj_t *building : ui.nav_buildings) {
            lv_obj_add_flag(building, LV_OBJ_FLAG_HIDDEN);
        }
        return;
    }

    bool spans_changed =
        ui.nav_building_scene_revision != state->map_scene_revision ||
        ui.nav_building_point_count != point_count ||
        ui.nav_building_footprint_count != footprint_count;
    for(std::uint8_t i = 0; i < point_count; ++i) {
        ui.nav_building_target_x[i] = state->building_points[i].x;
        ui.nav_building_target_y[i] = state->building_points[i].y;
    }
    for(std::uint8_t i = 0; i < footprint_count; ++i) {
        const moto_ui_building_span_t next = state->building_footprints[i];
        spans_changed = spans_changed ||
                        ui.nav_building_spans[i].first_point_index !=
                            next.first_point_index ||
                        ui.nav_building_spans[i].point_count !=
                            next.point_count ||
                        ui.nav_building_spans[i].building_class !=
                            next.building_class;
        ui.nav_building_spans[i] = next;
    }

    const bool snap = spans_changed || ui.reduce_motion;
    ui.nav_building_point_count = point_count;
    ui.nav_building_footprint_count = footprint_count;
    ui.nav_building_scene_revision = state->map_scene_revision;
    if(snap) {
        for(std::uint8_t i = 0; i < point_count; ++i) {
            ui.nav_building_x[i] = ui.nav_building_target_x[i];
            ui.nav_building_y[i] = ui.nav_building_target_y[i];
        }
    }
    if(spans_changed) {
        for(std::uint8_t i = 0;
            i < MOTO_UI_BUILDING_FOOTPRINT_CAPACITY; ++i) {
            if(i < footprint_count) {
                const bool landmark =
                    ui.nav_building_spans[i].building_class == 1U;
                lv_obj_set_style_line_color(
                    ui.nav_buildings[i],
                    landmark ? kBuildingLandmark : kBuildingGray, 0);
                lv_obj_set_style_line_width(
                    ui.nav_buildings[i], px(landmark ? 2 : 1), 0);
                lv_obj_remove_flag(ui.nav_buildings[i], LV_OBJ_FLAG_HIDDEN);
            } else {
                lv_obj_add_flag(ui.nav_buildings[i], LV_OBJ_FLAG_HIDDEN);
            }
        }
    }
    if(snap) apply_building_geometry_frame();
}

void update_route_geometry(const moto_ui_state_t *state) {
    const std::uint8_t count = std::min<std::uint8_t>(
        state->route_point_count, MOTO_UI_ROUTE_POINT_CAPACITY);
    if(count < 2) {
        ui.nav_route_point_count = 0;
        ui.nav_route_target_count = 0;
        ui.nav_route_identity = state->route_identity;
        ui.nav_route_generation = state->route_generation;
        lv_obj_add_flag(ui.nav_route_shadow, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(ui.nav_route, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(ui.nav_marker, LV_OBJ_FLAG_HIDDEN);
        return;
    }

    for(std::uint8_t i = 0; i < count; ++i) {
        ui.nav_route_target_x[i] = state->route_points[i].x;
        ui.nav_route_target_y[i] = state->route_points[i].y;
    }

    // A new route or a wholesale reroute should appear immediately. Ordinary
    // GNSS/IMU updates are blended at 40 Hz so the road glides under the fixed
    // rider marker instead of jumping from one phone fix to the next.
    const bool snap = ui.nav_route_identity != state->route_identity ||
                      ui.nav_route_generation != state->route_generation ||
                      ui.nav_route_point_count != count || ui.reduce_motion;
    ui.nav_route_target_count = count;
    ui.nav_route_point_count = count;
    ui.nav_route_identity = state->route_identity;
    ui.nav_route_generation = state->route_generation;
    if(snap) {
        for(std::uint8_t i = 0; i < count; ++i) {
            ui.nav_route_x[i] = ui.nav_route_target_x[i];
            ui.nav_route_y[i] = ui.nav_route_target_y[i];
        }
    }

    lv_obj_remove_flag(ui.nav_route_shadow, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(ui.nav_route, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(ui.nav_marker, LV_OBJ_FLAG_HIDDEN);
    if(snap) apply_route_geometry_frame();
}

lv_point_precise_t arrow_base(const lv_point_precise_t& previous,
                              const lv_point_precise_t& tip,
                              double head_length = px(24.0)) {
    const double dx = static_cast<double>(tip.x - previous.x);
    const double dy = static_cast<double>(tip.y - previous.y);
    const double length = std::max(1.0, std::hypot(dx, dy));
    const double ux = dx / length;
    const double uy = dy / length;
    return {
        static_cast<lv_value_precise_t>(tip.x - ux * head_length),
        static_cast<lv_value_precise_t>(tip.y - uy * head_length),
    };
}

constexpr int icon_px(int value) { return px(value * 3 / 5); }
constexpr double icon_px(double value) { return px(value * 0.6); }

void draw_arrowhead(lv_layer_t *layer, const lv_area_t& area,
                    const lv_point_precise_t& previous,
                    const lv_point_precise_t& tip) {
    const double dx = static_cast<double>(tip.x - previous.x);
    const double dy = static_cast<double>(tip.y - previous.y);
    const double length = std::max(1.0, std::hypot(dx, dy));
    const double ux = dx / length;
    const double uy = dy / length;
    const auto base = arrow_base(previous, tip, icon_px(24.0));
    const double wing = icon_px(18.0);

    lv_draw_triangle_dsc_t triangle;
    lv_draw_triangle_dsc_init(&triangle);
    triangle.color = kWhite;
    triangle.opa = LV_OPA_COVER;
    triangle.p[0] = {
        static_cast<lv_value_precise_t>(area.x1 + tip.x),
        static_cast<lv_value_precise_t>(area.y1 + tip.y),
    };
    triangle.p[1] = {
        static_cast<lv_value_precise_t>(area.x1 + base.x - uy * wing),
        static_cast<lv_value_precise_t>(area.y1 + base.y + ux * wing),
    };
    triangle.p[2] = {
        static_cast<lv_value_precise_t>(area.x1 + base.x + uy * wing),
        static_cast<lv_value_precise_t>(area.y1 + base.y - ux * wing),
    };
    lv_draw_triangle(layer, &triangle);
}

void draw_maneuver_icon(lv_event_t *event) {
    lv_obj_t *object = lv_event_get_target_obj(event);
    lv_area_t area;
    lv_obj_get_coords(object, &area);
    lv_layer_t *layer = lv_event_get_layer(event);

    lv_point_precise_t points[8]{};
    int count = 0;
    switch(ui.nav_maneuver_type) {
        case MOTO_MANEUVER_RIGHT:
            points[0] = {icon_px(34), icon_px(102)};
            points[1] = {icon_px(34), icon_px(63)};
            points[2] = {icon_px(55), icon_px(42)};
            points[3] = {icon_px(105), icon_px(42)};
            count = 4;
            break;
        case MOTO_MANEUVER_LEFT:
            points[0] = {icon_px(82), icon_px(102)};
            points[1] = {icon_px(82), icon_px(63)};
            points[2] = {icon_px(61), icon_px(42)};
            points[3] = {icon_px(11), icon_px(42)};
            count = 4;
            break;
        case MOTO_MANEUVER_SLIGHT_RIGHT:
            points[0] = {icon_px(36), icon_px(102)};
            points[1] = {icon_px(36), icon_px(72)};
            points[2] = {icon_px(96), icon_px(12)};
            count = 3;
            break;
        case MOTO_MANEUVER_SLIGHT_LEFT:
            points[0] = {icon_px(80), icon_px(102)};
            points[1] = {icon_px(80), icon_px(72)};
            points[2] = {icon_px(20), icon_px(12)};
            count = 3;
            break;
        case MOTO_MANEUVER_UTURN:
            points[0] = {icon_px(88), icon_px(102)};
            points[1] = {icon_px(88), icon_px(50)};
            points[2] = {icon_px(82), icon_px(33)};
            points[3] = {icon_px(69), icon_px(23)};
            points[4] = {icon_px(51), icon_px(20)};
            points[5] = {icon_px(34), icon_px(27)};
            points[6] = {icon_px(25), icon_px(43)};
            points[7] = {icon_px(25), icon_px(84)};
            count = 8;
            break;
        case MOTO_MANEUVER_ROUNDABOUT: {
            lv_draw_line_dsc_t stem;
            lv_draw_line_dsc_init(&stem);
            stem.color = kWhite;
            stem.width = icon_px(11);
            stem.round_start = 1;
            stem.round_end = 1;
            stem.p1 = {static_cast<lv_value_precise_t>(area.x1 + icon_px(58)),
                       static_cast<lv_value_precise_t>(area.y1 + icon_px(101))};
            stem.p2 = {static_cast<lv_value_precise_t>(area.x1 + icon_px(58)),
                       static_cast<lv_value_precise_t>(area.y1 + icon_px(79))};
            lv_draw_line(layer, &stem);

            lv_draw_arc_dsc_t circle;
            lv_draw_arc_dsc_init(&circle);
            circle.color = kWhite;
            circle.width = icon_px(11);
            circle.rounded = 1;
            circle.center = {
                static_cast<int32_t>(area.x1 + icon_px(58)),
                static_cast<int32_t>(area.y1 + icon_px(53)),
            };
            circle.radius = icon_px(27);
            circle.start_angle = 86;
            circle.end_angle = 326;
            lv_draw_arc(layer, &circle);

            const lv_point_precise_t previous = {icon_px(69), icon_px(24)};
            const lv_point_precise_t tip = {icon_px(86), icon_px(36)};
            draw_arrowhead(layer, area, previous, tip);
            return;
        }
        case MOTO_MANEUVER_ARRIVE: {
            lv_point_precise_t check[] = {
                {static_cast<lv_value_precise_t>(area.x1 + icon_px(20)), static_cast<lv_value_precise_t>(area.y1 + icon_px(54))},
                {static_cast<lv_value_precise_t>(area.x1 + icon_px(47)), static_cast<lv_value_precise_t>(area.y1 + icon_px(80))},
                {static_cast<lv_value_precise_t>(area.x1 + icon_px(99)), static_cast<lv_value_precise_t>(area.y1 + icon_px(26))}};
            lv_draw_line_dsc_t line;
            lv_draw_line_dsc_init(&line);
            line.color = kGreen;
            line.width = icon_px(12);
            line.round_start = line.round_end = 1;
            line.points = check;
            line.point_cnt = 3;
            lv_draw_line(layer, &line);
            return;
        }
        case MOTO_MANEUVER_STRAIGHT:
        default:
            points[0] = {icon_px(58), icon_px(103)};
            points[1] = {icon_px(58), icon_px(10)};
            count = 2;
            break;
    }

    lv_point_precise_t absolute[8]{};
    const lv_point_precise_t base = arrow_base(points[count - 2],
                                                points[count - 1], icon_px(24.0));
    for(int i = 0; i < count; ++i) {
        const lv_point_precise_t point = i == count - 1 ? base : points[i];
        absolute[i] = {
            static_cast<lv_value_precise_t>(area.x1 + point.x),
            static_cast<lv_value_precise_t>(area.y1 + point.y),
        };
    }
    lv_draw_line_dsc_t line;
    lv_draw_line_dsc_init(&line);
    line.color = kWhite;
    line.width = icon_px(12);
    line.round_start = 1;
    line.round_end = 1;
    line.points = absolute;
    line.point_cnt = count;
    lv_draw_line(layer, &line);
    draw_arrowhead(layer, area, points[count - 2], points[count - 1]);
}

void update_maneuver(moto_maneuver_t maneuver) {
    if(ui.nav_maneuver_type == maneuver) return;
    ui.nav_maneuver_type = maneuver;
    lv_obj_invalidate(ui.nav_maneuver);
}

void draw_segment(lv_layer_t *layer, lv_color_t color, int width,
                  lv_opa_t opacity, const lv_point_precise_t *points,
                  int count) {
    lv_draw_line_dsc_t line;
    lv_draw_line_dsc_init(&line);
    line.color = color;
    line.width = width;
    line.opa = opacity;
    line.round_start = 1;
    line.round_end = 1;
    // LVGL's descriptor predates const-correct polyline inputs; the draw task
    // only reads the points for the duration of this call.
    line.points = const_cast<lv_point_precise_t *>(points);
    line.point_cnt = count;
    lv_draw_line(layer, &line);
}

void draw_disc(lv_layer_t *layer, int x, int y, int diameter,
               lv_color_t color, lv_opa_t opacity) {
    lv_draw_rect_dsc_t disc;
    lv_draw_rect_dsc_init(&disc);
    disc.radius = LV_RADIUS_CIRCLE;
    disc.bg_color = color;
    disc.bg_opa = opacity;
    disc.border_opa = LV_OPA_TRANSP;
    const lv_area_t area = {
        x - diameter / 2,
        y - diameter / 2,
        x + diameter / 2,
        y + diameter / 2,
    };
    lv_draw_rect(layer, &disc, &area);
}

void draw_waymate_mark(lv_event_t *event) {
    lv_area_t area;
    lv_obj_get_coords(lv_event_get_target_obj(event), &area);
    lv_layer_t *layer = lv_event_get_layer(event);
    const double scale = (area.x2 - area.x1 + 1) / 100.0;
    static const int paths[2][6] = {{12,30,28,74,46,20}, {54,30,70,74,88,20}};
    for(const auto &path : paths) {
        lv_point_precise_t points[3];
        for(int i = 0; i < 3; ++i) points[i] = {
            static_cast<lv_value_precise_t>(area.x1 + path[i*2] * scale),
            static_cast<lv_value_precise_t>(area.y1 + path[i*2+1] * scale)};
        draw_segment(layer, kWhite, static_cast<int>(8 * scale), LV_OPA_COVER, points, 3);
    }
}

void draw_connection_symbol(lv_event_t *event) {
    if(ui.lifecycle_visual == LifecycleVisual::Ready ||
       ui.lifecycle_visual == LifecycleVisual::Connected) {
        draw_waymate_mark(event);
        return;
    }
    lv_area_t area;
    lv_obj_get_coords(lv_event_get_target_obj(event), &area);
    lv_layer_t *layer = lv_event_get_layer(event);
    const lv_color_t color = ui.lifecycle_visual == LifecycleVisual::PhoneOffline ? kAmber : kIce;
    const lv_point_precise_t route[] = {
        {static_cast<lv_value_precise_t>(area.x1 + px(20)), static_cast<lv_value_precise_t>(area.y1 + px(95))},
        {static_cast<lv_value_precise_t>(area.x1 + px(58)), static_cast<lv_value_precise_t>(area.y1 + px(95))},
        {static_cast<lv_value_precise_t>(area.x1 + px(90)), static_cast<lv_value_precise_t>(area.y1 + px(55))},
        {static_cast<lv_value_precise_t>(area.x1 + px(130)), static_cast<lv_value_precise_t>(area.y1 + px(55))},
    };
    draw_segment(layer, color, px(5), LV_OPA_COVER, route, 4);
    draw_disc(layer, route[0].x, route[0].y, px(12), color, LV_OPA_COVER);
    draw_disc(layer, route[3].x, route[3].y, px(12), color, LV_OPA_COVER);
    if(ui.lifecycle_visual == LifecycleVisual::PhoneConnecting || ui.lifecycle_visual == LifecycleVisual::Planning) {
        const double t = ui.lifecycle_phase_deg / 360.0 * 3;
        const int segment = std::min(2, static_cast<int>(t));
        const double f = t - segment;
        draw_disc(layer, static_cast<int>(route[segment].x + (route[segment+1].x-route[segment].x)*f),
                  static_cast<int>(route[segment].y + (route[segment+1].y-route[segment].y)*f), px(10), kWhite, LV_OPA_COVER);
    }
}

void set_layer_opacity(void *object, int32_t opacity) {
    lv_obj_set_style_opa(static_cast<lv_obj_t *>(object), opacity, 0);
}

void apply_lifecycle_content(LifecycleVisual visual) {
    ui.lifecycle_visual = visual;
    const char *kicker = "WAYMATE";
    const char *title = "";
    const char *subtitle = "";
    lv_color_t title_color = kWhite;
    switch(visual) {
        case LifecycleVisual::PhoneOffline:
            title = "PHONE LOST";
            title_color = kAmber;
            subtitle = "请打开手机应用";
            break;
        case LifecycleVisual::PhoneConnecting:
            title = "CONNECTING";
            subtitle = "正在建立连接";
            break;
        case LifecycleVisual::Connected:
            title = "CONNECTED";
            subtitle = "连接成功";
            title_color = kGreen;
            break;
        case LifecycleVisual::Ready:
            kicker = "PHONE CONNECTED";
            title = "READY";
            subtitle = "请在手机选择目的地";
            break;
        case LifecycleVisual::Planning:
            kicker = "WAYMATE";
            title = "ROUTE LOADING";
            subtitle = "正在规划路线";
            break;
        case LifecycleVisual::Hidden:
            break;
    }
    lv_label_set_text(ui.nav_lifecycle_kicker, kicker);
    lv_label_set_text(ui.nav_lifecycle_title, title);
    lv_label_set_text(ui.nav_lifecycle_subtitle, subtitle);
    lv_obj_set_style_text_color(ui.nav_lifecycle_title, title_color, 0);
    lv_obj_set_style_text_color(ui.nav_lifecycle_subtitle,
                                visual == LifecycleVisual::Connected
                                    ? kGreen : kSoft,
                                0);
    lv_obj_invalidate(ui.nav_lifecycle_symbol);
}

void lifecycle_fade_in();

void lifecycle_fade_out_complete(lv_anim_t *) {
    if(ui.nav_lifecycle == nullptr) return;
    if(ui.lifecycle_target == LifecycleVisual::Hidden) {
        ui.lifecycle_visual = LifecycleVisual::Hidden;
        lv_obj_add_flag(ui.nav_lifecycle, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_opa(ui.nav_lifecycle, LV_OPA_COVER, 0);
        return;
    }
    apply_lifecycle_content(ui.lifecycle_target);
    lifecycle_fade_in();
}

void lifecycle_fade_in() {
    lv_obj_remove_flag(ui.nav_lifecycle, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_style_opa(ui.nav_lifecycle, LV_OPA_TRANSP, 0);
    lv_anim_t fade;
    lv_anim_init(&fade);
    lv_anim_set_var(&fade, ui.nav_lifecycle);
    lv_anim_set_exec_cb(&fade, set_layer_opacity);
    lv_anim_set_values(&fade, LV_OPA_TRANSP, LV_OPA_COVER);
    lv_anim_set_duration(&fade, 220);
    lv_anim_set_path_cb(&fade, lv_anim_path_ease_out);
    lv_anim_start(&fade);
}

void transition_lifecycle(LifecycleVisual next) {
    if(ui.nav_lifecycle == nullptr) return;
    if(next == ui.lifecycle_target &&
       (next == ui.lifecycle_visual ||
        lv_obj_has_flag(ui.nav_lifecycle, LV_OBJ_FLAG_HIDDEN))) {
        return;
    }
    ui.lifecycle_target = next;
    lv_anim_delete(ui.nav_lifecycle, set_layer_opacity);
    if(ui.reduce_motion) {
        if(next == LifecycleVisual::Hidden) {
            ui.lifecycle_visual = LifecycleVisual::Hidden;
            lv_obj_add_flag(ui.nav_lifecycle, LV_OBJ_FLAG_HIDDEN);
        } else {
            apply_lifecycle_content(next);
            lv_obj_remove_flag(ui.nav_lifecycle, LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_style_opa(ui.nav_lifecycle, LV_OPA_COVER, 0);
        }
        return;
    }
    if(ui.lifecycle_visual == LifecycleVisual::Hidden ||
       lv_obj_has_flag(ui.nav_lifecycle, LV_OBJ_FLAG_HIDDEN)) {
        if(next == LifecycleVisual::Hidden) return;
        apply_lifecycle_content(next);
        lifecycle_fade_in();
        return;
    }

    lv_anim_t fade;
    lv_anim_init(&fade);
    lv_anim_set_var(&fade, ui.nav_lifecycle);
    lv_anim_set_exec_cb(&fade, set_layer_opacity);
    lv_anim_set_values(&fade,
                       lv_obj_get_style_opa(ui.nav_lifecycle, LV_PART_MAIN),
                       LV_OPA_TRANSP);
    lv_anim_set_duration(&fade, 140);
    lv_anim_set_path_cb(&fade, lv_anim_path_ease_in);
    lv_anim_set_completed_cb(&fade, lifecycle_fade_out_complete);
    lv_anim_start(&fade);
}

LifecycleVisual desired_lifecycle_visual() {
    if(ui.demo_active) {
        return LifecycleVisual::Hidden;
    }
    if(ui.phone_connection == MOTO_UI_PHONE_OFFLINE) {
        return LifecycleVisual::PhoneOffline;
    }
    if(ui.phone_connection == MOTO_UI_PHONE_CONNECTING) {
        return LifecycleVisual::PhoneConnecting;
    }
    if(ui.lifecycle_success_active && !ui.navigation_has_guidance) {
        return LifecycleVisual::Connected;
    }
    if(ui.navigation_has_guidance) {
        return LifecycleVisual::Hidden;
    }
    if(ui.navigation_route_request_in_flight) {
        return LifecycleVisual::Planning;
    }
    return LifecycleVisual::Ready;
}

void refresh_lifecycle() {
    transition_lifecycle(desired_lifecycle_visual());
    for(int i = 1; i < MOTO_UI_PAGE_COUNT; ++i) {
        if(!ui.connection_status[i]) continue;
        const char *text = ui.phone_connection == MOTO_UI_PHONE_OFFLINE ? "PHONE LOST" :
                           ui.phone_connection == MOTO_UI_PHONE_CONNECTING ? "LINK NOT READY" : "";
        lv_label_set_text(ui.connection_status[i], ui.demo_active ? "DEMO" : text);
    }
}

void lifecycle_tick(lv_timer_t *) {
    if(ui.reduce_motion || ui.nav_lifecycle_symbol == nullptr ||
       (ui.lifecycle_visual != LifecycleVisual::PhoneConnecting &&
        ui.lifecycle_visual != LifecycleVisual::Planning)) {
        return;
    }
    const std::uint16_t step =
        ui.lifecycle_visual == LifecycleVisual::PhoneConnecting ? 9U : 5U;
    ui.lifecycle_phase_deg =
        static_cast<std::uint16_t>((ui.lifecycle_phase_deg + step) % 360U);
    lv_obj_invalidate(ui.nav_lifecycle_symbol);
}

void connection_success_timeout(lv_timer_t *timer) {
    lv_timer_pause(timer);
    ui.lifecycle_success_active = false;
    refresh_lifecycle();
}

void set_navigation_guidance_visible(bool visible) {
    lv_obj_t *objects[] = {
        ui.nav_maneuver,
        ui.nav_distance,
        ui.nav_unit,
        ui.nav_road,
        ui.nav_progress,
    };
    for(lv_obj_t *object : objects) {
        if(visible) {
            lv_obj_remove_flag(object, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(object, LV_OBJ_FLAG_HIDDEN);
        }
    }
    if(!visible) lv_obj_add_flag(ui.nav_limit, LV_OBJ_FLAG_HIDDEN);
}

void update_nav_status(const moto_ui_state_t *state) {
    const char *text = "";
    lv_color_t color = kQuiet;
    if(ui.demo_active) {
        lv_label_set_text(ui.nav_status, "DEMO RIDE");
        lv_obj_set_style_text_color(ui.nav_status, kWhite, 0);
        return;
    }
    if(state->mode != MOTO_UI_ARRIVED && state->route_point_count < 2) {
        // Empty navigation states are rendered by the full lifecycle surface,
        // never by a tiny diagnostic caption floating in a black screen.
        lv_label_set_text(ui.nav_status, "");
        return;
    }
    switch(state->mode) {
        case MOTO_UI_ACQUIRING_FIX: text = "ACQUIRING GPS"; color = kAmber; break;
        case MOTO_UI_REROUTING: text = "REROUTING"; color = kAmber; break;
        case MOTO_UI_OFFLINE: text = "ROUTE CACHED"; color = kQuiet; break;
        case MOTO_UI_ARRIVED: text = "ARRIVED"; color = kGreen; break;
        case MOTO_UI_NAVIGATING:
            if(state->online == 0) text = "NETWORK OFFLINE";
            break;
    }
    if(state->mode != MOTO_UI_ARRIVED) {
        if(state->gnss_stale) { text = "LOCATION STALE"; color = kAmber; }
        else if(state->off_route) { text = "OFF ROUTE"; color = kRed; }
        else if(state->gps_accuracy_m == 0) { text = "WAITING FOR GPS"; color = kAmber; }
    }
    lv_label_set_text(ui.nav_status, text);
    lv_obj_set_style_text_color(ui.nav_status, color, 0);
}

void update_navigation(const moto_ui_state_t *state) {
    update_building_geometry(state);
    update_road_geometry(state);
    update_route_geometry(state);
    update_maneuver(state->maneuver);
    update_nav_status(state);

    // Never suggest "go straight for 0 m" while there is no route. Waiting is
    // a connection state, not actionable navigation guidance.
    const bool has_guidance = ui.demo_active ||
                              state->mode == MOTO_UI_ARRIVED ||
                              state->route_point_count >= 2;
    ui.navigation_has_guidance = has_guidance;
    ui.navigation_route_request_in_flight =
        state->route_request_in_flight != 0;
    set_navigation_guidance_visible(has_guidance);
    refresh_lifecycle();
    if(!has_guidance) {
        lv_obj_remove_flag(ui.nav_map, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_text_font(ui.nav_status, &tertiary_font, 0);
        lv_obj_set_width(ui.nav_status, px(180));
        lv_obj_align(ui.nav_status, LV_ALIGN_TOP_MID, 0, px(320));
        return;
    }

    char value[16];
    const char *unit = "m";
    if(state->distance_to_maneuver_m >= 1000) {
        std::snprintf(value, sizeof(value), "%.1f",
                      state->distance_to_maneuver_m / 1000.0);
        unit = "km";
    } else {
        std::snprintf(value, sizeof(value), "%u",
                      static_cast<unsigned>(state->distance_to_maneuver_m));
    }
    const bool arrived = state->mode == MOTO_UI_ARRIVED;
    const bool actionable = !arrived && state->has_next_maneuver &&
                            !state->off_route && !state->gnss_stale &&
                            state->gps_accuracy_m > 0 && state->mode != MOTO_UI_REROUTING;
    if(!actionable) { std::snprintf(value, sizeof(value), "--"); unit = ""; }
    if(actionable || arrived) lv_obj_remove_flag(ui.nav_maneuver, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(ui.nav_maneuver, LV_OBJ_FLAG_HIDDEN);
    if(arrived) {
        update_maneuver(MOTO_MANEUVER_ARRIVE);
        lv_obj_add_flag(ui.nav_distance, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(ui.nav_unit, LV_OBJ_FLAG_HIDDEN);
    }
    if(arrived) {
        lv_obj_add_flag(ui.nav_map, LV_OBJ_FLAG_HIDDEN);
        lv_obj_align(ui.nav_maneuver, LV_ALIGN_TOP_MID, 0, px(95));
        lv_obj_add_flag(ui.nav_progress, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_text_font(ui.nav_status, &navigation_status_font, 0);
        lv_obj_align(ui.nav_status, LV_ALIGN_TOP_MID, 0, px(205));
    } else {
        lv_obj_remove_flag(ui.nav_map, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_pos(ui.nav_maneuver, px(75), px(43));
        lv_obj_set_style_text_font(ui.nav_status, &tertiary_font, 0);
        lv_obj_align(ui.nav_status, LV_ALIGN_TOP_MID, 0, px(320));
    }
    const bool warning = !arrived && (state->off_route || state->gnss_stale ||
                         state->gps_accuracy_m == 0 || state->mode == MOTO_UI_REROUTING);
    if(warning) {
        lv_obj_add_flag(ui.nav_distance, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(ui.nav_unit, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_text_font(ui.nav_status, &navigation_status_font, 0);
        lv_obj_set_width(ui.nav_status, px(250));
        lv_obj_align(ui.nav_status, LV_ALIGN_TOP_MID, 0, px(55));
    } else {
        lv_obj_set_width(ui.nav_status, px(180));
    }
    lv_obj_align(ui.nav_road, LV_ALIGN_TOP_MID, 0, px(arrived ? 250 : 280));
    lv_label_set_text(ui.nav_road, state->next_road_name ? state->next_road_name : "");
    lv_obj_set_style_line_color(ui.nav_route,
        state->off_route ? kRed : (state->gnss_stale || state->mode == MOTO_UI_REROUTING) ? kAmber : kIce, 0);
    lv_label_set_text(ui.nav_distance, value);
    lv_label_set_text(ui.nav_unit, unit);
    // This number is never the total trip distance. Its physical attachment to
    // the maneuver glyph makes that meaning clear without an explanatory label.
    lv_obj_align(ui.nav_distance, LV_ALIGN_TOP_LEFT, px(150), px(48));
    lv_obj_align(ui.nav_unit, LV_ALIGN_TOP_MID, px(25), px(94));

    lv_arc_set_value(ui.nav_progress,
                     std::min<int>(100, state->route_progress_percent));
    lv_obj_set_style_arc_color(ui.nav_progress, traffic_color(state->traffic),
                               LV_PART_INDICATOR);

    if(state->speed_limit_kph > 0 && !arrived) {
        char limit[8];
        std::snprintf(limit, sizeof(limit), "%u",
                      static_cast<unsigned>(state->speed_limit_kph));
        lv_label_set_text(ui.nav_limit_value, limit);
        lv_obj_remove_flag(ui.nav_limit, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(ui.nav_limit, LV_OBJ_FLAG_HIDDEN);
    }
}

void update_speedometer(const moto_ui_state_t *state) {
    const bool has_usable_fix = state->gps_accuracy_m > 0 && !state->gnss_stale && state->speed_available;
    if(!has_usable_fix) {
        lv_label_set_text(ui.speed_value, "--");
        lv_obj_align(ui.speed_value, LV_ALIGN_CENTER, 0,
                     px(kSpeedUnknownOpticalYOffset));
        lv_arc_set_value(ui.speed_arc, 0);
        for(int i = 0; i < kSpeedTickCount; ++i) {
            lv_obj_set_style_line_color(ui.speed_ticks[i], kGraphite, 0);
        }
        return;
    }
    char value[8];
    std::snprintf(value, sizeof(value), "%u",
                  static_cast<unsigned>(state->speed_kph));
    lv_label_set_text(ui.speed_value, value);
    lv_obj_align(ui.speed_value, LV_ALIGN_CENTER, 0,
                 px(kSpeedHeroOpticalYOffset));
    lv_arc_set_value(ui.speed_arc, std::min<int>(160, state->speed_kph));
    for(int i = 0; i < kSpeedTickCount; ++i) {
        const bool active = state->speed_kph >= static_cast<unsigned>(i * 160 / (kSpeedTickCount - 1));
        lv_obj_set_style_line_color(ui.speed_ticks[i], active ? kRoadGray : kGraphite, 0);
    }
}

void update_compass(const moto_ui_state_t *state) {
    const bool has_usable_fix = state->gps_accuracy_m > 0 && !state->gnss_stale;
    const bool has_heading = has_usable_fix && state->heading_available;
    const unsigned heading_deg = has_heading ? state->heading_deg : 0;
    if(has_heading) {
        char heading[12];
        std::snprintf(heading, sizeof(heading), "%03u°", heading_deg);
        lv_label_set_text(ui.compass_heading, heading);
        lv_label_set_text(ui.compass_cardinal, cardinal_name(heading_deg));
    } else {
        lv_label_set_text(ui.compass_heading, "--");
        lv_label_set_text(ui.compass_cardinal, "WAITING");
        lv_label_set_text(ui.compass_speed, "-- km/h");
    }

    if(has_usable_fix && state->speed_available) {
        char speed[20];
        std::snprintf(speed, sizeof(speed), "%u km/h", static_cast<unsigned>(state->speed_kph));
        lv_label_set_text(ui.compass_speed, speed);
    } else {
        lv_label_set_text(ui.compass_speed, "-- km/h");
    }
    const double heading_rad = heading_deg * kPi / 180.0;
    for(int i = 0; i < kCompassTickCount; ++i) {
        if(has_heading) lv_obj_remove_flag(ui.compass_ticks[i], LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(ui.compass_ticks[i], LV_OBJ_FLAG_HIDDEN);
        const double angle = i * 15.0 * kPi / 180.0 - heading_rad;
        const double inner = px(i % 3 == 0 ? 138.0 : 145.0);
        ui.compass_tick_points[i][0] = {
            static_cast<lv_value_precise_t>(px(180.0) + std::sin(angle) * px(154.0)),
            static_cast<lv_value_precise_t>(px(180.0) - std::cos(angle) * px(154.0)),
        };
        ui.compass_tick_points[i][1] = {
            static_cast<lv_value_precise_t>(px(180.0) + std::sin(angle) * inner),
            static_cast<lv_value_precise_t>(px(180.0) - std::cos(angle) * inner),
        };
        lv_line_set_points_mutable(ui.compass_ticks[i],
                                   ui.compass_tick_points[i], 2);
        lv_obj_set_style_line_color(ui.compass_ticks[i], i == 0 ? kAmber : kQuiet, 0);
    }

    static const double bearings[4] = {0.0, 90.0, 180.0, 270.0};
    static const char *letters[4] = {"N", "E", "S", "W"};
    for(int i = 0; i < 4; ++i) {
        if(has_heading) lv_obj_remove_flag(ui.compass_letters[i], LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(ui.compass_letters[i], LV_OBJ_FLAG_HIDDEN);
        const double angle = bearings[i] * kPi / 180.0 - heading_rad;
        const int x = static_cast<int>(px(180.0) + std::sin(angle) * px(112.0));
        const int y = static_cast<int>(px(180.0) - std::cos(angle) * px(112.0));
        lv_label_set_text(ui.compass_letters[i], letters[i]);
        lv_obj_set_pos(ui.compass_letters[i], x - px(14), y - px(10));
        lv_obj_set_style_text_color(ui.compass_letters[i], i == 0 ? kAmber : kRoadGray, 0);
    }
}

void update_music_view() {
    lv_label_set_text(ui.music_source, ui.music.connected ? ui.music_source_text : "MEDIA UNAVAILABLE");
    lv_label_set_text(ui.music_title, ui.music.connected ? ui.music_title_text : "");
    lv_label_set_text(ui.music_artist, ui.music.connected ? ui.music_artist_text : "");
    lv_label_set_text(ui.music_button_labels[1], ui.music.playing ? "II" : ">");
    lv_label_set_text(ui.music_button_labels[3], ui.music.liked ? "SENT" : "LIKE");
    if(ui.music.like_available) {
        lv_obj_remove_flag(ui.music_buttons[3], LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(ui.music_buttons[3], LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_set_style_text_color(ui.music_symbol, ui.music.playing ? kIce : kSoft, 0);
    for(int i = 0; i < 3; ++i) {
        if(ui.music.connected) lv_obj_remove_state(ui.music_buttons[i], LV_STATE_DISABLED);
        else lv_obj_add_state(ui.music_buttons[i], LV_STATE_DISABLED);
    }
}

void music_button_event(lv_event_t *event) {
    const auto command = static_cast<moto_music_command_t>(
        reinterpret_cast<std::intptr_t>(lv_event_get_user_data(event)));
    // The phone may reject or delay a command. Wait for the next real
    // MediaState instead of showing an optimistic playback or like state.
    if(ui.music.connected && ui.music_callback != nullptr) ui.music_callback(command, ui.music_callback_context);
}

void create_page_dots() {
    for(int i = 0; i < MOTO_UI_PAGE_COUNT; ++i) {
        ui.page_dots[i] = lv_obj_create(ui.screen);
        lv_obj_remove_style_all(ui.page_dots[i]);
        lv_obj_set_size(ui.page_dots[i], px(5), px(5));
        lv_obj_set_y(ui.page_dots[i], px(337));
        lv_obj_set_style_bg_opa(ui.page_dots[i], LV_OPA_COVER, 0);
        lv_obj_set_style_radius(ui.page_dots[i], px(3), 0);
        lv_obj_clear_flag(ui.page_dots[i], LV_OBJ_FLAG_CLICKABLE);
    }
    ui.page_dots_timer = lv_timer_create(hide_page_dots,
                                         kPageDotsVisibleMs, nullptr);
    update_page_dots();
    reveal_page_dots();
}

void create_navigation_page() {
    lv_obj_t *page = ui.pages[MOTO_UI_PAGE_NAVIGATION];
    ui.nav_map = make_layer(page);
    // The map is the topmost hit target across most of the navigation page.
    // Forward swipe gestures to the page/screen. Local demo activation is not
    // bound to a long press: a glove, mount or palm must never replace active
    // phone guidance with the built-in fixture while riding.
    lv_obj_add_flag(ui.nav_map, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_flag(ui.nav_map, LV_OBJ_FLAG_GESTURE_BUBBLE);
    lv_obj_set_height(ui.nav_map, px(294));

    // Real building footprints are quiet closed outlines beneath both roads
    // and the selected route. No inferred rectangles or decorative fill is
    // generated on-device.
    for(std::uint8_t i = 0;
        i < MOTO_UI_BUILDING_FOOTPRINT_CAPACITY; ++i) {
        ui.nav_buildings[i] = create_map_polyline(ui.nav_map,
                                                  ui.nav_building_lines[i]);
        lv_obj_set_size(ui.nav_buildings[i], MOTO_UI_CANVAS_WIDTH, px(294));
        lv_obj_set_style_line_width(ui.nav_buildings[i], px(1), 0);
        lv_obj_set_style_line_color(ui.nav_buildings[i], kBuildingGray, 0);
        lv_obj_set_style_line_opa(ui.nav_buildings[i], LV_OPA_COVER, 0);
        lv_obj_set_style_line_rounded(ui.nav_buildings[i], false, 0);
        lv_obj_add_flag(ui.nav_buildings[i], LV_OBJ_FLAG_HIDDEN);
    }

    // Quiet, real street context sits behind the selected route. Each road is
    // its own LVGL line so disconnected streets are never joined by a fake
    // diagonal. The bundled Jinan fixture uses all eight bounded slots; a
    // future online provider must simplify its response to the same limit.
    for(std::uint8_t i = 0; i < MOTO_UI_ROAD_POLYLINE_CAPACITY; ++i) {
        ui.nav_roads[i] = create_map_polyline(ui.nav_map, ui.nav_road_lines[i]);
        lv_obj_set_size(ui.nav_roads[i], MOTO_UI_CANVAS_WIDTH, px(294));
        lv_obj_set_style_line_width(ui.nav_roads[i], px(3), 0);
        lv_obj_set_style_line_color(ui.nav_roads[i], kRoadGray, 0);
        lv_obj_set_style_line_opa(ui.nav_roads[i], LV_OPA_COVER, 0);
        lv_obj_set_style_line_rounded(ui.nav_roads[i], true, 0);
        lv_obj_add_flag(ui.nav_roads[i], LV_OBJ_FLAG_HIDDEN);
    }

    ui.nav_route_shadow = create_map_polyline(ui.nav_map, ui.nav_route_shadow_line);
    lv_obj_set_size(ui.nav_route_shadow, MOTO_UI_CANVAS_WIDTH, px(294));
    lv_obj_set_style_line_width(ui.nav_route_shadow, px(13), 0);
    lv_obj_set_style_line_color(ui.nav_route_shadow, kGraphite, 0);
    lv_obj_set_style_line_rounded(ui.nav_route_shadow, true, 0);
    ui.nav_route = create_map_polyline(ui.nav_map, ui.nav_route_line);
    lv_obj_set_size(ui.nav_route, MOTO_UI_CANVAS_WIDTH, px(294));
    lv_obj_set_style_line_width(ui.nav_route, px(3), 0);
    lv_obj_set_style_line_color(ui.nav_route, kIce, 0);
    lv_obj_set_style_line_rounded(ui.nav_route, true, 0);
    ui.nav_route_motion_timer = lv_timer_create(route_motion_tick,
                                                 kRouteMotionFrameMs,
                                                 nullptr);

    ui.nav_marker = lv_obj_create(ui.nav_map);
    lv_obj_remove_style_all(ui.nav_marker);
    lv_obj_set_size(ui.nav_marker, px(35), px(37));
    lv_obj_set_pos(ui.nav_marker, px(163), px(177));
    lv_obj_clear_flag(ui.nav_marker, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(ui.nav_marker, draw_vehicle_marker,
                        LV_EVENT_DRAW_MAIN_END, nullptr);

    lv_obj_t *hero = make_layer(page);
    lv_obj_set_height(hero, px(120));
    lv_obj_set_style_bg_color(hero, kBlack, 0);
    lv_obj_set_style_bg_opa(hero, LV_OPA_COVER, 0);
    ui.nav_road = make_label(page, &navigation_road_font, kWhite, "");
    // Noto Sans SC 28 needs its full 29 px line box; leave one pixel of
    // clearance so the largest glyph bounding boxes stay inside the label.
    lv_obj_set_size(ui.nav_road, px(230), 30);
    lv_obj_set_style_pad_all(ui.nav_road, 0, 0);
    lv_label_set_long_mode(ui.nav_road, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_align(ui.nav_road, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui.nav_road, LV_ALIGN_TOP_MID, 0, px(280));

    ui.nav_status = make_label(page, &tertiary_font, kAmber, "");
    // The status can switch to Inter 32 with Noto Sans SC 28 fallback.
    lv_obj_set_size(ui.nav_status, px(180), 34);
    lv_obj_set_style_pad_all(ui.nav_status, 0, 0);
    lv_obj_set_style_text_align(ui.nav_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui.nav_status, LV_ALIGN_TOP_MID, 0, px(320));

    // The next action and fixed-width distance sit above the real map.
    // This opaque hero strip keeps route geometry from crossing the labels.
    ui.nav_maneuver = lv_obj_create(page);
    lv_obj_remove_style_all(ui.nav_maneuver);
    lv_obj_set_size(ui.nav_maneuver, px(70), px(65));
    lv_obj_set_pos(ui.nav_maneuver, px(75), px(43));
    lv_obj_clear_flag(ui.nav_maneuver, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(ui.nav_maneuver, draw_maneuver_icon,
                        LV_EVENT_DRAW_MAIN_END, nullptr);

    ui.nav_distance = make_label(page, &numeric_font, kWhite, "--");
    lv_obj_set_width(ui.nav_distance, px(150));
    lv_obj_set_style_text_align(ui.nav_distance, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(ui.nav_distance, LV_LABEL_LONG_DOT);
    ui.nav_unit = make_label(page, &secondary_font, kQuiet, "m");

    ui.nav_limit = lv_obj_create(page);
    lv_obj_set_size(ui.nav_limit, px(44), px(44));
    // Keep the optional demo/SDK-provided value inside the circular safe area.
    // Real AMap Web-Service snapshots use zero and remain hidden because that
    // API does not return a road speed limit.
    lv_obj_set_pos(ui.nav_limit, px(280), px(244));
    lv_obj_set_style_radius(ui.nav_limit, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(ui.nav_limit, kWhite, 0);
    lv_obj_set_style_bg_opa(ui.nav_limit, LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(ui.nav_limit, kRed, 0);
    lv_obj_set_style_border_width(ui.nav_limit, px(3), 0);
    lv_obj_set_style_pad_all(ui.nav_limit, 0, 0);
    lv_obj_clear_flag(ui.nav_limit, LV_OBJ_FLAG_CLICKABLE);
    ui.nav_limit_value = make_label(ui.nav_limit, &primary_font, kBlack, "--");
    lv_obj_center(ui.nav_limit_value);

    ui.nav_progress = lv_arc_create(page);
    lv_obj_set_size(ui.nav_progress, px(316), px(316));
    lv_obj_center(ui.nav_progress);
    lv_arc_set_rotation(ui.nav_progress, 48);
    lv_arc_set_bg_angles(ui.nav_progress, 0, 84);
    lv_arc_set_range(ui.nav_progress, 0, 100);
    lv_arc_set_value(ui.nav_progress, 0);
    lv_obj_remove_style(ui.nav_progress, nullptr, LV_PART_KNOB);
    lv_obj_clear_flag(ui.nav_progress, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(ui.nav_progress, px(3), LV_PART_MAIN);
    lv_obj_set_style_arc_color(ui.nav_progress, kGraphite, LV_PART_MAIN);
    lv_obj_set_style_arc_width(ui.nav_progress, px(4), LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(ui.nav_progress, kIce, LV_PART_INDICATOR);
    lv_obj_move_to_index(ui.nav_progress, 0);

    // Connection lifecycle overlay. The composition follows the same circular
    // safe area as the navigation instrument and intentionally uses one hero
    // symbol instead of a dashboard of technical status labels.
    ui.nav_lifecycle = make_layer(page);
    lv_obj_set_style_bg_color(ui.nav_lifecycle, kBlack, 0);
    lv_obj_set_style_bg_opa(ui.nav_lifecycle, LV_OPA_COVER, 0);
    lv_obj_add_flag(ui.nav_lifecycle, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_flag(ui.nav_lifecycle, LV_OBJ_FLAG_GESTURE_BUBBLE);

    ui.nav_lifecycle_kicker = make_label(
        ui.nav_lifecycle, &tertiary_font, kQuiet,
        "WAYMATE");
    lv_obj_set_style_text_letter_space(ui.nav_lifecycle_kicker, px(2), 0);
    lv_obj_align(ui.nav_lifecycle_kicker, LV_ALIGN_TOP_MID, 0, px(39));

    ui.nav_lifecycle_symbol = lv_obj_create(ui.nav_lifecycle);
    lv_obj_remove_style_all(ui.nav_lifecycle_symbol);
    lv_obj_set_size(ui.nav_lifecycle_symbol, px(150), px(150));
    lv_obj_align(ui.nav_lifecycle_symbol, LV_ALIGN_TOP_MID, 0, px(61));
    lv_obj_clear_flag(ui.nav_lifecycle_symbol, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(ui.nav_lifecycle_symbol, draw_connection_symbol,
                        LV_EVENT_DRAW_MAIN_END, nullptr);

    ui.nav_lifecycle_title = make_label(
        ui.nav_lifecycle, &navigation_status_font, kWhite, "PHONE LOST");
    lv_obj_set_width(ui.nav_lifecycle_title, px(280));
    lv_obj_set_style_text_align(ui.nav_lifecycle_title,
                                LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_letter_space(ui.nav_lifecycle_title, px(2), 0);
    lv_obj_align(ui.nav_lifecycle_title, LV_ALIGN_TOP_MID, 0, px(231));

    ui.nav_lifecycle_subtitle = make_label(
        ui.nav_lifecycle, &nav_text_font, kSoft, "请打开手机应用");
    lv_obj_set_width(ui.nav_lifecycle_subtitle, px(280));
    lv_obj_set_style_text_align(ui.nav_lifecycle_subtitle,
                                LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui.nav_lifecycle_subtitle, LV_ALIGN_TOP_MID, 0, px(278));

    ui.nav_lifecycle_timer = lv_timer_create(lifecycle_tick, 40, nullptr);
    ui.nav_success_timer = lv_timer_create(connection_success_timeout,
                                            kConnectionSuccessHoldMs,
                                            nullptr);
    lv_timer_pause(ui.nav_success_timer);
    apply_lifecycle_content(LifecycleVisual::PhoneOffline);
    ui.lifecycle_target = LifecycleVisual::PhoneOffline;
}

void draw_backtrack_map(lv_event_t *event) {
    if(lv_event_get_code(event) != LV_EVENT_DRAW_MAIN) return;
    const auto& s = ui.backtrack;
    lv_layer_t *layer = lv_event_get_layer(event);
    lv_area_t area;
    lv_obj_get_coords(ui.backtrack_map, &area);
    lv_draw_line_dsc_t line;
    lv_draw_line_dsc_init(&line);
    line.width = 3; line.round_start = 1; line.round_end = 1;
    const auto pixel = [&](moto_ui_point_t p) -> lv_point_precise_t { return {static_cast<lv_value_precise_t>(area.x1 + p.x), static_cast<lv_value_precise_t>(area.y1 + p.y)}; };
    const auto draw = [&](moto_ui_point_t a, moto_ui_point_t b, lv_color_t color) {
        line.p1 = pixel(a); line.p2 = pixel(b); line.color = color;
        draw_map_line(layer, line);
    };
    for(uint16_t i = 1; i < s.point_count; ++i) {
        const auto& a = s.points[i-1]; const auto& b = s.points[i];
        if(a.segment_index != b.segment_index) continue;
        if(b.progress_m <= s.progress_m) draw(a.pixel, b.pixel, kGraphite);
        else if(a.progress_m >= s.progress_m || b.progress_m == a.progress_m) draw(a.pixel, b.pixel, kIce);
        else {
            const double f = static_cast<double>(s.progress_m - a.progress_m) / (b.progress_m - a.progress_m);
            const moto_ui_point_t mid{static_cast<int16_t>(std::lround(a.pixel.x + (b.pixel.x-a.pixel.x)*f)),
                                      static_cast<int16_t>(std::lround(a.pixel.y + (b.pixel.y-a.pixel.y)*f))};
            draw(a.pixel, mid, kGraphite); draw(mid, b.pixel, kIce);
        }
    }
    // Singleton breadcrumb runs remain visible without inventing a connecting edge.
    for(uint16_t i = 0; i < s.point_count; ++i) {
        const bool before = i && s.points[i-1].segment_index == s.points[i].segment_index;
        const bool after = i+1 < s.point_count && s.points[i+1].segment_index == s.points[i].segment_index;
        if(!before && !after) draw(s.points[i].pixel, s.points[i].pixel, kIce);
    }
    if(s.location_valid && s.marker.x >= 0 && s.marker.x < 284 && s.marker.y >= 0 && s.marker.y < 106) {
        auto a = s.marker, b = s.marker; a.x -= 3; b.x += 3;
        line.width = 7; draw(a, b, kWhite);
    }
}

void backtrack_distance(char *output, std::size_t size, uint32_t metres) {
    if(metres == UINT32_MAX) std::snprintf(output, size, "--");
    else if(metres < 1000) std::snprintf(output, size, "%lu m", static_cast<unsigned long>(metres));
    else if(metres < 100000) std::snprintf(output, size, "%.1f km", metres / 1000.0);
    else std::snprintf(output, size, "%.0f km", metres / 1000.0);
}

void update_backtrack() {
    const auto& s = ui.backtrack;
    const lv_color_t color = s.off_track ? kAmber : kIce;
    lv_label_set_text(ui.backtrack_title, s.arrived ? "START REACHED" : s.off_track ? "OFF TRACK" : "BACKTRACK");
    lv_obj_set_style_text_color(ui.backtrack_title, color, 0);
    const char *hint = s.arrived ? "RIDE STILL ACTIVE" : s.paused ? "RIDE PAUSED" :
        !s.location_valid ? "WAITING FOR GPS" : s.off_track ? "RETURN TO TRAIL" : s.trail_gap ? "TRAIL GAP" : "FOLLOW TRAIL";
    lv_label_set_text(ui.backtrack_hint, hint);
    lv_obj_set_style_text_color(ui.backtrack_hint, color, 0);
    char text[40];
    backtrack_distance(text, sizeof(text), s.location_valid && !s.arrived ? s.target_distance_m : UINT32_MAX);
    lv_label_set_text(ui.backtrack_distance, s.arrived ? "START" : text);
    backtrack_distance(text, sizeof(text), s.remaining_distance_m);
    lv_label_set_text_fmt(ui.backtrack_remaining, "%s remaining", text);
    lv_label_set_text(ui.backtrack_basis, s.geometry_unavailable ? "TRAIL TOO LARGE" :
        !s.location_valid ? "DIRECTION UNAVAILABLE" : s.relative_direction ? "RELATIVE / MAP NORTH UP" : "NORTH UP");
    const bool arrow = s.location_valid && !s.arrived && s.direction_cdeg != UINT16_MAX;
    if(arrow) {
        lv_obj_remove_flag(ui.backtrack_arrow, LV_OBJ_FLAG_HIDDEN);
        const double angle = s.direction_cdeg / 100.0 * kPi / 180;
        const int shape[5][2] = {{-16,0},{0,-19},{16,0},{0,-19},{0,21}};
        for(int i = 0; i < 5; ++i) {
            ui.backtrack_arrow_points[i] = {
                static_cast<lv_value_precise_t>(px(25.0 + shape[i][0]*std::cos(angle)-shape[i][1]*std::sin(angle))),
                static_cast<lv_value_precise_t>(px(25.0 + shape[i][0]*std::sin(angle)+shape[i][1]*std::cos(angle)))};
        }
        lv_line_set_points(ui.backtrack_arrow, ui.backtrack_arrow_points, 5);
        lv_obj_set_style_line_color(ui.backtrack_arrow, color, 0);
    } else lv_obj_add_flag(ui.backtrack_arrow, LV_OBJ_FLAG_HIDDEN);
    lv_obj_invalidate(ui.backtrack_map);
}

void create_backtrack_page() {
    lv_obj_t *page = ui.pages[MOTO_UI_PAGE_BACKTRACK];
    const auto label = [&](const lv_font_t *font, lv_color_t color, int y, const char *text) {
        lv_obj_t *object = make_label(page, font, color, text);
        lv_obj_set_width(object, px(250));
        lv_obj_set_style_text_align(object, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(object, LV_ALIGN_TOP_MID, 0, px(y));
        return object;
    };
    ui.backtrack_title = label(&primary_font, kIce, 35, "BACKTRACK");
    ui.backtrack_arrow = lv_line_create(page);
    lv_obj_set_size(ui.backtrack_arrow, px(50), px(50));
    lv_obj_align(ui.backtrack_arrow, LV_ALIGN_TOP_MID, 0, px(76));
    lv_obj_set_style_line_width(ui.backtrack_arrow, px(4), 0);
    lv_obj_set_style_line_rounded(ui.backtrack_arrow, true, 0);
    ui.backtrack_distance = label(&primary_font, kWhite, 128, "--");
    ui.backtrack_hint = label(&tertiary_font, kIce, 160, "WAITING FOR GPS");
    ui.backtrack_basis = label(&tertiary_font, kQuiet, 185, "NORTH UP");
    ui.backtrack_map = lv_obj_create(page);
    lv_obj_remove_style_all(ui.backtrack_map);
    lv_obj_set_size(ui.backtrack_map, 284, 106);
    lv_obj_align(ui.backtrack_map, LV_ALIGN_TOP_MID, 0, px(209));
    lv_obj_remove_flag(ui.backtrack_map, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(ui.backtrack_map, draw_backtrack_map, LV_EVENT_DRAW_MAIN, nullptr);
    ui.backtrack_remaining = label(&secondary_font, kWhite, 297, "-- remaining");
}

void create_speed_page() {
    lv_obj_t *page = ui.pages[MOTO_UI_PAGE_SPEED];
    ui.speed_arc = lv_arc_create(page);
    lv_obj_set_size(ui.speed_arc, px(312), px(312));
    lv_obj_center(ui.speed_arc);
    lv_arc_set_rotation(ui.speed_arc, 138);
    lv_arc_set_bg_angles(ui.speed_arc, 0, 264);
    lv_arc_set_range(ui.speed_arc, 0, 160);
    lv_obj_remove_style(ui.speed_arc, nullptr, LV_PART_KNOB);
    lv_obj_clear_flag(ui.speed_arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(ui.speed_arc, px(3), LV_PART_MAIN);
    lv_obj_set_style_arc_color(ui.speed_arc, kGraphite, LV_PART_MAIN);
    lv_obj_set_style_arc_width(ui.speed_arc, px(3), LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(ui.speed_arc, kIce, LV_PART_INDICATOR);

    for(int i = 0; i < kSpeedTickCount; ++i) {
        const double angle = (138.0 + i * (264.0 / (kSpeedTickCount - 1))) * kPi / 180.0;
        const double inner = px(i % 2 == 0 ? 132.0 : 136.0);
        ui.speed_tick_points[i][0] = {
            static_cast<lv_value_precise_t>(px(180.0) + std::cos(angle) * px(142.0)),
            static_cast<lv_value_precise_t>(px(180.0) + std::sin(angle) * px(142.0)),
        };
        ui.speed_tick_points[i][1] = {
            static_cast<lv_value_precise_t>(px(180.0) + std::cos(angle) * inner),
            static_cast<lv_value_precise_t>(px(180.0) + std::sin(angle) * inner),
        };
        ui.speed_ticks[i] = lv_line_create(page);
        lv_obj_set_size(ui.speed_ticks[i], MOTO_UI_CANVAS_WIDTH,
                        MOTO_UI_CANVAS_HEIGHT);
        lv_line_set_points_mutable(ui.speed_ticks[i], ui.speed_tick_points[i], 2);
        lv_obj_set_style_line_width(ui.speed_ticks[i], px(i % 2 == 0 ? 2 : 1), 0);
        lv_obj_set_style_line_color(ui.speed_ticks[i], kGraphite, 0);
    }
    ui.speed_value = make_label(page, &speed_font, kWhite, "--");
    lv_obj_set_width(ui.speed_value, px(250));
    lv_obj_set_style_text_align(ui.speed_value, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui.speed_value, LV_ALIGN_CENTER, 0,
                 px(kSpeedHeroOpticalYOffset));
    lv_obj_t *unit = make_label(page, &secondary_font, kSoft, "km/h");
    lv_obj_set_style_text_letter_space(unit, px(1), 0);
    lv_obj_align(unit, LV_ALIGN_CENTER, 0, px(45));
}

void create_compass_page() {
    lv_obj_t *page = ui.pages[MOTO_UI_PAGE_COMPASS];
    for(int i = 0; i < kCompassTickCount; ++i) {
        ui.compass_ticks[i] = lv_line_create(page);
        lv_obj_set_size(ui.compass_ticks[i], MOTO_UI_CANVAS_WIDTH,
                        MOTO_UI_CANVAS_HEIGHT);
        lv_obj_set_style_line_width(ui.compass_ticks[i], px(i % 3 == 0 ? 2 : 1), 0);
        lv_obj_set_style_line_color(ui.compass_ticks[i], kGraphite, 0);
    }
    for(int i = 0; i < 4; ++i) {
        ui.compass_letters[i] = make_label(page, &tertiary_font, kGraphite, "N");
        lv_obj_set_size(ui.compass_letters[i], px(28), px(22));
        lv_obj_set_style_text_align(ui.compass_letters[i], LV_TEXT_ALIGN_CENTER, 0);
    }
    ui.compass_heading = make_label(page, &numeric_font, kWhite, "--");
    lv_obj_set_width(ui.compass_heading, px(200));
    lv_obj_set_style_text_align(ui.compass_heading, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui.compass_heading, LV_ALIGN_CENTER, 0,
                 px(-37 + kCompassStackOpticalYOffset));
    ui.compass_cardinal = make_label(page, &compass_cardinal_font, kIce, "WAITING");
    lv_obj_set_width(ui.compass_cardinal, px(230));
    lv_obj_set_style_text_align(ui.compass_cardinal, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ui.compass_cardinal, LV_ALIGN_CENTER, 0,
                 px(10 + kCompassStackOpticalYOffset));
    lv_obj_t *basis = make_label(page, &tertiary_font, kQuiet, "DERIVED HEADING");
    lv_obj_align(basis, LV_ALIGN_CENTER, 0,
                 px(90 + kCompassStackOpticalYOffset));
    ui.compass_speed = make_label(page, &secondary_font, kSoft, "-- km/h");
    lv_obj_set_style_text_letter_space(ui.compass_speed, px(1), 0);
    lv_obj_align(ui.compass_speed, LV_ALIGN_CENTER, 0,
                 px(57 + kCompassStackOpticalYOffset));
}

void create_music_page() {
    lv_obj_t *page = ui.pages[MOTO_UI_PAGE_MUSIC];
    ui.music_source = make_label(page, &tertiary_font, kSoft, "WAITING FOR MEDIA");
    lv_obj_set_size(ui.music_source, px(210), 22);
    lv_obj_set_style_text_align(ui.music_source, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(ui.music_source, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_letter_space(ui.music_source, px(1), 0);
    lv_obj_align(ui.music_source, LV_ALIGN_TOP_MID, 0, px(37));

    ui.music_symbol = make_label(page, &lv_font_montserrat_48, kIce, LV_SYMBOL_AUDIO);
    lv_obj_align(ui.music_symbol, LV_ALIGN_TOP_MID, 0, px(90));

    ui.music_title = make_label(page, &media_title_font, kWhite, "");
    lv_obj_set_size(ui.music_title, px(280), 32);
    lv_obj_set_style_text_align(ui.music_title, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(ui.music_title, LV_LABEL_LONG_DOT);
    lv_obj_align(ui.music_title, LV_ALIGN_TOP_MID, 0, px(144));
    ui.music_artist = make_label(page, &nav_text_font, kSoft, "");
    lv_obj_set_size(ui.music_artist, px(260), 24);
    lv_obj_set_style_text_align(ui.music_artist, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(ui.music_artist, LV_LABEL_LONG_DOT);
    lv_obj_align(ui.music_artist, LV_ALIGN_TOP_MID, 0, px(198));

    static const char *labels[4] = {"<<", ">", ">>", "LIKE"};
    static const int positions[4][3] = {
        {78, 254, 54}, {153, 247, 62}, {228, 254, 54}, {147, 312, 66},
    };
    for(int i = 0; i < 4; ++i) {
        ui.music_buttons[i] = lv_button_create(page);
        lv_obj_set_size(ui.music_buttons[i], px(positions[i][2]),
                        px(i == 3 ? 28 : positions[i][2]));
        lv_obj_set_pos(ui.music_buttons[i], px(positions[i][0]),
                       px(positions[i][1]));
        lv_obj_set_style_radius(ui.music_buttons[i], LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(ui.music_buttons[i], i == 1 ? kWhite : kGraphite, 0);
        lv_obj_set_style_bg_opa(ui.music_buttons[i], LV_OPA_COVER, 0);
        lv_obj_set_style_shadow_width(ui.music_buttons[i], 0, 0);
        lv_obj_set_style_border_width(ui.music_buttons[i], 0, 0);
        // Pin the pressed appearance to the idle appearance. The LVGL default
        // theme darkens and grows pressed buttons (recolor 35% + 3 px grow);
        // on the ESP32 PPA render path that pre-composited recolor painted as
        // a hard-edged yellow-green block over the round button. Identical
        // pressed styles remove the visual state difference by construction.
        lv_obj_set_style_bg_color(ui.music_buttons[i], i == 1 ? kWhite : kGraphite,
                                  LV_STATE_PRESSED);
        lv_obj_set_style_bg_opa(ui.music_buttons[i], LV_OPA_COVER,
                                LV_STATE_PRESSED);
        lv_obj_set_style_radius(ui.music_buttons[i], LV_RADIUS_CIRCLE,
                                LV_STATE_PRESSED);
        lv_obj_set_style_shadow_width(ui.music_buttons[i], 0, LV_STATE_PRESSED);
        lv_obj_set_style_border_width(ui.music_buttons[i], 0, LV_STATE_PRESSED);
        lv_obj_set_style_recolor_opa(ui.music_buttons[i], LV_OPA_TRANSP,
                                     LV_STATE_PRESSED);
        lv_obj_set_style_transform_width(ui.music_buttons[i], 0,
                                         LV_STATE_PRESSED);
        lv_obj_set_style_transform_height(ui.music_buttons[i], 0,
                                          LV_STATE_PRESSED);
        lv_obj_add_flag(ui.music_buttons[i], LV_OBJ_FLAG_GESTURE_BUBBLE);
        lv_obj_add_event_cb(
            ui.music_buttons[i], music_button_event, LV_EVENT_CLICKED,
            reinterpret_cast<void *>(static_cast<std::intptr_t>(i)));
        ui.music_button_labels[i] = make_label(
            ui.music_buttons[i], i == 3 ? &tertiary_font : &secondary_font,
            i == 1 ? kBlack : kWhite, labels[i]);
        lv_obj_center(ui.music_button_labels[i]);
    }
}

void set_boot_content_opacity(void *object, int32_t opacity) {
    lv_obj_set_style_opa(static_cast<lv_obj_t *>(object), opacity, 0);
}

}  // namespace

extern "C" void moto_nav_ui_show_boot_screen(void) {
    configure_typography();
    /* This entry point is also used while the full UI is live. Delete every
       timer that retains widget pointers before reset_ui_state() and
       lv_obj_clean() invalidate the tree. */
    if(ui.page_dots_timer != nullptr) {
        lv_timer_delete(ui.page_dots_timer);
        ui.page_dots_timer = nullptr;
    }
    if(ui.nav_route_motion_timer != nullptr) {
        lv_timer_delete(ui.nav_route_motion_timer);
        ui.nav_route_motion_timer = nullptr;
    }
    if(ui.nav_lifecycle_timer != nullptr) {
        lv_timer_delete(ui.nav_lifecycle_timer);
        ui.nav_lifecycle_timer = nullptr;
    }
    if(ui.nav_success_timer != nullptr) {
        lv_timer_delete(ui.nav_success_timer);
        ui.nav_success_timer = nullptr;
    }
    reset_ui_state();
    ui.screen = lv_screen_active();
    lv_obj_clean(ui.screen);
    lv_obj_remove_flag(ui.screen, LV_OBJ_FLAG_SCROLLABLE);
    const lv_color_t boot_black = LV_COLOR_MAKE(0x00, 0x00, 0x00);
    lv_obj_set_style_bg_color(ui.screen, boot_black, 0);
    lv_obj_set_style_bg_opa(ui.screen, LV_OPA_COVER, 0);

    // Keep the AMOLED background truly black and animate only the white mark.
    // A single opacity animation with a delayed reverse is cheaper than
    // per-letter animation and fits inside the existing 1.25 s boot cadence.
    lv_obj_t *content = make_layer(ui.screen);
    lv_obj_set_style_opa(content, LV_OPA_TRANSP, 0);

    lv_obj_t *mark = lv_obj_create(content);
    lv_obj_remove_style_all(mark);
    lv_obj_set_size(mark, px(150), px(150));
    lv_obj_center(mark);
    lv_obj_set_y(mark, lv_obj_get_y(mark) + px(kBootMarkOpticalYOffset));
    lv_obj_add_event_cb(mark, draw_waymate_mark, LV_EVENT_DRAW_MAIN_END, nullptr);

    lv_anim_t fade;
    lv_anim_init(&fade);
    lv_anim_set_var(&fade, content);
    lv_anim_set_exec_cb(&fade, set_boot_content_opacity);
    lv_anim_set_values(&fade, LV_OPA_TRANSP, LV_OPA_COVER);
    lv_anim_set_delay(&fade, 30);
    lv_anim_set_duration(&fade, 230);
    lv_anim_set_reverse_delay(&fade, 650);
    lv_anim_set_reverse_duration(&fade, 260);
    lv_anim_set_path_cb(&fade, lv_anim_path_ease_in_out);
    lv_anim_start(&fade);
}

extern "C" void moto_nav_ui_show_power_off_screen(void) {
    if(ui.screen == nullptr) return;
    if(ui.page_dots_timer != nullptr) {
        lv_timer_delete(ui.page_dots_timer);
        ui.page_dots_timer = nullptr;
    }
    if(ui.nav_route_motion_timer != nullptr) {
        lv_timer_delete(ui.nav_route_motion_timer);
        ui.nav_route_motion_timer = nullptr;
    }
    if(ui.nav_lifecycle_timer != nullptr) {
        lv_timer_delete(ui.nav_lifecycle_timer);
        ui.nav_lifecycle_timer = nullptr;
    }
    if(ui.nav_success_timer != nullptr) {
        lv_timer_delete(ui.nav_success_timer);
        ui.nav_success_timer = nullptr;
    }

    lv_obj_clean(ui.screen);
    lv_obj_set_style_bg_color(ui.screen, LV_COLOR_MAKE(0x00, 0x00, 0x00), 0);
    lv_obj_set_style_bg_opa(ui.screen, LV_OPA_COVER, 0);

    lv_obj_t *brand = lv_obj_create(ui.screen);
    lv_obj_remove_style_all(brand);
    lv_obj_set_size(brand, px(120), px(120));
    lv_obj_align(brand, LV_ALIGN_CENTER, 0, px(-32 + kBootMarkOpticalYOffset));
    lv_obj_add_event_cb(brand, draw_waymate_mark, LV_EVENT_DRAW_MAIN_END, nullptr);

    lv_obj_t *status = make_label(ui.screen, &tertiary_font,
                                  LV_COLOR_MAKE(0xFF, 0xFF, 0xFF),
                                  "POWER OFF");
    lv_obj_set_style_text_letter_space(status, px(2), 0);
    lv_obj_align(status, LV_ALIGN_CENTER, 0, px(60));
}

extern "C" void moto_nav_ui_create(void) {
    configure_typography();
    reset_ui_state();
    ui.screen = lv_screen_active();
    lv_obj_clean(ui.screen);
    lv_obj_remove_flag(ui.screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(ui.screen, kBlack, 0);
    lv_obj_set_style_bg_opa(ui.screen, LV_OPA_COVER, 0);
    lv_obj_add_event_cb(ui.screen, gesture_event, LV_EVENT_GESTURE, nullptr);
    for(int i = 0; i < MOTO_UI_PAGE_COUNT; ++i) {
        ui.pages[i] = make_layer(ui.screen);
        lv_obj_add_flag(ui.pages[i], LV_OBJ_FLAG_GESTURE_BUBBLE);
    }
    create_navigation_page();
    create_speed_page();
    create_compass_page();
    create_music_page();
    create_backtrack_page();
    for(int i = 1; i < MOTO_UI_PAGE_COUNT; ++i) {
        ui.connection_status[i] = make_label(ui.pages[i], &tertiary_font, kAmber, "");
        lv_obj_align(ui.connection_status[i], LV_ALIGN_BOTTOM_MID, 0, px(-27));
    }
    create_page_dots();
    // Press events are delivered to the topmost object under the finger, not
    // necessarily to its page. Register once across the finished tree so any
    // touch reliably wakes the dots, including the map and music controls.
    install_interaction_wake(ui.screen);

    moto_ui_state_t initial{};
    initial.mode = MOTO_UI_ACQUIRING_FIX;
    initial.page = MOTO_UI_PAGE_NAVIGATION;
    initial.maneuver = MOTO_MANEUVER_STRAIGHT;
    initial.traffic = MOTO_TRAFFIC_UNKNOWN;
    moto_nav_ui_set_state(&initial);
    show_page(MOTO_UI_PAGE_NAVIGATION, true);
}

extern "C" void moto_nav_ui_set_state(const moto_ui_state_t *state) {
    if(state == nullptr || ui.screen == nullptr) return;
    show_page(state->page);
    // NavPresenter maps an unusable fix to zero accuracy. Clear the hidden
    // instrument pages too, so a previous real sample cannot survive a later
    // loss of positioning and appear current when the rider switches pages.
    if(state->gps_accuracy_m == 0 &&
       ui.page != MOTO_UI_PAGE_SPEED && ui.page != MOTO_UI_PAGE_COMPASS) {
        update_speedometer(state);
        update_compass(state);
    }
    // For normal navigation snapshots, hidden pages do not need to be
    // invalidated. Page changes immediately apply a fresh snapshot through
    // PhoneNavBridge, so this keeps every page correct while avoiding three
    // full page redraws per navigation update.
    switch(ui.page) {
        case MOTO_UI_PAGE_NAVIGATION: update_navigation(state); break;
        case MOTO_UI_PAGE_SPEED: update_speedometer(state); break;
        case MOTO_UI_PAGE_COMPASS: update_compass(state); break;
        case MOTO_UI_PAGE_BACKTRACK: update_backtrack(); break;
        case MOTO_UI_PAGE_MUSIC:
        case MOTO_UI_PAGE_COUNT: break;
    }
}

extern "C" void moto_nav_ui_set_backtrack_state(const moto_ui_backtrack_state_t *state) {
    if(state == nullptr || ui.screen == nullptr) return;
    ui.backtrack = *state;
    ui.backtrack.point_count = std::min<uint16_t>(state->point_count, MOTO_UI_BACKTRACK_POINT_CAPACITY);
    if(ui.page == MOTO_UI_PAGE_BACKTRACK) update_backtrack();
    update_page_dots();
}

extern "C" void moto_nav_ui_set_motion_state(const moto_ui_state_t *state) {
    if(state == nullptr || ui.screen == nullptr || state->page != ui.page) return;
    // QMI8658 samples arrive at high frequency. Only the route polyline or
    // compass rose actually changes with yaw; labels, arcs and hidden pages
    // remain untouched so LVGL submits a small, bounded dirty region.
    if(ui.page == MOTO_UI_PAGE_NAVIGATION) {
        update_building_geometry(state);
        update_road_geometry(state);
        update_route_geometry(state);
    } else if(ui.page == MOTO_UI_PAGE_COMPASS) {
        update_compass(state);
    }
}

extern "C" void moto_nav_ui_set_phone_connection(
    moto_ui_phone_connection_t connection) {
    if(ui.screen == nullptr || connection < MOTO_UI_PHONE_OFFLINE ||
       connection > MOTO_UI_PHONE_ONLINE) {
        return;
    }
    if(ui.phone_connection == connection) return;
    const bool became_online =
        connection == MOTO_UI_PHONE_ONLINE &&
        ui.phone_connection != MOTO_UI_PHONE_ONLINE;
    ui.phone_connection = connection;
    if(became_online) {
        ui.lifecycle_success_active = true;
        if(ui.nav_success_timer != nullptr) {
            lv_timer_set_period(ui.nav_success_timer,
                                kConnectionSuccessHoldMs);
            lv_timer_reset(ui.nav_success_timer);
            lv_timer_resume(ui.nav_success_timer);
        }
    } else if(connection != MOTO_UI_PHONE_ONLINE) {
        ui.lifecycle_success_active = false;
        if(ui.nav_success_timer != nullptr) {
            lv_timer_pause(ui.nav_success_timer);
        }
    }
    refresh_lifecycle();
}

extern "C" void moto_nav_ui_set_reduce_motion(uint8_t reduce_motion) {
    ui.reduce_motion = reduce_motion != 0;
    if(ui.nav_lifecycle_timer != nullptr) {
        if(ui.reduce_motion) {
            lv_timer_pause(ui.nav_lifecycle_timer);
        } else {
            lv_timer_resume(ui.nav_lifecycle_timer);
        }
    }
    refresh_lifecycle();
}

extern "C" void moto_nav_ui_set_page(moto_ui_page_t page) {
    if(ui.screen != nullptr) {
        show_page(page, true);
        if(ui.page == MOTO_UI_PAGE_BACKTRACK) update_backtrack();
    }
}

extern "C" moto_ui_page_t moto_nav_ui_get_page(void) {
    return ui.page;
}

extern "C" void moto_nav_ui_set_page_change_callback(
    moto_page_change_callback_t callback, void *context) {
    ui.page_callback = callback;
    ui.page_callback_context = context;
}

extern "C" void moto_nav_ui_set_music_state(const moto_music_state_t *state) {
    if(state == nullptr || ui.screen == nullptr) return;
    ui.music = *state;
    copy_text(ui.music_source_text, sizeof(ui.music_source_text),
              state->source_name, "PHONE MEDIA");
    copy_text(ui.music_title_text, sizeof(ui.music_title_text),
              state->track_title, "");
    copy_text(ui.music_artist_text, sizeof(ui.music_artist_text),
              state->artist_name, "");
    ui.music.source_name = ui.music_source_text;
    ui.music.track_title = ui.music_title_text;
    ui.music.artist_name = ui.music_artist_text;
    update_music_view();
}

extern "C" void moto_nav_ui_set_music_page_enabled(uint8_t enabled) {
    if(ui.screen == nullptr) return;
    ui.music_page_enabled = enabled != 0;
    if(!ui.music_page_enabled && ui.page == MOTO_UI_PAGE_MUSIC) {
        show_page(MOTO_UI_PAGE_NAVIGATION, true);
    }
    update_page_dots();
}

extern "C" void moto_nav_ui_set_music_command_callback(
    moto_music_command_callback_t callback, void *context) {
    ui.music_callback = callback;
    ui.music_callback_context = context;
}

extern "C" void moto_nav_ui_set_demo_active(uint8_t enabled) {
    ui.demo_active = enabled != 0;
    refresh_lifecycle();
}

extern "C" void moto_nav_ui_set_demo_change_callback(
    moto_demo_change_callback_t callback, void *context) {
    ui.demo_callback = callback;
    ui.demo_callback_context = context;
}
