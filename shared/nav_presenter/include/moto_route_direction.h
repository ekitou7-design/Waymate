#pragma once
#include <algorithm>
#include <cmath>
#include "nav_core/nav_core.hpp"

namespace moto::nav {
inline double direction_radians(double d) { return d * 3.14159265358979323846 / 180.0; }
// Read-only planned geometry projection shared by iPhone and ESP32.
inline const char* planned_route_direction(const NavSnapshot& snapshot) {
  constexpr const char* unknown = "沿路线前进";
  if (snapshot.state != NavState::Navigating || !snapshot.has_usable_fix ||
      snapshot.gnss_stale || snapshot.off_route || !snapshot.has_route_view ||
      snapshot.route_id.empty() || snapshot.route_view_point_count < 2 ||
      snapshot.route_view_point_count > snapshot.route_view_points.size() ||
      !std::isfinite(snapshot.horizontal_accuracy_m) ||
      snapshot.horizontal_accuracy_m <= 0) return unknown;
  const auto valid = [](const Gcj02Point& p) {
    return std::isfinite(p.latitude_deg) && std::isfinite(p.longitude_deg) &&
           std::abs(p.latitude_deg) < 85 && std::abs(p.longitude_deg) <= 180;
  };
  const auto& origin = snapshot.route_view_origin;
  if (!valid(origin)) return unknown;
  const double longitude_scale = std::cos(direction_radians(origin.latitude_deg));
  // NavCore simplifies this planned window at 3 m tolerance. Include that
  // uncertainty both in segment proximity and in the bearing sector boundary.
  constexpr double geometry_error_m = 3.0;
  const double radius = snapshot.horizontal_accuracy_m + geometry_error_m;
  int direction = -1;
  for (std::size_t i = 1; i < snapshot.route_view_point_count; ++i) {
    const auto& a = snapshot.route_view_points[i - 1];
    const auto& b = snapshot.route_view_points[i];
    if (!valid(a) || !valid(b)) return unknown;
    const double ax = direction_radians(std::remainder(a.longitude_deg - origin.longitude_deg, 360.0)) * 6371000.0 * longitude_scale;
    const double ay = direction_radians(a.latitude_deg - origin.latitude_deg) * 6371000.0;
    const double dx = direction_radians(std::remainder(b.longitude_deg - a.longitude_deg, 360.0)) * 6371000.0 * longitude_scale;
    const double dy = direction_radians(b.latitude_deg - a.latitude_deg) * 6371000.0;
    const double length2 = dx * dx + dy * dy;
    if (length2 < 0.01) continue; // Duplicate route points carry no direction.
    const double t = std::clamp(-(ax * dx + ay * dy) / length2, 0.0, 1.0);
    if (std::hypot(ax + t * dx, ay + t * dy) > radius) continue;
    const double bearing = std::atan2(dx, dy) * 180.0 / 3.14159265358979323846;
    const int sector = static_cast<int>(std::floor((bearing + 382.5) / 45.0)) % 8;
    const double uncertainty = std::atan2(2 * geometry_error_m, std::sqrt(length2)) * 180.0 / 3.14159265358979323846;
    if (std::abs(std::remainder(bearing - sector * 45.0, 360.0)) + uncertainty >= 22.5)
      return unknown;
    // At corners, crossings or parallel opposite lanes, an uncertain current
    // segment must not become a confidently wrong compass instruction.
    if (direction != -1 && direction != sector) return unknown;
    direction = sector;
  }
  static constexpr const char* labels[] = {
      "北", "东北", "东", "东南", "南", "西南", "西", "西北"};
  return direction < 0 ? unknown : labels[direction];
}

}
