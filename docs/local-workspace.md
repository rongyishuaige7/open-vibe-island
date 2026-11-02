# 本机工作区与版本收拢记录

2026-10-28 清理后，只保留一个源码目录：

```text
/Users/rongyi/Developer/open-vibe-island-dsh-local
```

它已从关联工作区提升为独立主仓库，`.git` 是此目录内的真实目录。
日常开发继续在这里进行，无需恢复已经删除的 `open-vibe-island` 主目录。
本次整合分支为 `chore/consolidate-current-runtime`，代码整合提交为 `0e93720`，
已推送到 `origin`。旧分支继续保存在 Git 中，不再各自占用一份项目目录和构建缓存。

## 为什么保留这个版本

清理前，正在运行的开发 App 与 `dsh-local` 构建具有相同的 Mach-O UUID：
`C96F1AC2-E4D0-3423-97D3-EFAE9D9BAB10`。因此，使用它的源码状态作为个人版本基线，
而不是根据文件夹修改时间判断版本新旧。

这份基线包含 DSH、AGY、KEEPER、多个 Codex home 的发现逻辑、会话标题、模型标签、
像素角色、今日 token 统计，以及个人版的会话发现与终端跳转修复。
本次另行合入已有审计分支的稳定性修复；没有进行额外的上游功能升级。

## 各旧目录的具体差异和去向

下表中目录名均位于 `/Users/rongyi/Developer/` 下；短名称省略共同前缀
`open-vibe-island-`。

| 原目录 | 清理前版本及差异 | 处理结果 |
| --- | --- | --- |
| `open-vibe-island` | `main` / `b50f87a`，较早的上游主线基线，缺少后续个人功能与修复 | Git 对象、分支、归档迁入保留目录并校验后，删除旧主目录 |
| `dsh-local` | `19d96ef`，当前运行 App 的来源；另有 2 个未提交文件，修复 Claude Pro 消息重复计数 | 保留目录；原修改和测试提交为 `e63d7dc`，再合并审计修复至 `0e93720` |
| `local` | `1e8b7ee`，DSH 加入前的个人版本；另有 10 个未提交文件，涉及标题、AGY、后台 transcript 预载和 Claude Pro 统计 | 10 个文件的全部补丁均在整合结果中验证存在；保存原始快照后删除目录 |
| `dsh` | `a49de08`，最初 4 个 DSH 提交：接入会话和今日 token、兼容可选元数据、补载历史、限制启动读取日志尾部 | 同等功能已适配进个人分支，且有更多后续修复；删除目录、保留分支 |
| `display-polish` | `8323835`，2 个独立设计提交：角色提示未读完成/等待、主题优先的会话行及模型标签；另有 4 个未提交文件尝试折叠 Idle 会话 | 作为可选设计保存在分支与 WIP 快照中，删除目录；未完成的折叠逻辑未合入当前界面 |
| `open-vibe-island/.worktrees/audit-hardening` | `8bdfa84`，15 个稳定性、安全与构建相关提交 | 合入保留版本并验证后删除工作区 |
| 第一批 10 个功能目录 | HEAD 均是 `19d96ef` 的祖先，功能已经包含在当前运行版本中 | 删除目录，保留所有原分支 |

相较早期 `dsh`，保留版本还有活跃轮次过滤、实际对话标题、按本地日期重置 token 基线、
从当日事件恢复 token、AGY 详情折叠、AGY wrapper PTY 解析和 Ghostty/tmux 跳转修复。
因此没有必要再保留一份早期 DSH 工程。

`display-polish` 的 Idle 折叠草稿只修改了模型和面板高度，列表视图尚未接入对应分组。
直接合入会带来显示不一致。其 2 个已提交设计改动也会改变当前界面，因此本次保留为
可恢复的设计分支，没有用它覆盖正在使用的界面方案。

第一批删除的 10 个目录后缀为：`agent-icons`、`conversation-titles`、`fix-codex-home`、
`hide-unknown-terminal`、`localize-session-text`、`pixel-mascots`、`session-model`、
`skip-warp-keystroke-test`、`stale-sessions`、`today-tokens`。
临时整合目录 `.worktrees/consolidate-runtime` 也已移除。

## 本次合入的修复

- 为 hooks、终端跳转中的 AppleScript 和 CLI 子进程增加超时，避免调用无限等待。
- Bridge 不再抢占仍有活跃服务的 socket；发送决策失败时保留待处理提示。
- OpenCode 按响应 envelope 解析命令结果，限制调试日志；无法安全解析原配置时停止改写。
- 恢复旧 Claude 元数据时保持兼容；发现恢复的 Codex 会话时合并状态，避免覆盖已有状态。
- 周期性对账使用 iTerm 快照，同时保留个人版后台 transcript 预载。
- Watch 状态读取保持线程安全，刷新配对和连接状态、清理待处理卡片，并限制配对尝试频率。
- Gemini 长完成文本去重改为 O(n log n)，并跟踪 `Package.resolved` 以固定依赖解析结果。

冲突解决保留了个人版 Bridge observer 的事件计数、线程安全 Watch count provider，
以及仅在显式启用时运行真实 Warp 按键测试的约定。

## 源码和正在运行的 App

当前安装并运行的开发 App 位于：

```text
/Users/rongyi/Applications/Open Island Dev.app
```

本次没有重启 App、替换安装包或重新安装 hooks。清理结束核对时 PID 仍为 `89392`，
构建 UUID 与原版本一致。最终源码已经包含新合并的修复，完整测试和构建通过；
这些代码修改需要下次重新构建并启动 App 才会生效。
仅用 `open` 再次打开现有 App 不会刷新其中的二进制。

`/Applications/Open Island.app` 是另外安装的旧 Release 包，未包含在这次项目目录清理中。
用户配置、会话数据和独立安装的 hooks 也不属于被删除的项目副本。

## 备份和恢复依据

所有维护归档均保留在唯一项目目录内部：

```text
.git/maintenance-archives/20261028_095030/
```

其中包括清理前和最终删除前的 Git bundle、原始工作区清单、3 份未提交补丁、原始修改文件、
打包 App/ZIP、Harness 截图与报告、依赖锁文件、测试日志和 Git 迁移验证记录。
原归档的文件 SHA256 和符号链接目标均在删除旧副本前核对一致。

原始未提交状态还保存为以下本地分支，且包含在最终恢复 bundle 中：

| 本地恢复分支 | 快照提交 |
| --- | --- |
| `archive/20261028-display-polish-wip` | `75339af` |
| `archive/20261028-local-wip` | `a01ead4` |
| `archive/20261028-dsh-local-wip` | `4b78227` |

恢复分支未推送到远端，当前源码整合分支已推送。
这些快照与原有功能分支允许以后按需提取改动，不需要恢复多个常驻项目目录。
维护归档位于 `.git`，普通 clone 不会复制它；迁移整份本地项目时应一并保留。

## 最终验证

- 在提升后的最终路径运行 `zsh scripts/harness.sh ci`：本地化检查、文档检查、
  623 项 Swift 测试（78 个 suite）和 Swift 构建全部通过。
- `git fsck --full --no-dangling`、最终恢复 bundle 校验、全 refs 对比均通过。
- `git worktree list` 只登记一个工作区，Developer 下只剩一个相关项目目录。
- 16 个原工作区收拢为 1 个，目录占用由约 12.99 GiB 降为 0.92 GiB；
  保留了恢复材料和一份可继续使用的构建缓存。

详细执行记录见[已完成的收拢计划](./exec-plans/completed/2026-10-28-worktree-consolidation.md)。
