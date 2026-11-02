# PI Desktop 接入方案

- 状态：已实施（PR #9 已合并）
- 日期：2026-11-02
- 目标运行时版本：PI Desktop 0.21.0（`net.aiuo.pi-desktop`）
- 相关文档：`docs/product.md`、`docs/architecture.md`、`docs/hooks.md`

## 0. TL;DR

PI Desktop 是 Electron 应用，**每个会话没有独立进程**，所有会话共用一个
`~/.pi-desktop/pi.sqlite`。因此它不能复用 `pi` CLI 那套「每个进程装一个
extension，靠 hook 报事件」的模型，而应该走 **DSH 式的宿主集成**：

1. 主要数据源是 `pi.sqlite` 的只读轮询（会话 / 消息 / turn / token 都在里面）；
2. 可选增强是一个 PI Desktop 插件，负责「低延迟推送 + 审批 + 会话级聚焦」三件事；
3. 桥上新开 `processPiDesktopHook` 命令，payload 结构与 `DSHHookPayload` 同构；
4. 视觉上用一套灰白（偏白）品牌色，避免和岛上现有的高饱和 agent 色打架。

## 1. 目标与非目标

目标：

- PI Desktop 里每个活跃会话在刘海里有一行，能看出「在跑什么 / 用什么模型 / 进行到哪一步」；
- 状态准确：运行中 / 等待审批 / 已完成，不出现「跑完了还挂着」的幽灵会话；
- 今日 token 并入现有的 today-token 卡片；
- 一键切回 PI Desktop（能做到会话级聚焦更好）；
- 失败开放：PI Desktop 没装、没跑、schema 变了、插件没启用，都只是「少一个数据源」，不影响其它 agent。

非目标：

- 不接管 PI Desktop 的 provider / model / MCP 配置；
- 不做 RACP 远程控制（手机配对那套），只做本机监控；
- 不复用 pi CLI 的 `~/.pi/agent/extensions/open-island.ts`（数据源完全不同）；
- 不做「替用户在 PI Desktop 里发送消息」。

## 2. 事实底座（已核实）

| 项 | 结论 | 证据 |
|---|---|---|
| 应用 | `/Applications/PI-Desktop.app`，bundle id `net.aiuo.pi-desktop`，0.21.0，Electron 43，Team ID `DUV63RKYTW`，中文 UI | `Info.plist`、`codesign -dv` |
| 数据目录 | `~/.pi-desktop/`：`pi.sqlite`（2.3 MB）+ `pi.sqlite-wal`（4 MB，活跃写入）+ `plugins/` + `logs/` | 文件系统 |
| schema 版本 | `PRAGMA user_version = 24` | sqlite |
| 核心表 | `sessions`(5) / `turns`(49) / `messages`(1269) / `session_todo`(8) / `projects`(1) / `providers`(1) / `audit_log`(614) | sqlite |
| 会话字段 | `id/title/project_id/provider_id/model_id/mode/permission_mode/source/pinned/last_seq/created_at/updated_at/deleted_at` | schema |
| turn 字段 | `id/session_id/status(running·completed·aborted·error)/input_tokens/output_tokens/usage_json/started_at/ended_at` | schema |
| usage_json | `{inputTokens, outputTokens, cacheReadTokens, reasoningTokens, totalTokens, operations[], aggregation:"aggregate"}` | 实测样本 |
| 消息字段 | `role(user/assistant/tool/system)/tool_name/text/streaming/seq/turn_id`，工具名如 `Bash` `Read` `Write` `plugin_*` | 实测 |
| 插件目录 | `~/.pi-desktop/plugins/{installed,dev,market}`；`registry.json` 记录 id/enabled/scope/permissions | 实测 |
| 插件入口 | `main.js` 在独立 Node 进程执行，注入全局 `pi`，只有 `onLoad`/`onUnload`；面板另有 `window.pluginBridge` | `Resources/skills/plugin-development.md` |
| 宿主 API | `app/plugin/commands/ui/workspace/fs/agent/session/usage/services/bus/clipboard/shell/net/events/desktop/keyboard/browser/audio/models/providers` | asar 反编译 |
| 会话读取权限 | `session.list/get/listMessages` 只要求 **`session.read.own`** —— 只能读插件自己导入的会话，**读不到用户会话** | asar `case "session.list"` |
| LLM 上下文权限 | `session.read` 仅允许在「插件工具执行期间」读当前会话上下文 | asar `readSessionContext` |
| 用量 API | `pi.usage.listTurns`（`usage.read`）返回每 turn 计数器与会话标题，不含消息体 | 文档 + asar |
| 桌面控制 | `pi.desktop.listOperations()` / `invoke()`（`desktop.control`，高风险），操作集需运行时枚举 | asar |
| 事件 | RACP 事件族：`session.created/changed/archived`、`turn.queued/started/completed/interrupted/failed/canceled/activity`、`item.started/delta/completed`、`tool.progress`、`approval.requested/resolved`、`input.requested/resolved`、`terminal.*`、`resync.required` | asar schema |
| 插件可收事件 | 插件侧只有 3 个 session 事件：`session:activated`、`session:modelChanged`、`session:turnEnded`；另有 `appearance:changed`、`workspace:changed`。实测收到过 `session:activated`（载荷含 `sessionId`/`projectPath`/`activeTurn`）与 `appearance:changed` | asar + 探针日志 |
| 桌面操作（实测） | `desktop.listOperations()` 只公示 3 个（`app/getVersion`、`app/health`、`app/getOnboarding`），但 `desktop.invoke` 实际还接受 `session/list`、`session/get`、`session/open`；`session/messages`、`approval/*`、`session/turns` 返回 `NOT_FOUND` | 探针日志 |
| `session/open` 语义 | 参数是**裸字符串** `args: [sessionId]`；成功后返回该会话与消息窗口（`messageStart/End`），即可做会话级聚焦 | 探针日志 |
| 审批可控性 | `approval/respond`、`approval/pending`、`approval/list` 全部未暴露 → 插件**无法**代用户批准/拒绝 | 探针日志 |
| `usage.listTurns` | 跨会话返回每 turn 计数与 `sessionId`/`sessionTitle`/`turnId`，可直接用于今日账本 | 探针日志 |
| `session.read.own` 边界 | 实测 `pi.session.list` 返回 `{"items":[]}`（只能看到插件自己导入的会话） | 探针日志 |
| 插件热更新 | 改代码保存即热重载（0.2.0 → 0.7.0 全自动）；**扩权限必须显式重载** | 探针日志 |
| WAL 并发 | 15 s 内 143 次只读查询：`busy=0`，p50 1.4 ms / p95 2.5 ms / max 25 ms | 实测 |
| 跳转 | **没有 URL scheme**（`CFBundleURLTypes` 不存在），只能激活 app，会话级定位要靠插件或 AX | `Info.plist` |
| 审批持久化 | 不落库；`audit_log` 只有 `tool_execute` | sqlite |
| 进程形态 | 主进程 + Electron helpers + `sidecar.js`，**每会话无独立进程**，`ps` 只能看到 `PI-Desktop` | `ps`、Resources |
| 现有 pi CLI 集成 | 走 `~/.pi/agent/extensions/open-island.ts`，与 PI Desktop 数据源不同，互不复用 | `PiHooks.swift`、`PiExtensionInstallationManager.swift` |

三个直接推论：

1. **进程级发现不可用**。`ActiveAgentProcessDiscovery` 只能在 `piAgentVariant`
   （`binaryName == "pi"`）里识别 CLI，识别不到 PI Desktop；也不需要为它加，
   因为一个 PI Desktop 进程对应 N 个会话。
2. **插件读不到会话列表，但能通过桌面操作绕过去**。`pi.session.*` 受 `session.read.own`
   限制（实测返回空列表）；而 `desktop.invoke("session/list")` 能拿到全部会话 —— 代价是
   `desktop.control` 这个高风险权限，且该操作**未在 `listOperations()` 里公示**，
   属于可用但无契约的口子，只能当增强、不能当唯一依赖。
3. **SQLite 是唯一完整的事实来源**。会话、消息、工具名、turn 状态、token 都在里面，
   且 WAL 持续写入，外部只读连接可看到最新提交。

## 3. 路径选型

| 方案 | 数据完整度 | 延迟 | 稳定性 | 权限面 | 结论 |
|---|---|---|---|---|---|
| A. 纯插件（`pi.events` + `desktop.invoke`） | 中高（会话列表要靠未公示的 `session/list`） | 高 | 低（操作集未公示，版本间可能变） | 大（`desktop.control` 高风险） | 可作增强，不作主路径 |
| B. 纯 SQLite 只读轮询 | 高（全字段） | 1–3 s | 中（私有 schema 会漂） | 无（不碰插件权限） | 可独立成立 |
| C. 混合：B 读 + A 推/控 | 高 | 高 | 高（互为降级） | 中 | **选定** |

混合的边界很清晰：

- **B 负责「事实」**：会话列表、当前工具、turn 状态、token、todo 进度；
- **A 只负责三件事**：① 事件秒推（省掉 1 s 轮询延迟）；② 会话级聚焦
  （`desktop.invoke("session/open", [sessionId])`，实测可用）；③ 未来若拿到审批能力再说
  （当前**确认不可用**，见 §10）；
- 插件缺失 / 未启用 / 报错 → 自动退回 B-only，功能降级但不报错。

## 4. 目标架构

```
                  ┌───────────────────────────── PI Desktop (Electron) ─────────────────────────────┐
                  │  renderer  ──  agent-runtime/sidecar.js  ──  pi.sqlite (+WAL)                    │
                  │        │                                            │                            │
                  │        └── plugin host (Node)  ◀── pi.events ───────┘                            │
                  └────────┬───────────────────────────────┬────────────────────────────────────────┘
                           │ NDJSON (unix socket)          │ 只读 SQLite（1 s 轮询 + WAL mtime 门控）
                           ▼                               ▼
   ~/Library/Application Support/OpenIsland/bridge.sock   PiDesktopSessionStore (Swift, Core)
                           │                               │
                           └────────► BridgeServer ◄───────┘
                                        │
                                        ▼
                              AgentEvent → SessionState → AppModel → 刘海
                                        ▲
                                        │ command.sock（聚焦/审批回执）
                              Pi Desktop plugin ◄────────── Open Island
```

组件职责：

| 组件 | 层 | 职责 |
|---|---|---|
| `PiDesktopSessionStore` | Core | 只读打开 `pi.sqlite`，增量读 sessions/turns/messages/todo，产出快照与 delta |
| `PiDesktopIntegrationManager` | Core | 安装/卸载插件、检查 app 与 DB 状态、ledger 文件 |
| `PiDesktopHooks` 模型 | Core | 插件上报的 payload（与 `DSHHooks.swift` 同构） |
| `BridgeServer.handlePiDesktopHook` | Core | 校验、合并两个数据源、emit `AgentEvent` |
| `PiDesktopDiscoveryCoordinator` | App | 轮询节奏、活性判定、心跳、退出清理 |
| `open-island-pi-desktop.js` | App/Resources | PI Desktop 插件：事件推送 + 命令通道 |
| `PiDesktopFocusService` | App | 激活 app / 调用插件聚焦 |

## 5. 数据模型

```swift
/// PI Desktop 与 pi CLI 是两个运行时，工具枚举必须分开。
public extension AgentTool {
    // AgentSession.swift: brandColorHex / displayName 增加 case
    case piDesktop = "piDesktop"
}

public struct PiDesktopSessionSnapshot: Equatable, Codable, Sendable {
    public var sessionID: String
    public var title: String?
    public var projectPath: String?
    public var workspaceName: String?
    public var providerID: String?
    public var modelID: String?
    public var mode: String              // agent / chat
    public var permissionMode: String    // ask / accept-edits / auto / inherit
    public var phase: SessionPhase       // running / waitingForApproval / waitingForAnswer / completed
    public var summary: String?          // 最近一条 assistant 首行，截断 120 字符
    public var currentTool: String?      // 最近一条 role=tool 的 tool_name
    public var todoCompleted: Int?
    public var todoTotal: Int?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var isSubagent: Bool
}

public struct PiDesktopTodayTokens: Equatable, Codable, Sendable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var sessionCount: Int
}
```

`AgentTool.piDesktop` 与现有 `.pi` 并存：

| | `.pi` | `.piDesktop` |
|---|---|---|
| 显示名 | Pi | Pi Desktop |
| 数据源 | `~/.pi/agent/sessions` + extension hook | `~/.pi-desktop/pi.sqlite` + 插件 |
| 生命周期 | 每会话一个 CLI 进程 | 应用级，多会话 |
| 品牌色 | `#a3e635`（lime） | `#F4F1EA`（灰白，见 §13） |

## 6. 桥协议

新增命令，结构照抄 DSH（`BridgeTransport.swift` 的 `CommandType`）：

```json
{"type":"command","command":{
  "type":"processPiDesktopHook",
  "piDesktopHook":{
    "event":"snapshot",                     // snapshot | sessionStart | activity | approval | sessionEnd
    "sessions":[ /* PiDesktopSessionSnapshot */ ],
    "session": null,
    "todayTokens":{"totalTokens":0,"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"sessionCount":0},
    "timestamp": 1762092000000
  }}}
```

Swift 侧：

```swift
public struct PiDesktopHookPayload: Equatable, Codable, Sendable {
    public enum Event: String, Codable, Sendable {
        case snapshot      // 周期全量，兼作迟到启动的追赶
        case sessionStart
        case activity
        case approval      // 审批/提问开始或结束
        case sessionEnd
    }
    public var event: Event
    public var session: PiDesktopSessionSnapshot?
    public var sessions: [PiDesktopSessionSnapshot]?
    public var todayTokens: PiDesktopTodayTokens?
    public var timestamp: Date
}
```

- 插件走 socket 时会先收到 `hello` 再收到 `response`，必须只认 `type: "response"` 的行
  （这是 OpenCode 插件踩过的坑，见 `open-island-opencode.js` 的注释）。
- 插件不可用时，Swift 侧用同一份 `PiDesktopSessionSnapshot` 直接 emit，协议不分支。

## 7. 事件与状态映射

| PI Desktop 事实 | SessionPhase | 岛上表现 |
|---|---|---|
| `turn.started` / `turns.status = running` | `.running` | 行前缀呼吸点 + 当前工具 |
| `approval.requested`（仅插件在线） | `.waitingForApproval` | 展开通知层，按钮可用性见 §10 |
| `input.requested`（仅插件在线） | `.waitingForAnswer` | 显示问题摘要 |
| `turn.completed` 且无新 turn | `.completed` | 3 s 后折叠，保留 90 s |
| `turn.failed` / `error` | `.completed` + 错误摘要 | 红色角标 |
| `session.archived` / `deleted` / app 退出 | sessionEnd | 从列表移除 |

## 8. 活性判定与轮询节奏

- **门控**：每 1 s `stat` 一次 `pi.sqlite-wal` 的 `mtime` 和 `size`；没变就不查库，
  空闲时 CPU 开销接近于零。
- **轮询**：有 `turns.status = 'running'` 或 WAL 刚变化 → 1 s；全部静默 → 3 s；
  PI Desktop 未运行 → 停止轮询（只留进程检测，5 s 一次）。
- **心跳**：活跃会话每 15 s 发一次 `sessionHeartbeat`；90 s 无更新 → `detached`；
  app 退出（`NSRunningApplication` 消失）→ 全量 `sessionEnd`。
- **快照**：每 10 s 或启动后首轮，发一次全量 `snapshot`，保证 Open Island 重启能补齐。
- **去重**：`session.id` 为主键；`turns.id` 为 turn 去重键；同一会话的旧快照不覆盖
  更新的 `updated_at`。

## 9. 今日 token 账本

- 逐 turn 累加 `input_tokens + output_tokens`；`cacheReadTokens` 单列，
  **不计入 total**（对齐 DSH 与现有卡片口径）。
- `usage_json.aggregation = "aggregate"` 时只取顶层计数，**不要再加 `operations[]`**，
  否则重复计数。
- 按本地日切分：`Calendar.current.startOfDay`，跨 DST 与 23/25 小时日都要有单测。
- 无 `usage_json` 的 turn 退回 `input_tokens/output_tokens` 两列。
- 落盘 `~/Library/Application Support/OpenIsland/pi-desktop-today-tokens.json`，
  带 `version` 字段；口径变更时 bump，避免旧文件污染当日总量（DSH 的 `LEDGER_VERSION` 同理）。

## 10. 审批与提问的能力边界

事实（P0 已核实）：

- `approval.requested/resolved` 只存在于运行时事件流，**不落库**（`audit_log` 只有 `tool_execute`）；
- `desktop.invoke("approval/respond")`、`"approval/pending"`、`"approval/list"` 全部返回
  `NOT_FOUND: operation is not exposed` —— **插件没有审批读写能力**；
- `session:approval*` 之类事件也不在插件事件表里。

因此结论定为**只读降级**，不做按钮：

- 若将来某个版本把 `approval/*` 暴露出来，再按「探测 → 启用按钮」的路径加；
- 在探测为否时，岛上不显示批准/拒绝按钮，只显示「需要审批（在 PI Desktop 中处理）」；
- 绝不出现「按钮点了没反应」的假交互。

这条结论会直接影响产品文案：PI Desktop 的审批是**提醒型**，不是**操作型**。

## 11. 跳回

| 级别 | 手段 | 可用性 |
|---|---|---|
| L1 基础 | `NSRunningApplication(bundleIdentifier:)` 激活 app | 一定可用 |
| L2 会话级 | `desktop.invoke("session/open", [sessionId])`（**裸字符串**参数，非对象） | **P0/P4 实测可用**：切到目标会话、并取消 app 隐藏；但**不会把 app 提到最前**，必须先 `activate` |
| L3 兜底 | AX 遍历窗口选中会话 | 需要辅助功能授权，默认关闭 |

L1 必须实现（无插件时唯一手段）；L2 在插件已安装并授权时启用，失败自动退回 L1；
L3 只做 Lab 实验开关，不进主路径。

注意 `session/open` 的参数形状是踩过的坑：传 `{id}` 或 `{sessionId}` 都返回
`Session not found`，只有 `args: ["<id>"]` 才成功，实现时要在插件里固定这一形状。

另外两个实测结论：

- 插件来源**会**带 `selectSessionId`。asar 里 `if (source === "plugin") return {...}`
  的提前返回只作用于 `session/create` / `session/fork`；`session/open` 分支无论如何都带
  `selectSessionId`，实测侧边栏会切到目标会话。
- `session/open` 会取消隐藏，但不会抬升窗口层级。跳转实现必须先
  `NSRunningApplication.activate`，否则用户看到的是「app 在后台被选中」。

## 12. 安装、发现与设置

- 安装：把插件写到 `~/.pi-desktop/plugins/dev/local.openisland.pi-desktop-bridge/`
  （`manifest.json` + `main.js`），首次需要用户在 PI Desktop「扩展」页点
  **「加载本地插件」并选中该目录**；加载后会出现在 `registry.json`（`source: "dev"`）。
- 更新语义（P0 实测）：**改代码保存即热重载**，无需重新选目录；**扩权限必须显式重载**
  （重载会重新走一次授权）。所以首次安装的权限清单要一次写全，避免二次点击。
- 状态检测（设置页展示四项）：
  1. PI Desktop 是否安装（`/Applications/PI-Desktop.app`）；
  2. 是否运行（`NSRunningApplication`）；
  3. `pi.sqlite` 是否可读（`PRAGMA user_version` 是否在支持区间）；
  4. 插件目录是否存在 / 是否在 `registry.json` 里 enabled / 已授予哪些权限。
- 卸载：删插件目录 + 删 ledger；不动 PI Desktop 自身配置。
- 失败文案：区分「未安装」「未运行」「schema 不支持（期望 24，实际 N）」「插件未启用」。

## 13. 配色：灰白（偏白）

设计意图：PI Desktop 是「工具感、页面感」的产品，配一套**低饱和、偏白的银灰**，
在黑色刘海背景上像一张纸；不抢主文案，也不和 Claude 橙、Codex 蓝、Gemini 绿撞色。

| Token | Hex | 用途 | 在 `#0A0A0B` 上对比度 |
|---|---|---|---|
| `piDesktop.accent` | `#F4F1EA` | agent 点、徽章 tint、迷你曲线 | 17.5:1 |
| `piDesktop.accentStrong` | `#FFFFFF` | 运行中的高亮环 / 焦点 | 19.8:1 |
| `piDesktop.accentMuted` | `#CFC9BE` | 次级标签、模型名 | 12.0:1 |
| `piDesktop.accentSubtle` | `#948E83` | 时间戳、元信息 | 6.1:1 |
| `piDesktop.onAccent` | `#1B1A18` | 浅底上的文字（15.4:1） | — |
| `piDesktop.fill` | `rgba(244,241,234,0.10)` | 徽章底、行 hover | — |
| `piDesktop.hairline` | `rgba(244,241,234,0.28)` | 1 px 描边 | — |
| `piDesktop.glow` | `rgba(244,241,234,0.20)` | 运行态呼吸光 | — |

使用规则：

- **Do**：只用于 ≤16 px 的点、线、图标、徽章描边；作为「身份色」而不是「文字色」。
- **Do**：浅色设置页里改用 `accentMuted` / `onAccent`，纯白在浅背景上不可见。
- **Don't**：不要用纯白做大面积填充（会和岛上正文抢层级）。
- **Don't**：不要给 `#F4F1EA` 加饱和渐变；需要层次就用透明度 0.10 / 0.20 / 0.28 三档。
- 落地：`AgentTool.piDesktop.brandColorHex = "#F4F1EA"`，其余 token 放
  `IslandDesignPalette`，由 `IslandPanelView`（行 tint）、`PixelMascotLayer`
  （象素召唤颜色）、通知层共用。

## 14. 代码触点清单

新增：

| 文件 | 作用 |
|---|---|
| `Sources/OpenIslandCore/PiDesktopHooks.swift` | payload 模型（照 `DSHHooks.swift`） |
| `Sources/OpenIslandCore/PiDesktopSessionStore.swift` | SQLite 只读读取 + 增量游标 |
| `Sources/OpenIslandCore/PiDesktopIntegrationManager.swift` | 插件安装/卸载、状态、ledger |
| `Sources/OpenIslandApp/PiDesktopDiscoveryCoordinator.swift` | 轮询、活性、心跳 |
| `Sources/OpenIslandApp/Resources/open-island-pi-desktop.js` | PI Desktop 插件 |
| `Tests/OpenIslandCoreTests/PiDesktopSessionStoreTests.swift` | 用临时 sqlite fixture |
| `Tests/OpenIslandCoreTests/PiDesktopHooksTests.swift` | 编解码 + 账本 |
| `Tests/OpenIslandCoreTests/PiDesktopLedgerTests.swift` | 本地日 / DST / 去重 |

修改：

| 文件 | 改动 |
|---|---|
| `Sources/OpenIslandCore/AgentSession.swift` | `AgentTool.piDesktop`、`displayName`、`brandColorHex` |
| `Sources/OpenIslandCore/BridgeTransport.swift` | `CommandType.processPiDesktopHook` + 编解码 |
| `Sources/OpenIslandCore/BridgeServer.swift` | `handlePiDesktopHook` 分发 |
| `Sources/OpenIslandCore/AgentEvent.swift` | `piDesktopSessionUpdated` / `piDesktopTodayTokensUpdated` |
| `Sources/OpenIslandCore/SessionState.swift` | 快照应用与去重 |
| `Sources/OpenIslandApp/AppModel.swift` | coordinator 生命周期、今日 token 合并 |
| `Sources/OpenIslandApp/Views/SettingsView.swift` | 集成状态面板 |
| `Sources/OpenIslandApp/IslandDesignPalette.swift` | 灰白 token |
| `Sources/OpenIslandApp/Views/IslandPanelView.swift` | 行 tint（`brandColorHex` 已自动生效，需检查对比度） |
| `docs/product.md`、`README.md` | agent 矩阵新增一行 |

## 15. 分阶段实施

| 阶段 | 内容 | 验收 | 预估 |
|---|---|---|---|
| P0 Spike | 探针插件：事件目录、桌面操作集、`usage.listTurns` 结构、WAL 并发 | **已完成**，结论见 §2 与 §18 | ✅ |
| P1 读取层 | `PiDesktopSessionStore` + 单测（临时 DB fixture，含 WAL） | 能从真实库读出 5 个会话、49 个 turn，字段齐全 | 1 d |
| P2 桥接 | 协议 + reducer + coordinator，先用脚本伪造 payload | 刘海出现 PI Desktop 行，状态随 turn 变化 | 0.5 d |
| P3 Token | 账本 + 今日卡片 | 与直接 SQL 求和一致（抽样 3 天） | 0.5 d |
| P4 插件 | 事件推送 + 审批（若支持）+ 聚焦 | 插件停止后自动降级，不报错 | 1 d |
| P5 视觉 | 灰白 token + 徽章 + 设置页 | 浅色/深色背景都可读，对比度达标 | 0.5 d |
| P6 收尾 | 文档、README 矩阵、卸载路径、release note | `swift test` 全绿 | 0.5 d |

## 16. 测试矩阵

| 层 | 用例 |
|---|---|
| 单测 | payload 编解码 round-trip；未知 `event` 值降级；账本本地日边界、DST、`aggregation=aggregate` 不重复计数 |
| 单测 | `PiDesktopSessionStore`：fixture DB 的增量游标、`deleted_at` 过滤、`streaming` 消息、schema 版本不匹配时返回 nil |
| 单测 | `SessionState`：快照乱序到达、重复快照、`waitingForApproval` → `actionableStateResolved` |
| 集成 | socket harness 发 fixture 序列 → 断言 SessionState 终态；插件进程被杀 → 心跳超时后 detached |
| 手测 | 真机：开 3 个会话并发跑；关 PI Desktop；重启 Open Island 补齐快照；浅色/深色外观检查 |

## 17. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 私有 schema 漂移 | 读不到 / 读错 | 每次读校验 `user_version`（当前 24）；只 SELECT 明确列；失败即降级为「仅显示 app 运行中」 |
| WAL 并发 | `SQLITE_BUSY` | 实测 15 s / 143 次查询 `busy=0`，p50 1.4 ms。仍按 `READONLY` + `busy_timeout=200 ms` + 短查询实现，失败跳过本轮 |
| 未公示的桌面操作 | `session/list`、`session/open` 在版本升级后可能消失 | 只在插件路径使用，且每次启动做能力探测；失败退回 SQLite 读取 + app 激活 |
| `session/open` 参数形状反直觉 | 聚焦静默失败 | 固定 `args: ["<id>"]`；有单测覆盖；返回 `NOT_FOUND` 时退回 L1 |
| 与 pi CLI 会话重复 | 列表里出现两份 | 两套 tool 枚举分开；PI Desktop 只认 `pi.sqlite`，CLI 只认 `~/.pi/agent` |
| 隐私 | 消息内容进日志/上传 | 只取首行 ≤120 字符，不落盘原文；日志打码；无网络上报（local-first） |
| 插件权限过大 | `desktop.control` 高风险 | 默认不装插件即可用；装时在设置页显示权限清单 |
| 事件目录不公开 | 推送失效 | 以 SQLite 为准，事件只是加速；失效不影响正确性 |

## 18. P0 结论（2026-11-02 实测）

探针：`local.openisland.pi-desktop-probe`（只读，跑完即删），PI Desktop 0.21.0，
宿主 `protocolVersion 11`。

| 问题 | 结论 |
|---|---|
| 插件能收到哪些事件 | 仅 `session:activated`、`session:modelChanged`、`session:turnEnded` + `appearance:changed`、`workspace:changed`；RACP 的 `turn.*`/`tool.progress`/`approval.*` **不广播** |
| 审批能否代理 | **不能**：`approval/respond`、`approval/pending`、`approval/list` 均 `NOT_FOUND` |
| 能否读到会话列表 | `pi.session.list` → `{"items":[]}`；`desktop.invoke("session/list")` → 全量（title/modelId/permissionMode/messageCount/updatedAt/source） |
| 能否会话级聚焦 | **能**：`desktop.invoke("session/open", ["<id>"])`，返回打开的会话与消息窗口 |
| 会话详情 | `session/get` 接受 `{id}`，返回会话 + 消息窗口 + compaction 信息；`session/messages` 不存在 |
| token | `usage.listTurns` 跨会话返回 `turnId`/`sessionId`/`sessionTitle`/`inputTokens`/`outputTokens`/`cacheReadTokens`/`reasoningTokens`/时间戳，可直接做账本 |
| WAL 并发 | 15 s / 143 次只读查询：`busy=0`，p50 1.4 ms，p95 2.5 ms，max 25 ms |
| 热重载 | 改代码保存即重载；**扩权限必须显式重载** |

仍未验证（不阻塞 P1）：

- `session:turnEnded` 的真实载荷 —— 静态确认存在，探针窗口内没有完成一次 turn；
- `approval.requested` 的运行时形状 —— 同上；
- `session_todo` 的更新时机 —— 表里有 8 行，未观察到变更；
- `activeTurn` 字段在真正运行 turn 时的取值。

P1 起以 SQLite 为事实源，事件仅作加速，因此这些空项不会阻塞主线。

## 19. 文档与发布

- `docs/product.md` agent 矩阵加一行：PI Desktop / Supported / 宿主集成（SQLite 只读 + 可选插件）。
- `README.md` 支持矩阵同步（release 时以它为准）。
- 本方案落地后移到 `docs/exec-plans/completed/`。
- 不做 release note 的话，至少在 PR 描述里写清楚「PI Desktop 需要 0.21.0+」。

## 20. 实施记录

| 阶段 | 提交 | 验证 |
|---|---|---|
| P1 读取层 | `fa9315f` | 10 个 fixture 测试；真机 5 会话 / 9 turn / 760,512 tokens 与 SQL 一致 |
| P2 桥接 | `9636aa4` | 跑通 `processPiDesktopHook`；启动日志 `published 5 PI Desktop session(s)` |
| P3 token | `9850ae1` | 今日账本 `908,786 / 3 会话`；aggregate 不重复计数，按 turn id 去重 |
| P4 跳转 | `73c5c4a` + `d4b5616` | 真实 focus：`ok=true`、日志 `focused …`、窗口切到目标会话；补上 activate |
| P5 视觉 | `0e04e66` | paper token + 徽章 fill/hairline；对比度 17.5:1 |

合并后 `main` = `bc31a14`，全量 **666 tests / 85 suites** 绿。

仍未做（刻意留白）：

- 插件不推送事件：`session:activated` / `session:turnEnded` 只用于确认存活，
  会话与 token 仍由 1 秒轮询读取，避免与轮询状态互相覆盖；
- README 支持矩阵留到发版时统一更新（`docs/product.md` 已加行）；
- 审批只读，不可代点。
