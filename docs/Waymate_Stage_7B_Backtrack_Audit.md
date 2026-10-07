# Stage 7B pre-implementation audit

2026-10-07 Asia/Shanghai. HEAD 351c213. Initial status: only untracked design/. No commit/push or design edits.

The production chain audited before changing packets: BacktrackSession/BacktrackRoute → AppModel → PresentationCoordinator/Driver → ESP32BLECentral → Objective-C++ shared codec → BLE v1/Reassembler → NimBLE transport → PhoneNavBridge → NavPresenter → nav_ui. Also inspected NavigationSnapshot, RouteGeometry, MapScene, MediaState, DeviceCommand, native probes, XcodeGen and reconnect/cache machinery.

## Existing BLE Capability

v1 has NavigationSnapshot (phase/maneuver/road/ETA), a continuous 24-point Navigation RouteGeometry window with token/generation, GCJ-02 road/building MapScene, four pages and no Backtrack semantic message. It cannot express Backtrack active, segment breaks, breadcrumb target bearing, offTrack/arrival or independent session identity. Remaining distance can represent metres mechanically but its NavigationSnapshot meaning is ordinary Navigation; using it as Backtrack would fabricate guidance. MapScene spans are genuine road context, not breadcrumb trails.

Frame fragmentation, CRC, sequence rejection, connection epochs, handshake capabilities, ACK, watchdog and paced writes are reusable. PageSelected is a generic user selection; its new value must be capability-gated. Without protocol changes, the honest ceiling is the existing Speed fallback and manual instruments; no Backtrack round guidance.

## Protocol Decision

Use additive v1 extension: BacktrackState 0x15, BacktrackGeometry 0x16, CapabilityBacktrack bit 8 and page Backtrack=4. Keep all existing layouts and NavigationSnapshot's original page validation. Old devices receive only original messages/pages, with Speed fallback. Unknown payload types already return UnknownMessageType without updating application state; no v2 or UUID change.

Backtrack identity uses all 16 bytes of immutable route UUID plus a monotonic UInt32 display generation, independent of Navigation route IDs and BLE connection session. End sends an inactive tombstone, preventing same-generation resurrection. Geometry uses bounded 24-point logical chunks fragmented by the mature framing layer, with one requested ACK per chunk, all completed before State/page. Reconnect resets only delivery bookkeeping and retransmits the current immutable projection. Progress sends only state; no RideRecord, matching or provider requests on ESP32.

## Geometry and render boundary

Display-only per-segment simplification retains original cumulative positions, endpoints, source segment indices and gaps, bounded to 256 points; Stage 7A's source and matching remain untouched. Too many mandatory endpoints must be reported as display geometry unavailable rather than joining gaps. A WGS84-only breadcrumb map has no GCJ-02 background overlay. Presenter performs pixel projection/color splitting only; no nearest matching/offTrack/arrival. Arrow uses phone relative direction when valid, otherwise absolute bearing with NORTH UP.

Coordinator remains the only priority policy. Ordinary progress/rejoin preserves manual browsing; new offTrack and arrived transitions reclaim Home. Media expiry reevaluates the current component. No new device Start/End command or location manager.
