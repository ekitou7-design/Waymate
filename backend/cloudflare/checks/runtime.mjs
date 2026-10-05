import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

const config = JSON.parse(await readFile(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
const routeRequest = JSON.parse(await readFile(new URL("../../fixtures/route-request-v1.json", import.meta.url), "utf8"));
const routeFixture = await readFile(new URL("../../fixtures/amap-route-v2.json", import.meta.url), "utf8");

async function runtime(t, bindings = {}, outboundService = () => { throw new Error("unexpected network request"); }) {
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: true, scriptPath: fileURLToPath(new URL("../dist/worker.js", import.meta.url)),
    compatibilityDate: config.compatibility_date, compatibilityFlags: config.compatibility_flags,
    bindings: { ...config.vars, ...bindings },
    ratelimits: Object.fromEntries(config.ratelimits.map(({ name, ...value }) => [name, value])),
    outboundService,
  }));
  t.after(() => mf.dispose());
  return mf;
}
const requestRoute = (mf, path = "/v1/routes", body = JSON.stringify(routeRequest), headers = {}) =>
  mf.dispatchFetch(`https://gateway.test${path}`, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body });

test("disabled default is offline, reports no live readiness, and preserves errors/CORS", async (t) => {
  const mf = await runtime(t, { MOTO_PROVIDER: "disabled" });
  const response = await mf.dispatchFetch("https://gateway.test/healthz");
  assert.equal(response.status, 200);
  const health = await response.json();
  assert.equal(health.ready_for_live_navigation, false);
  assert.equal(health.capabilities.surrounding_map, false);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), config.vars.WEB_ORIGIN);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const route = await requestRoute(mf);
  assert.equal(route.status, 503);
  assert.equal((await route.json()).error.code, "SERVER_MISCONFIGURED");
  assert.equal((await mf.dispatchFetch("https://gateway.test/unknown")).status, 404);
  assert.equal((await mf.dispatchFetch("https://gateway.test/v1/routes", { method: "OPTIONS" })).status, 204);
});

test("fixture routes, route options, validation and optional base path use the shared gateway", async (t) => {
  const mf = await runtime(t, { MOTO_PROVIDER: "fixture", MOTO_BASE_PATH: "/moto-gps/api" });
  assert.equal((await mf.dispatchFetch("https://gateway.test/healthz")).status, 404);
  const health = await (await mf.dispatchFetch("https://gateway.test/moto-gps/api/healthz")).json();
  assert.equal(health.ready_for_live_navigation, false);
  const route = await requestRoute(mf, "/moto-gps/api/v1/routes");
  assert.equal(route.status, 200);
  assert.equal((await route.json()).request_id, routeRequest.request_id);
  const options = await (await requestRoute(mf, "/moto-gps/api/v1/route-options")).json();
  assert.ok(options.routes.length >= 1 && options.routes.length <= 3);
  for (const [body, code] of [["{", "INVALID_JSON"], ["{}", "INVALID_REQUEST"], ['"' + "x".repeat(9000) + '"', "REQUEST_TOO_LARGE"]]) {
    const result = await requestRoute(mf, "/moto-gps/api/v1/routes", body);
    assert.equal(result.status, 400);
    assert.equal((await result.json()).error.code, code);
  }
});

test("live mode forwards route, POI and city queries to AMap without exposing its key", async (t) => {
  const seen = [];
  const mf = await runtime(t, { MOTO_PROVIDER: "amap", AMAP_WEB_SERVICE_KEY: "secret-test-key", MOTO_MAP_PMTILES_URL: "disabled" }, (request) => {
    const url = new URL(request.url); seen.push(url.pathname);
    assert.equal(url.hostname, "restapi.amap.com");
    assert.equal(url.searchParams.get("key"), "secret-test-key");
    if (url.pathname === "/v5/direction/driving") return new Response(routeFixture);
    if (url.pathname === "/v5/place/text") return Response.json({ status: "1", pois: [{ id: "test-poi", name: "济南站", location: "117.0,36.6" }] });
    if (url.pathname === "/v3/config/district") return Response.json({ status: "1", districts: [{ adcode: "370102", level: "district", name: "历下区", polyline: "117.1,36.6;117.2,36.6;117.2,36.7;117.1,36.7;117.1,36.6" }] });
    throw new Error("unexpected upstream");
  });
  const routes = await requestRoute(mf);
  assert.equal(routes.status, 200); assert.doesNotMatch(await routes.text(), /secret-test-key/);
  const places = await (await mf.dispatchFetch("https://gateway.test/v1/places?keywords=济南站")).json();
  assert.equal(places.places[0].name, "济南站");
  const cities = await (await mf.dispatchFetch("https://gateway.test/v1/map/cities?keywords=历下区")).json();
  assert.equal(cities.cities[0].id, "370102");
  assert.equal(seen.length, 3);
});

test("live mode needs no R2 and reports surrounding maps as disabled", async (t) => {
  const mf = await runtime(t, { MOTO_PROVIDER: "amap", AMAP_WEB_SERVICE_KEY: "secret-test-key" });
  const health = await (await mf.dispatchFetch("https://gateway.test/healthz")).json();
  assert.equal(health.ready_for_live_navigation, true);
  assert.equal(health.capabilities.real_navigation, true);
  assert.equal(health.capabilities.surrounding_map, false);
  assert.deepEqual(health.map_source, {
    enabled: false,
    mode: "disabled",
    reason: "surrounding map is disabled",
  });
  const response = await mf.dispatchFetch("https://gateway.test/v1/map/tiles/15/27044/12791");
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "MAP_DISABLED");
});

test("AMap rejection cannot fall back to a synthetic route or leak credentials", async (t) => {
  const mf = await runtime(t, { MOTO_PROVIDER: "amap", AMAP_WEB_SERVICE_KEY: "secret-test-key", MOTO_MAP_PMTILES_URL: "disabled" },
    () => Response.json({ status: "0", infocode: "10001", info: "secret-test-key" }));
  const result = await requestRoute(mf);
  assert.equal(result.status, 503);
  const text = await result.text();
  assert.doesNotMatch(text, /secret-test-key/);
  assert.equal(JSON.parse(text).error.code, "AMAP_10001");
  assert.equal(JSON.parse(text).route, undefined);
});

test("missing live key fails closed", async (t) => {
  const mf = await runtime(t, { MOTO_PROVIDER: "amap" });
  const response = await mf.dispatchFetch("https://gateway.test/healthz");
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "SERVER_MISCONFIGURED");
});

test("rate limits cannot be bypassed using X-Real-IP", async (t) => {
  const mf = await runtime(t, { MOTO_PROVIDER: "fixture" });
  for (let i = 0; i < 30; i++) {
    const result = await requestRoute(mf, "/v1/routes", JSON.stringify(routeRequest), { "X-Real-IP": `192.0.2.${i}` });
    assert.equal(result.status, 200);
    await result.text();
  }
  const blocked = await requestRoute(mf);
  assert.equal(blocked.status, 429);
  assert.equal(blocked.headers.get("Retry-After"), "60");
});
