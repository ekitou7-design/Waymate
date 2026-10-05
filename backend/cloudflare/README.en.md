> **Language:** English · [中文](README.md)
>
> The Chinese version is authoritative if the two versions differ.

# Deploy the Cloudflare Workers Free Navigation Mode

This is an additional deployment option requested in
[issue #2](https://github.com/mx3353672833-debug/moto-gps-waveshare/issues/2).
The existing [Node.js server deployment](../README.en.md), its commands and defaults remain available.
Both deployments reuse the search, routing, city, map conversion and protocol validation code.
iOS and ESP32 keep the same protocol.

```text
iPhone → your Worker HTTPS endpoint → AMap (places / routes / alternatives / rerouting / cities)
                                   ✕ surrounding map tiles (explicitly disabled)
```

This mode does not create, bind or use Cloudflare R2, so it does not require a payment method for map caching.
Configure the AMap key only as a Worker Secret. You need your own Cloudflare account and AMap permissions;
the repository does not provide a public navigation service. iPhone, ESP32 and their BLE/navigation protocol stay unchanged.

## 1. Test locally

Install Node.js 22+ (24 recommended) and npm. From the repository root:

```sh
npm ci --prefix backend
npm ci --prefix backend/cloudflare
npm test --prefix backend
npm test --prefix backend/cloudflare
```

The Workers checks run inside Miniflare / workerd with no R2 binding and controlled upstream responses.
No account or real key is needed. They cover routes and alternatives, places, cities, input validation,
rate limiting and the explicit map-disabled response.
Passing these checks does not verify mainland China connectivity or a real AMap account.

Enter this directory and copy `.dev.vars.example` to `.dev.vars`:

```sh
cd backend/cloudflare
cp .dev.vars.example .dev.vars
npm run dev
```

On Windows PowerShell, use `Copy-Item .dev.vars.example .dev.vars`; the npm commands are the same.
Open `http://localhost:8787/healthz`. The example uses **fixture mode**: synthetic routes, empty place
results and `ready_for_live_navigation=false`, without contacting AMap or online maps.
`.dev.vars` is local only; it does not configure the deployed Worker.

## 2. Configure the Worker without R2

Run the following commands from `backend/cloudflare`:

```sh
npx wrangler login
```

`wrangler.jsonc` already sets `MOTO_PROVIDER=amap` and `MOTO_MAP_PMTILES_URL=disabled`,
and contains no `r2_buckets` configuration:

| Setting | Purpose |
| --- | --- |
| `MOTO_PROVIDER` | `amap`, enabling real AMap places, routes, alternatives, rerouting and city queries |
| `MOTO_MAP_PMTILES_URL` | `disabled`, turning surrounding map tiles off |
| `WEB_ORIGIN` | Allowed website origin, e.g. `https://nav.example.com`; use an empty string for native-app-only use |
| `MOTO_BASE_PATH` | Empty by default, exposing `/v1/...`; `/moto-gps/api` exposes `/moto-gps/api/v1/...`; no trailing slash |

The map endpoint remains for protocol compatibility. It returns `503` with `MAP_DISABLED` when called;
it does not contact a map source and never fails because an R2 binding is missing. `/healthz` reports
`ready_for_live_navigation=true`, `capabilities.real_navigation=true`, and `capabilities.surrounding_map=false`.

Set your AMap **Web Service key**:

```sh
npx wrangler secret put AMAP_WEB_SERVICE_KEY
```

Paste it at the prompt. Never put it in `wrangler.jsonc`, Git or an Issue. Live mode without a key returns
503 instead of a synthetic route. Your AMap account needs POI, driving route and administrative district
permissions and quota. For rejected requests, inspect account restrictions and the returned error code.
If you use an outbound IP allowlist, separately verify that Workers egress meets those restrictions.

## 3. Deploy and connect the app

```sh
npm run build
npm run deploy
```

`build` only bundles and checks the Worker. `deploy` uploads it to your own Cloudflare account.
Use the returned `https://moto-gps-gateway.<your-subdomain>.workers.dev/` URL, or follow
[Cloudflare's custom-domain setup](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/).
A custom domain alone does not guarantee mainland China connectivity.

Enter the deployed HTTPS base URL in the app’s 网关设置 (Gateway settings) and save to apply it immediately.
Source builds can still use `MOTOGPSGatewayBaseURL` in `platforms/ios/project.yml` as the default.
Without a Mac, use the [IPA installation guide](../../docs/IOS_SIDELOAD.en.md). With the default path:

```text
https://moto-gps-gateway.YOUR-SUBDOMAIN.workers.dev/
```

With `MOTO_BASE_PATH=/moto-gps/api`:

```text
https://nav.example.com/moto-gps/api/
```

Use the same prefix in verification requests below. No ESP32 firmware change is needed.
The original server remains available; to switch back, save its URL in the app’s gateway settings.

## 4. Verify your deployment

Replace the placeholder URL with your endpoint. On Windows use `curl.exe` to avoid PowerShell alias differences.

```sh
curl --fail-with-body https://YOUR-WORKER/healthz
curl --fail-with-body 'https://YOUR-WORKER/v1/places?keywords=%E6%B5%8E%E5%8D%97%E8%A5%BF%E7%AB%99'
curl --fail-with-body 'https://YOUR-WORKER/v1/map/cities?keywords=%E6%B5%8E%E5%8D%97'
curl --fail-with-body -H 'Content-Type: application/json' --data-binary @../fixtures/route-request-v1.json https://YOUR-WORKER/v1/routes
curl --fail-with-body -H 'Content-Type: application/json' --data-binary @../fixtures/route-request-v1.json https://YOUR-WORKER/v1/route-options
curl -i https://YOUR-WORKER/v1/map/tiles/15/27044/12791
```

Check `provider=amap` and successful real searches, routes and alternatives. A tile request should return
`error.code=MAP_DISABLED`, not fixture roads or an R2 binding error.
`/healthz` reports configured capabilities; it does not contact AMap or the map source and does not
prove upstream availability. Speed limits and traffic-light countdown remain unsupported.

On a phone using cellular data in the intended region, test place searches, route planning, alternatives,
rerouting and the iPhone → BLE → ESP32 navigation path. Record latency and timeouts. The Issue's reported OTA throughput does not verify
these operations. This implementation does not add IP selection or promise network speeds.
Large tile decoding can reach Workers CPU, memory or subrequest limits; confirm plan quotas and costs
against the actual workload.

## Runtime behavior and limitations

- Existing routes, searches, cities and error JSON contracts are preserved through Cloudflare's official Node HTTP adapter.
- `surrounding_map` is unavailable in this mode: the Worker does not read PMTiles, create R2, cache tiles or invent roads.
- iOS route planning, alternatives, live route requests, rerouting and BLE navigation messages do not depend on surrounding maps.
- Existing bundled/local iOS maps remain usable; this Worker does not provide new tile downloads.
- Cloudflare per-IP limits are 30 route, 60 place, 30 city and 600 tile requests per minute.
  These are edge limits, not strict account-wide quotas. Use different `namespace_id` values for separate
  gateways to avoid shared quotas. Users behind one public IP share its allowance. CORS and rate limiting
  are not authentication; configure access protection for your intended audience.
- This addition does not switch a production domain or the app's default gateway. It provides code and
  instructions for an optional deployment.

References: [Workers Node HTTP](https://developers.cloudflare.com/workers/runtime-apis/nodejs/http/),
[Workers rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/).
