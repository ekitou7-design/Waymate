# BLE v1 additive Backtrack display extension

Stage 7B, 2026-10-07. Frame version and payload revision remain **1**. Existing UUIDs, packet byte layouts, golden vectors and NavigationSnapshot page semantics are unchanged. New messages require `CapabilityBacktrack = 1 << 8` in the existing ConnectionStatus handshake. Without it the phone sends original v1 messages and Speed fallback, never page 4.

| Addition | Value | Meaning |
| --- | --- | --- |
| BacktrackState | 0x15 | Phone-owned live breadcrumb guidance and display selection |
| BacktrackGeometry | 0x16 | Immutable display-only reversed actual trail, bounded chunks |
| DisplayPage::Backtrack | 4 | Independent Backtrack page; accepted by BacktrackState and DeviceCommand PageSelected |

NavigationSnapshot still accepts pages 0–3. DeviceCommand layout is unchanged; page 4 is sent only by a new firmware presenting an active Backtrack session. No new Start/End device command exists. Old firmware decodes unknown application types as UnknownMessageType and discards them; normal v1 packets continue to work. Capability gating prevents this path during normal mixed-version operation.

All integers use existing little-endian encoding. UUID identity is the immutable BacktrackRoute UUID's exact 16 bytes (not a Navigation route token). Generation is nonzero UInt32, incremented once per new route UUID in the phone transport cache, retained across reconnects. Generation is scoped to a phone process; BLE session/connection epoch rejects packets from a prior process/connection.

## BacktrackState (48-byte payload)

| Order | Bytes | Field |
| --- | --- | --- |
| 1 | 1 | payload revision = 1 |
| 2 | 16 | identity UUID |
| 3 | 4 | generation |
| 4 | 2 | flags |
| 5 | 1 | display_page, 0–4 |
| 6 | 4 | remaining_distance_m, actual trail excluding gaps |
| 7 | 4 | target_distance_m, straight distance to phone-selected breadcrumb target |
| 8 | 4 | progress_m, cumulative distance on original source trail |
| 9 | 2 | target_bearing_cdeg, absolute clockwise bearing from north |
| 10 | 2 | direction_cdeg, relative to valid course or north when relative flag is absent |
| 11 | 4 + 4 | current WGS84 latitude_e6 / longitude_e6 |

Flags: bit 0 active; 1 offTrack; 2 arrived; 3 usable location; 4 relative direction; 5 trail gap; 6 paused; 7 display geometry unavailable. Higher bits reject. Unknown target distance = UInt32.max; unknown direction/bearing = UInt16.max. Usable encoded direction is 0–35999. Unusable or paused location hides arrow, target distance and current marker. Arrival does not end Ride.

Inactive state is an End tombstone with the same identity/generation and original page 0–3. Receiver clears breadcrumb state/points and rejects same-generation resurrection, including delayed geometry. A newer identity requires a newer generation. The ESP32 does not compute matching, offTrack, remaining distance or arrival.

## BacktrackGeometry (31 + 14n-byte payload)

Revision u8; UUID[16]; generation u32; chunk_index u16; chunk_count u16; first_point_index u16; total_point_count u16; this_chunk_point_count u16. Each point is WGS84 latitude_e6 s32, longitude_e6 s32, original cumulative progress_m u32, original reversed segment_index u16.

Total display capacity 256. Each chunk contains up to 24 points. Chunk count must be ceil(total/24), first index = chunk_index × 24, and point count must match the remaining capacity. Coordinates, counts, monotonic cumulative positions/segment indices, payload length and identity/generation are validated. Different segment indices MUST NOT be connected, even if they occur in adjacent chunks. Singleton segments remain separate points.

Phone uses display-only per-segment RDP with adaptive metric tolerance; retain endpoints and original cumulative positions, cap work per pass and retry with a larger tolerance. Never modify BacktrackRoute or use simplified points for matching. If mandatory endpoints exceed capacity, send the explicit geometry-unavailable state, show TRAIL TOO LARGE and keep real phone guidance. Never flatten gaps or substitute a provider route.

Geometry uses existing CRC framing, ordered reassembly, fragment sequencing and ACK. One chunk is in flight at a time; retries allocate a new frame sequence. ACK timeout begins after the final fragment was written, not at queue time. Failed/timeout ACK retries the same chunk; three failures use existing reconnect recovery. Matching duplicate chunks ACK Duplicate. State/page waits for ACK of every geometry chunk. Normal progress never resets geometry delivery. Session start/reconnect/reset resends it; no complete RideRecord crosses BLE.

At frame size 182 (170 payload bytes/frame), the worst 256-point geometry needs 11 chunks / 32 frames / 4,309 frame bytes. At frame size 20 (8 payload bytes/frame), it needs 492 frames / 9,829 bytes; a single 24-point chunk is 46 frames, below the existing 128-frame queue budget with its send gate at ≤32 queued frames. ACK/heartbeat/state/connection overhead is additional. State costs one 60-byte frame at 182, or six 20-byte frames at 20.

## Presentation and reconnect

PresentationCoordinator/Driver select Backtrack as real Home. Ordinary progress/rejoin and repeated urgent facts retain manual browsing. New offTrack/arrived transitions reclaim Home; active urgent states preempt temporary Media. Ordinary Backtrack permits the existing 5-second Media temporary window, whose expiry reevaluates Backtrack. Manual Media/Compass retain selection. Swipe order replaces Navigation Home with Backtrack while active, then Speed → Compass → Media. No physical Home shortcut is added.

Navigation → Backtrack stops Navigation on the phone, publishes the real idle Navigation baseline, sends and acknowledges Backtrack geometry, then sends BacktrackState/page. End tombstone precedes any subsequent Navigation geometry/snapshot. Receiver has separate storage and page selection; NavCore's enum/model remain unchanged. WGS84 breadcrumb overview never overlays GCJ-02 road context. Completed edges are Graphite, remaining Ice, and gaps remain blank.

Reconnect retains the phone projection/UUID/progress, clears delivery state, passes the existing handshake/epoch gate, sends the real baseline, restores geometry and then latest state/Home. Ended sessions restore only inactive tombstones and original Home. No Start/End command replay, snapshot rebuild or Ride lifecycle operation occurs.
