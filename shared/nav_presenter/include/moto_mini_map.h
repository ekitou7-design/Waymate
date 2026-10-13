#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include "nav_core/nav_core.hpp"

namespace moto::nav {
// Native 466px canvas. Both the phone preview and LVGL use this projection.
// No location matching or maneuver inference occurs here: NavCore owns those.
inline constexpr int kMiniMapVehicleX = 233;
inline constexpr int kMiniMapVehicleY = 276;
inline constexpr int kMiniMapLeft = 74, kMiniMapRight = 392;
inline constexpr int kMiniMapTop = 66, kMiniMapBottom = 300;
struct MiniMapPoint { std::int16_t x, y; };
struct MiniMapTransform {
  Gcj02Point origin{};
  double pixels_per_metre = 0.44;
  double longitude_pixels_per_degree = 1, latitude_pixels_per_degree = 1;
  float sin_heading = 0, cos_heading = 1;
};
inline double map_radians(double d) { return d * 3.14159265358979323846 / 180; }
inline bool valid_map_point(const Gcj02Point& p) {
  return std::isfinite(p.latitude_deg) && std::isfinite(p.longitude_deg) &&
         std::abs(p.latitude_deg) < 85 && std::abs(p.longitude_deg) <= 180;
}
inline std::uint32_t map_route_identity(const std::string& id) {
  if(id.empty()) return 0;
  std::uint32_t hash = 2166136261U;
  for(unsigned char c : id) hash = (hash ^ c) * 16777619U;
  return hash == 0 ? 1 : hash;
}
inline MiniMapPoint mini_map_project(const Gcj02Point& point, const MiniMapTransform& t) {
  if(!valid_map_point(point) || !valid_map_point(t.origin))
    return {kMiniMapVehicleX, kMiniMapVehicleY};
  const float east = static_cast<float>(std::remainder(point.longitude_deg - t.origin.longitude_deg, 360.0) * t.longitude_pixels_per_degree);
  const float north = static_cast<float>((point.latitude_deg - t.origin.latitude_deg) * t.latitude_pixels_per_degree);
  const float right = east * t.cos_heading - north * t.sin_heading;
  const float forward = east * t.sin_heading + north * t.cos_heading;
  return {static_cast<std::int16_t>(std::clamp(std::lround(kMiniMapVehicleX + right), -2000L, 2000L)),
          static_cast<std::int16_t>(std::clamp(std::lround(kMiniMapVehicleY - forward), -2000L, 2000L))};
}
inline bool mini_map_has_geometry(const NavSnapshot& s) {
  if(!s.has_route_view || s.route_view_point_count < 2 ||
     s.route_view_point_count > s.route_view_points.size() || !valid_map_point(s.route_view_origin)) return false;
  for(std::size_t i=0; i<s.route_view_point_count; ++i)
    if(!valid_map_point(s.route_view_points[i])) return false;
  return true;
}
// A fixed 8-byte camera state. At ambiguous corners hold the previous planned
// bearing; a new route starts north-up. Never consult IMU/device heading.
struct MiniMapCamera {
  std::uint32_t identity = 0;
  float bearing_rad = 0;
  MiniMapTransform update(const NavSnapshot& s) {
    const auto next_identity = map_route_identity(s.route_id);
    if(identity != next_identity) { identity = next_identity; bearing_rad = 0; }
    if(mini_map_has_geometry(s) && s.has_usable_fix && !s.gnss_stale && !s.off_route &&
       std::isfinite(s.horizontal_accuracy_m) && s.horizontal_accuracy_m > 0) {
      std::optional<double> candidate;
      bool ambiguous = false;
      const double longitude_scale = std::cos(map_radians(s.route_view_origin.latitude_deg));
      for(std::size_t i=1; i<s.route_view_point_count; ++i) {
        const auto& a=s.route_view_points[i-1]; const auto& b=s.route_view_points[i];
        const double ax=map_radians(std::remainder(a.longitude_deg-s.route_view_origin.longitude_deg,360.0))*6371000*longitude_scale;
        const double ay=map_radians(a.latitude_deg-s.route_view_origin.latitude_deg)*6371000;
        const double dx=map_radians(std::remainder(b.longitude_deg-a.longitude_deg,360.0))*6371000*longitude_scale;
        const double dy=map_radians(b.latitude_deg-a.latitude_deg)*6371000;
        const double length2=dx*dx+dy*dy;
        if(length2 < 0.01) continue;
        const double along=std::clamp(-(ax*dx+ay*dy)/length2,0.0,1.0);
        if(std::hypot(ax+along*dx,ay+along*dy) > s.horizontal_accuracy_m+3) continue;
        const double bearing=std::atan2(dx,dy);
        if(candidate && std::abs(std::remainder(bearing-*candidate,2*3.14159265358979323846)) > map_radians(20)) ambiguous=true;
        else candidate=bearing;
      }
      if(candidate && !ambiguous) bearing_rad=static_cast<float>(*candidate);
    }
    // Continuous zoom, with a visible approach plus road after the action.
    // Existing LVGL interpolation eases the projected targets at 40Hz.
    const double distance = s.has_next_maneuver && std::isfinite(s.distance_to_next_maneuver_m)
                              ? std::max(0.0,s.distance_to_next_maneuver_m) : 320.0;
    const double horizon=std::clamp(distance+120.0,200.0,700.0);
    const double scale=std::clamp(200.0/horizon,0.25,1.2);
    const double latitude_pixels=map_radians(1)*6371000*scale;
    return {s.route_view_origin, scale,
            latitude_pixels*std::cos(map_radians(s.route_view_origin.latitude_deg)), latitude_pixels,
            std::sin(bearing_rad),std::cos(bearing_rad)};
  }
};
static_assert(sizeof(MiniMapCamera) == 8);
}
