> **语言 / Language:** 中文 · [English](README.en.md)

# Cloudflare Workers 无 R2 实时导航部署

这是 [issue #2](https://github.com/mx3353672833-debug/moto-gps-waveshare/issues/2) 提出的新增部署方式。
原有 [Node.js + 自建服务器](../README.md) 方案继续保留，启动命令和默认行为不变。
两种部署共用搜索、路线、城市、地图转换和协议校验代码，iOS / ESP32 无需更换协议。

```text
iPhone → 你的 Worker HTTPS 地址 → 高德 Web 服务（POI / 路线 / 候选路线 / 偏航重算 / 城市）
                              ✕ 周边地图瓦片（Free Navigation Mode 中明确禁用）
```

此模式不创建、不绑定也不依赖 Cloudflare R2，不启用地图瓦片缓存，因此不需要绑定付款方式。
高德 Key 只通过 Worker Secret 配置。此方案仍需自己的 Cloudflare 账号和高德服务权限，
仓库不提供公共导航接口；iPhone 与 ESP32 的 BLE 和导航协议不变。

## 1. 本地验证

安装 Node.js 22+（推荐 24）和 npm。在仓库根目录运行：

```sh
npm ci --prefix backend
npm ci --prefix backend/cloudflare
npm test --prefix backend
npm test --prefix backend/cloudflare
```

Workers 测试在 Miniflare / workerd 中执行，使用无 R2 binding 的 Worker 和受控的高德上游响应，
不需要账号或真实 Key。覆盖路线与候选路线、搜索、城市、输入校验、限流，以及地图明确禁用。
测试通过不代表国内网络或真实高德账号已经验收。

进入本目录，复制 `.dev.vars.example` 为 `.dev.vars`：

```sh
cd backend/cloudflare
cp .dev.vars.example .dev.vars
npm run dev
```

Windows 可在 PowerShell 中用 `Copy-Item .dev.vars.example .dev.vars`，其余 npm 命令相同。
然后打开 `http://localhost:8787/healthz`。示例是 **fixture 模式**：返回合成路线、空搜索结果，
`ready_for_live_navigation=false`，不会访问高德或在线地图。`.dev.vars` 只供本地使用，不会部署为远端配置。

## 2. 配置 Worker（无需 R2）

以下命令均在 `backend/cloudflare` 执行：

```sh
npx wrangler login
```

`wrangler.jsonc` 已将生产路径设为 `MOTO_PROVIDER=amap` 和
`MOTO_MAP_PMTILES_URL=disabled`，并且没有 `r2_buckets` 配置：

| 配置 | 用途 |
| --- | --- |
| `MOTO_PROVIDER` | `amap`，启用真实高德 POI、路线、候选路线、偏航重算和城市查询 |
| `MOTO_MAP_PMTILES_URL` | `disabled`，关闭周边地图瓦片 |
| `WEB_ORIGIN` | 允许的网页 Origin，例如 `https://nav.example.com`；只用原生 App 可设空字符串 |
| `MOTO_BASE_PATH` | 默认空字符串，接口在 `/v1/...`；如设 `/moto-gps/api`，接口就在 `/moto-gps/api/v1/...`，不要加末尾 `/` |

地图接口仍保留用于协议兼容；被调用时返回 `503` 和 `MAP_DISABLED`，不会访问地图源，也不会报 R2 未绑定异常。
`/healthz` 会报告 `ready_for_live_navigation=true`、`capabilities.real_navigation=true`，以及
`capabilities.surrounding_map=false`。

添加自己的高德 **Web 服务 Key**：

```sh
npx wrangler secret put AMAP_WEB_SERVICE_KEY
```

在提示中粘贴 Key，不要写入 `wrangler.jsonc`、Git 或 Issue。启用 `amap` 却没有 Key 时返回 503，
不会偷偷回退到演示路线。高德账号需具备 POI、驾车路线、行政区划权限和配额；实际请求失败时检查
高德控制台的限制及返回错误码。若配置了出口 IP 白名单，必须另行验证 Workers 的出口是否符合要求。

## 3. 部署及连接 App

```sh
npm run build
npm run deploy
```

`build` 仅打包检查，不上传。`deploy` 才会部署到自己的 Cloudflare 账号。
默认使用命令返回的 `https://moto-gps-gateway.<你的子域>.workers.dev/`。
也可按 [Cloudflare 自定义域名文档](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
绑定自己的域名；自定义域名不会自动提供中国大陆网络质量保证。

在 App 的“网关设置”中填写部署后的 HTTPS 根地址并保存，即时生效。
也可以在源码构建时通过 `platforms/ios/project.yml` 的 `MOTOGPSGatewayBaseURL` 设置默认值。
没有 Mac 可使用 [IPA 安装方式](../../docs/IOS_SIDELOAD.md)。默认路径示例：

```text
https://moto-gps-gateway.YOUR-SUBDOMAIN.workers.dev/
```

若设置了 `MOTO_BASE_PATH=/moto-gps/api`，App 地址相应变为：

```text
https://nav.example.com/moto-gps/api/
```

同一个前缀要同时用于下面的验收请求。ESP32 固件不需要修改。
原服务器地址继续可用；回退时在 App 的“网关设置”中保存原地址。

## 4. 实际验收

下面占位地址必须换成自己的部署地址。Windows 使用 `curl.exe` 可避免 PowerShell 别名差异。

```sh
curl --fail-with-body https://YOUR-WORKER/healthz
curl --fail-with-body 'https://YOUR-WORKER/v1/places?keywords=%E6%B5%8E%E5%8D%97%E8%A5%BF%E7%AB%99'
curl --fail-with-body 'https://YOUR-WORKER/v1/map/cities?keywords=%E6%B5%8E%E5%8D%97'
curl --fail-with-body -H 'Content-Type: application/json' --data-binary @../fixtures/route-request-v1.json https://YOUR-WORKER/v1/routes
curl --fail-with-body -H 'Content-Type: application/json' --data-binary @../fixtures/route-request-v1.json https://YOUR-WORKER/v1/route-options
curl -i https://YOUR-WORKER/v1/map/tiles/15/27044/12791
```

确认 `provider=amap`、真实搜索、路线和候选路线成功；瓦片请求应明确返回
`error.code=MAP_DISABLED`，而不是 fixture 道路或 R2 错误。
`/healthz` 只报告已配置的能力，不主动请求高德或地图源；它不证明上游在线。
限速和红绿灯倒计时仍报告未支持，不因更换部署方式而增加。

在实际使用地区用手机蜂窝网络测试搜索、路线、候选路线、偏航重算和 iPhone → BLE → ESP32 链路，记录超时和延迟。
Issue 中的 OTA 下载速度不能替代这些验证；本方案没有内置 IP 优选或测速承诺。
大瓦片解码可能触及 Workers CPU / 内存 / 子请求限制，应根据实际负载确认套餐配额与成本。

## 运行方式和限制

- 路线、搜索、城市和错误 JSON 契约保留。Workers 使用官方 Node HTTP 适配器运行同一网关。
- `surrounding_map` 暂时不可用；本 Worker 不读取 PMTiles、不创建 R2、不缓存地图瓦片，也不生成假道路。
- iOS 的路线规划、候选路线、实时路线请求、偏航重算和 BLE 导航消息不依赖周边地图能力。
- iOS 已有的内置/本地离线地图仍可使用；本 Worker 不提供新的瓦片下载。
- Cloudflare 限流按 IP 分为路线 30、搜索 60、城市 30、瓦片 600 次/分钟。
  这是边缘限流而非全账号严格配额；不同网关应使用独立的 `namespace_id`，避免互相占用额度。
  多人共用一个公网 IP 会共享限额。CORS 和限流都不是用户认证，公开服务需按自己的访问范围配置保护。
- 没有自动切换线上域名，也不修改 App 默认网关。仓库只新增可自行部署的代码和说明。

实现依据：[Workers Node HTTP](https://developers.cloudflare.com/workers/runtime-apis/nodejs/http/)、
[Workers 限流](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)。
