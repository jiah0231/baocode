# Codex 功能适配核对

本次不是“全部适配完成”的声明。接口数量相近，不代表所有产品功能已端到端验证。

- 已补：从 Codex `skills/list` 动态读取当前项目已启用技能，显示在斜杠菜单，使用真实 `skill` 输入调用；收到技能变化通知后刷新。保留内置命令，兼容旧服务端不支持技能接口的情况。
- 已修：历史列表不再固定截断为 20 页，增加游标循环保护与会话去重。
- 同批修复：本地 Codex 路径设置、输出速度与活动状态由对应模块及测试覆盖；不等于自动安装 Codex，也不等于已完成 Windows/SSH/真实账号端到端测试。
- 尚未补齐：Codex 专用 Customize 编辑器、旧自定义提示词文件、Claude `/goal` 生命周期、细粒度扩展开关、Codex Bots、自动下载/更新 Codex、项目搬迁的持久化会话迁移。
- 不直接照搬：Claude 的 200K/1M 上下文选择器。Codex 应使用自己实际支持并报告的上下文能力。

尤其是会话迁移：核对的公开 `thread/metadata/update` 只支持 `gitInfo`，没有持久化 `cwd` 迁移字段。不能假装改一个请求就完成迁移，也不能贸然改写 Codex 的 SQLite/JSONL 数据。仍需独立设计并验证。

以下为逐项技术说明与官方协议来源。

# Codex integration: supported features and remaining differences

This fork's `feat/codex-agent` branch uses `codex app-server`, not the Claude
SDK, for Codex sessions. Implementing the same Dart capability interfaces is
not evidence that every product workflow has been tested with both engines.

## Changes in this parity patch

- **Skills in the composer:** enabled skills returned by `skills/list` for the
  current project are offered beside `/review`, `/init`, and `/diff`. Selecting
  `/skill-name` (or beginning a message with `$skill-name`) sends Codex's typed
  `skill` input with the server's actual skill path. Disabled skills and skills
  from another project are not offered. Built-in names take precedence.
  `skills/changed` reloads the list. An older server without this endpoint keeps
  the built-in commands; this does not install or enable a skill.
- **Catalog completeness:** history continues until `nextCursor` is exhausted,
  rather than stopping at 20 pages before filtering BaoCode sessions. Repeated
  cursors terminate safely and overlapping pages are deduplicated.

Skills are therefore not intrinsically a Claude-only feature. The old claim
that Codex can only have three hard-coded commands is no longer accurate.

## Remaining differences that must not be presented as complete parity

1. **Customize editor:** the existing editor still manages Claude-format
   `.claude` files, `CLAUDE.md`, hooks and plugins. It is not a Codex configuration
   editor. Codex skills discovery is supported in the composer, but this does
   not add editing for `AGENTS.md`, Codex rules, plugins or agent configuration.
2. **Custom prompt files:** this patch does not import or expand legacy Codex
   prompt files or Claude custom commands. Use native Codex skills for the new
   composer integration.
3. **Goal cards:** Codex plans are supported, but they are not Claude's `/goal`
   lifecycle. No synthetic `GoalReported` states are inferred from model prose.
4. **Fine-grained extension toggles:** the Customize switches are Claude
   settings. Codex's existing MCP server controls are separate; this patch does
   not pretend Claude skill/tool disable settings govern Codex. Enabled skills
   are read from Codex's own advertised state.
5. **Bots:** the bot subsystem still uses `ClaudeSdkGate` and creates Claude
   kernels. Porting its tool callbacks and lifecycle to Codex requires separate
   integration and tests, not changing the kernel ID alone.
6. **Installation:** a local executable override is distinct from bundling and
   updating Codex. No automatic Codex download/install is implied. Remote hosts
   must have their own Codex installation.
7. **Moving project history:** `CodexCatalog` does not implement `MovesSessions`.
   The inspected public `thread/metadata/update` schema updates `gitInfo`, not
   `cwd`. Merely resuming with another working directory is not established as
   a durable catalog migration. This patch does not rewrite Codex's SQLite or
   JSONL state. Do not assume project folder relocation migrates Codex history.
8. **Context-size menu:** Claude's 200K/1M selector is not copied to Codex.
   Codex reports its model's context capacity; an unsupported selector would
   give a misleading promise.

Output telemetry and executable settings have their own focused tests in this
patch. Native end-to-end behavior still depends on the installed Codex version;
unit tests with a fake transport do not prove account login, remote SSH, or
live model execution.

## Protocol references

- [Skills list parameters](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/SkillsListParams.json)
- [Skills list response](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/SkillsListResponse.json)
- [Typed skill input in turn/start](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/TurnStartParams.json)
- [Thread metadata update parameters](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/ThreadMetadataUpdateParams.json)

These are upstream main references inspected on 2026-11-01, not a guarantee
that every installed Codex version implements every endpoint.

## Windows test build

The dedicated `Codex parity Windows build` workflow runs analysis, focused
regression tests, a Windows x64 release build, and a 15-second startup smoke
check before uploading an installer and a portable bundle. It does not create a
release or publish updates. The test build disables upstream application updates
at compile time, without changing the user's saved update preference, so a
regular upstream release cannot silently replace these changes.

The installer uses BaoCode's existing installation identity and replaces an
existing installation; back up settings first. The portable bundle must remain
intact with its DLLs and `data` directory; `baocode.exe` is not a standalone file.
These artifacts are unsigned. The remote-server manifest is pinned to published
build `1.7.3.23-958eff42c6ca`; its server sources match this branch. A successful
startup smoke check is not a live Codex login/SSH/end-to-end session test.
