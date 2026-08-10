# 本轮执行报告（2026-08-10）

本文是 Otter MVP 本轮实现、验证与交付证据的单一入口。它记录已经完成的功能、测试方法与结果、性能和内存指标、只读真实服务验证、最终审计修复以及尚未完成的发布门槛。

本文已做脱敏处理：**不包含 API key、服务器地址、实时响应正文或任何可识别的媒体内容**。真实服务器验证全程遵守用户授权的只读边界。

## 1. 交付快照

| 项目 | 结果 |
|---|---|
| 仓库 | `TANG617/Otter` |
| 实现分支 | `codex/implement-otter-mvp` |
| 本报告前代码 HEAD | `e1c9d2d89e5d7f3a2b8f340eb42b330b2bebb442` |
| Draft PR | [#1 — Implement Otter native Immich browsing MVP](https://github.com/TANG617/Otter/pull/1) |
| 最终代码审计修复 | `59cb0c2`、`e1c9d2d` |
| 部署目标 | iOS / iPadOS 18+ |
| 本地工具链 | Xcode 27.0 beta (`27A5228h`)、Swift 6.4、iOS 27.0 Simulator |
| CI 工具链 | Xcode 16.4、iPhone 16 Pro、iOS 18.5、GitHub `macos-15` |
| 真实服务基线 | Immich v3.1.0，只读验证 |

本轮最终范围严格保持为四个产品动作：**Browse、View、Rate、Download**。上传、备份、自动本地图库同步、长期离线图库、macOS 和 Mac Catalyst 均未进入范围。

## 2. 已实现功能

### 2.1 工程与应用壳

- 建立 Swift 6 严格并发的 iPhone/iPad 工程、App/Unit/UI Test targets、XcodeGen 配置和已提交的 `Otter.xcodeproj`。
- 建立 `AppEnvironment`、`AppSession`、路由和 live/fixture runtime 注入边界。
- Onboarding 支持服务器 URL 规范化、API key 输入、取消安全的异步连接验证、明确错误态和稳定 accessibility identifiers。
- API key 使用 Keychain `WhenUnlockedThisDeviceOnly` 保存；诊断信息不显示服务器地址或凭据。
- 每次新连接分配新的 account namespace。同一服务器的另一把 key 不会复用前一个账户的 DB 或媒体缓存。
- 运行期收到 401 会使 session 转为 `authenticationInvalid`，移除本地凭据并清理账户作用域数据。

### 2.2 Immich v3 客户端与能力边界

- 实现服务器版本、metadata search、asset detail、thumbnail/preview/fullsize、original、rating、download info/archive 所需 DTO 和 endpoint builder。
- 受保护请求只通过 `x-api-key` header 认证；URL 规范化为实例根地址加 `/api`。
- 同源重定向可继续携带认证；跨 origin 重定向被拒绝。
- 不依赖 Immich Internal `/timeline/bucket` 或 `/timeline/buckets`。
- 不使用已废弃的 `size=original`；Original 使用 `/assets/{id}/original`。
- API-key 模式不宣称支持 sync stream；metadata search 使用分页、ID 去重、重叠窗口增量刷新和周期全量 reconciliation。
- rating 写入按能力开放，并在写后 GET read-back 验证；失败时回滚本地状态。
- endpoint、响应正文和 API key 不进入用户可见诊断或调试输出。

完整契约见 [Immich API Contract](immich-api-contract.md)。

### 2.3 本地优先数据层

- 使用 GRDB 建立 file-backed account、asset、sync state、server media profile 数据表和索引。
- 首次 bootstrap 分页写入；后续采用 `updatedAfter` 重叠窗口刷新，按 asset ID 去重。
- 每 24 小时触发周期全量 reconciliation，以清理 hard delete、归档/回收站变化和 offset pagination 可能遗漏的记录。
- Timeline 只读取分页窗口，不在启动时物化 10 万条元数据。
- Rating mutation 按 asset 串行化，避免快速 A→B 操作因 actor reentrancy 乱序覆盖；失败回滚受 mutation generation 保护。
- Sign Out 清理 account row、asset rows、sync state、Keychain 和账户媒体缓存；清理失败会显式返回 warning，不会静默成功。

### 2.4 媒体管线

- 实现合法 variant × representation 规划：Current/Original 与 thumbnail/preview/fullsize/original 的能力组合。
- 实现 progressive frame stream：可先显示 ThumbHash/低清帧，再替换为更高质量帧。
- 缺失、损坏或不可解码 derivative 会继续尝试下一个合法 representation，不因首个 404/坏图终止整个计划。
- 实现 account-scoped GRDB 磁盘字节缓存和 `NSCache` 渲染缓存；cache identity 包含账户、资产、revision、variant、purpose 和 pixel bucket。
- 实现 byte/render request coalescing、lease、负缓存、有限重试、取消传播、网络错误分类和 signpost/statistics。
- 调度器按交互/可见/预取 lane 限流；交互请求会抑制仍在队列中的 speculative work。
- 使用 ImageIO 检查尺寸并 downsample；Timeline、Viewer、最大 zoom 的 decode ceiling 分别为 512、3072、4096 px。
- 磁盘清理遇到 active lease 时记录 pending deletion；lease 释放后继续删除，避免 Sign Out 后旧请求重新写回账户数据。

详细设计见 [Media Pipeline](media-pipeline.md)。

### 2.5 Timeline

- 响应式 `LazyVGrid`，支持 iPhone/iPad、多 section 日期分组、稳定 ID、分页加载和去重。
- 增量插入/分组，避免每页对全部已加载资产重复 dictionary + sort。
- direction-aware、bounded、可取消的预取控制器；由可见窗口/滚动方向驱动，而非每个 cell 各自扩散。
- Cell 支持 progressive media、占位/失败态、可访问标签和稳定 accessibility identifiers。
- section count 在尚有下一页时使用 `+` 表示当前仅为已加载数量。

### 2.6 Fullscreen Viewer

- 支持 Current/Original 切换；Original 请求期间保留 Current 作为 fallback，避免空白闪烁。
- 当前项和 N±1 最多维持三个 active streams，N±2 只做 bounded prefetch。
- Viewer 可按需从数据源继续加载相邻页，不限于打开时 Timeline 已经加载的有限数组。
- UIKit `UIScrollView` surface 提供 fit、pinch zoom、pan、double tap、旋转后状态保持。
- zoom 请求按 pixel bucket 升级；同 quality 但更大像素面的 frame 不会被错误丢弃。
- 提供 Info、Settings、关闭、评分和导出入口；分页位置和评分标签具有可访问语义。
- 评分菜单支持 Unrated、Reject、1…5，并即时更新 UI；持久化失败会恢复原值并显示错误。

### 2.7 导出、设置和诊断

- Current/Original 导出语义明确；用户显式选择 Photos 或 Files。
- 导出前检查 representation 可用性；不可用时显示明确原因，不做静默替代。
- URLSession download 临时文件在回调作用域内立即移动到受控临时位置。
- Settings 支持 cache limit、清缓存、Diagnostics 和 Sign Out。
- Diagnostics 提供版本、能力、缓存和安全摘要，但不包含 endpoint、credential 或实时响应正文。
- Sign Out 先停止账户工作，再删除本地 DB/cache/credential；真实服务验证后本地账户数据为零。

### 2.8 Fixture、错误矩阵和 CI

- 确定性的 10k/100k metadata fixture，按页 lazy 生成，不跟踪大体积二进制测试图片。
- fixture media pipeline 支持 progressive stage、延迟、取消、missing/corrupt derivative、rating failure 和 export unavailable 场景。
- 并发安全 `MockURLProtocol` 记录器和响应队列；错误输出已脱敏。
- 运行时生成 PNG/JPEG、12 MP/48 MP 图像；大图仅在明确 performance opt-in 时分配。
- scope regression 脚本阻止 Internal timeline、上传/备份/offline library、macOS/Catalyst、credential-shaped content、私有本地配置和超过 512 KiB 的 tracked fixture。
- GitHub Actions 固定执行依赖解析、generic Simulator build、unit tests 和关键 fixture UI smoke。

## 3. 测试方法

### 3.1 依赖解析与编译

本地通用 Simulator 构建：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

xcodebuild -resolvePackageDependencies \
  -project Otter.xcodeproj \
  -scheme Otter \
  -clonedSourcePackagesDirPath .build/SourcePackages

xcodebuild build \
  -project Otter.xcodeproj \
  -scheme Otter \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO
```

另执行 Swift 6 complete strict concurrency 和 warnings-as-errors 的 `build-for-testing`。GRDB package 自身带有 suppress-warnings 设置，因此 warnings gate 显式传入：

```sh
xcodebuild build-for-testing \
  -project Otter.xcodeproj \
  -scheme Otter \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_SUPPRESS_WARNINGS=NO
```

结果：Otter 源码通过；最终日志仅保留 2 条来自 GRDB dependency 的 Sendable warning，不是 Otter source warning。

### 3.2 Unit tests

```sh
xcodebuild test \
  -project Otter.xcodeproj \
  -scheme Otter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OtterTests
```

覆盖重点：

- URL/API-key normalization、重定向、版本和 DTO contract。
- metadata pagination、ID 去重、重叠窗口、周期全量 reconciliation、hard delete。
- 10k/100k GRDB paging 和 batch merge。
- representation planner、fallback、cache identity、coalescing、scheduler promotion、取消、retry/negative cache。
- active lease 清理与 Sign Out 后禁止回写。
- Timeline pagination/grouping/prefetch bounds/cancellation。
- Viewer progressive staging、Current/Original fallback、N±1 active window、N±2 prefetch、zoom geometry。
- rating 串行化、read-back verification、rollback 和快速连续 mutation。
- export destination/variant 和 unavailable state。
- session、401 invalidation、account isolation、Keychain 和诊断脱敏。

### 3.3 Fixture UI tests

全套 UI smoke：

```sh
scripts/run-ui-smoke-tests.sh
```

脚本依次在 `iPhone 17 Pro` 和 `iPad Pro 13-inch (M5)` 上运行 `OtterUITests`。核心自动化场景：

1. Signed-out 启动，验证 Onboarding 可用和可访问。
2. Fixture Timeline 启动、滚动、打开 Viewer、翻页、评分、Current/Original/Export 入口。
3. 评分失败时 UI 和持久状态回滚。
4. Current export 不可用时显示明确失败，不静默导出其他版本。
5. Settings、Diagnostics、cache 操作、旋转和 Sign Out。

iOS 18.5 的 `Menu` 在 XCTest 中偶发 `AXScrollToVisible / kAXErrorCannotComplete`。最终 smoke 仍用稳定 accessibility ID 找到评分控件，并点击其可见中心坐标；随后继续断言菜单项、选择结果和 UI 状态。该改动只稳定自动化手势，不放宽产品断言。

### 3.4 Scope 与凭据回归

```sh
scripts/check-scope-regressions.sh
git diff --check
```

检查内容包括产品范围、禁止的 Immich Internal API、macOS/Catalyst、credential-shaped tracked content、本地配置文件、live write route 和大体积 fixture。

### 3.5 只读 live harness

Live tests 必须显式 opt in，且凭据只从进程环境读取：

```sh
export OTTER_RUN_LIVE_SERVER_TESTS=YES
export OTTER_TEST_SERVER_URL='<private server URL>'
export OTTER_TEST_API_KEY='<private API key>'
scripts/run-live-server-tests.sh
```

不要把真实值写进仓库、scheme、xcconfig 或 shell history。示例文件 [scripts/live-server.env.example](../scripts/live-server.env.example) 只保留空值。

Harness 允许的网络面只有：

- `GET /api/server/version`
- `POST /api/search/metadata`
- `GET /api/assets/{id}`
- `GET /api/assets/{id}/thumbnail`

它使用 ephemeral/no-cache/no-cookie session，只发送 `x-api-key`，拒绝跨 origin redirect，错误不回显 URL、body 或 key。没有 PUT、PATCH、DELETE、rating、download、archive、sync 或 admin 调用。

### 3.6 GitHub Actions iOS 18 验证

[成功的最终代码 CI run 31377026122](https://github.com/TANG617/Otter/actions/runs/31377026122) 使用：

- GitHub `macos-15`
- Xcode 16.4
- iPhone 16 Pro / iOS 18.5
- Swift package resolve
- generic iOS Simulator build
- 全部 `OtterTests`
- `testFixtureTimelineScrollViewerRatingAndExport` 关键 UI smoke

这提供了独立于本机 Xcode 27 beta 的 iOS 18 编译、单测和关键 iPhone UI 证据。

## 4. 测试结果

| 验证项 | 结果 |
|---|---:|
| Unit tests | 114 discovered；111 passed；0 failed；3 live opt-in skipped |
| iPhone 17 Pro / iOS 27.0 UI | 5/5 passed |
| 最终受影响 iPhone UI 复测 | 2/2 passed |
| iPad Pro 13-inch (M5) / iOS 27.0 key UI | 2/2 passed |
| GitHub CI / Xcode 16.4 / iOS 18.5 | Passed |
| Generic dual-architecture Simulator build | Passed |
| Swift 6 complete strict concurrency build | Passed |
| Warnings-as-errors build-for-testing | Passed for Otter source |
| Scope regression | Passed |
| `git diff --check` | Passed |

3 个 skipped tests 是故意的：未注入 live 环境时，live configuration、public read-only contract 和 first-page live probe 必须显示 skip，而不是意外联网或失败。

## 5. 真实 Immich 只读验证

在用户授权的局域网 Immich v3.1.0 实例上完成以下人工/运行态验证：

1. 使用真实 API key 完成连接验证。
2. 同步并在本地数据库观察到 **41,000** 个 assets。
3. Timeline 显示真实 thumbnails。
4. 打开 Viewer 首个资产并翻到下一项。
5. 打开 Settings，然后执行 Sign Out。
6. Sign Out 后检查本地数据：`accounts=0`、`assets=0`、`syncStates=0`。
7. 媒体缓存目录仅剩 cache SQLite 元数据文件，没有媒体 byte files；Onboarding 字段为空。

严格未执行：rating、Original、Photos/Files export、download info/archive，或任何其他服务器 mutation。系统弹出的保存密码提示选择了 `Not Now`，未把凭据交给系统密码保存流程。

## 6. 性能与内存

### 6.1 100k Timeline ETTrace

环境：Debug build、iPhone 17 Pro / iOS 27.0 Simulator、确定性 100,000-asset fixture。

方法：

1. 用 `-OTTER_USE_FIXTURES YES -OTTER_FIXTURE_ASSET_COUNT 100000` 启动。
2. 等 Timeline 稳定。
3. 连续执行三次约 90% 向上 swipe。
4. 等 visible progressive rendering 收敛。
5. 用 ETTrace 1.1.0 采集并将 Otter binary/dSYM UUID 与 trace 匹配。

| 指标 | 数值 |
|---|---:|
| Trace window | 61.988381 s |
| Main-thread idle | 57.737524 s |
| Main-thread active | 4.210055 s |
| Unattributed | 0.040802 s |
| Main-thread active / window | 约 6.79% |
| 最大 Otter-owned self sample | 5.714 ms，`FixtureRenderKey.isEqual` |
| 次大 Otter-owned self sample | 5.322 ms，media request / asset variant equality |

结论：该 simulator flow 没有持续的 Otter-owned 主线程热点。XCTest/AX snapshot 会显著增加 SwiftUI/UIAccessibility 采样，因此此结果不能等价为真机帧率。

本地 ignored artifact：

```text
.codex-artifacts/performance/ettrace-run/run-20260810-scroll100k/output_259.json
```

### 6.2 Viewer 释放后的 memgraph

方法：完成同一 Timeline scroll 后打开一个 Viewer item，等待媒体稳定，关闭 Viewer，等待 1 秒，再抓取运行进程 memgraph。

| 指标 | 数值 |
|---|---:|
| Physical footprint at capture | 259.8 MiB |
| Peak physical footprint | 314.3 MiB |
| Malloc graph | 224,848 nodes / 77,129 KiB |
| Leak candidates | 40 / 1,312 bytes |
| Otter-owned leaked type / ownership path | 0 |

40 个候选由 38 个匿名 32-byte malloc-zone nodes 和 2 个 SwiftUI `MaterialLuminanceAggregator` array-storage nodes 组成；未发现 Otter 类型或 ownership path。该结论只适用于此 simulator flow，不代表所有路径均已证明无泄漏。

本地 ignored artifacts：

```text
.codex-artifacts/performance/memgraph-100k/com.tang617.otter-87022-20260810-172612.memgraph
.codex-artifacts/performance/memgraph-100k/leak-summary.md
```

性能解释和剩余门槛见 [Performance Baseline](performance-baseline.md)。

## 7. 最终审计后修复

最终只读审计发现并在 `59cb0c2` / `e1c9d2d` 收敛的高价值问题包括：

- 新 key/同服务器账户隔离：取消仅凭服务器 URL 复用 namespace。
- 运行期 401：连接 session invalidation、Keychain 和账户数据清理。
- metadata hard delete/offset gap：加入周期 full reconciliation。
- derivative 404/corrupt：继续 representation fallback。
- 100k 主线程排序：改为增量插入/分组，不再每页全量 sort。
- Viewer 更高像素同质量 frame：以 pixel dimension 决定是否替换。
- Viewer 邻域：N±1 active，N±2 bounded prefetch，并支持继续加载相邻页。
- 快速连续评分：序列化/代次保护，避免晚到失败覆盖后一次成功。
- Sign Out/cache clear 与 active lease：pending deletion，防止清理后回写。
- Timeline/Viewer accessibility：为 cell 和独立控件提供真实语义与稳定 ID。
- iOS 18.5 UI automation：稳定 `Menu` 点击方式并在真实 CI runtime 复测。

## 8. 可复现压力运行

先构建并启动目标 simulator，再运行：

```sh
xcrun simctl launch booted com.tang617.otter \
  -OTTER_USE_FIXTURES YES \
  -OTTER_FIXTURE_ASSET_COUNT 100000
```

默认 fixture 不会分配 48 MP 图像。大图 helper 可能单次分配约 186 MiB，只应在明确的 performance 测试中 opt in。

## 9. 产物位置

### 已纳入仓库

- 本报告：`docs/execution-report-2026-08-10.md`
- 实现状态：[implementation-status.md](implementation-status.md)
- 性能基线：[performance-baseline.md](performance-baseline.md)
- Immich API 契约：[immich-api-contract.md](immich-api-contract.md)
- CI workflow：`.github/workflows/ios.yml`
- Live read-only runner：`scripts/run-live-server-tests.sh`
- UI smoke runner：`scripts/run-ui-smoke-tests.sh`
- Scope regression：`scripts/check-scope-regressions.sh`

### 仅本机保留、被 Git 忽略

- `.codex-artifacts/performance/ettrace-run/`
- `.codex-artifacts/performance/memgraph-100k/`
- 其他运行截图和审计临时证据位于 `.codex-artifacts/`

大体积 trace、memgraph 和截图故意不进入 Git，以避免仓库膨胀或带入本机/实时数据；可复现方法和数值已在 tracked Markdown 中固化。

## 10. 尚未关闭的发布门槛

1. 在代表性真机 iPhone/iPad 上运行 Time Profiler、Animation Hitches、Allocations 和 Leaks。
2. 在 iOS 18.x 真机或本地 runtime 上补全 iPad UI、内存和性能回归；当前 CI 已覆盖 iOS 18.5 iPhone build/unit/关键 UI。
3. 在真机验证 12 MP/48 MP、JPEG/PNG/HEIF/WebP、corrupt payload、网络丢失、429 和 constrained-memory。
4. 验证 Photos 对 WebP/current derivative 的实际保存行为；Files 导出不受此项阻塞。
5. 在稳定 LAN 上采集不含 UI automation/AX sampling 的 cold/warm live 性能。
6. Immich major version 超过 3 时必须重新做 capability probe 和 contract 回归；不能假定 v3 行为永久不变。

这些是明确的 release gates，不影响本轮 MVP 源码、自动化测试和只读真实服务验证已经完成的结论。
