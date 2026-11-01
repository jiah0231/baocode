# Codex 功能适配核对

接口数量不代表产品功能一致。本分支把 Claude 与 Codex 的等价功能分别接到各自真实协议，**不把 Claude 文件格式或状态伪装成 Codex 支持**。旧版本 Codex 不支持某接口时应显示错误；不会假装写入成功。

## 本次补齐的产品入口

| 功能 | Codex 实现与边界 |
| --- | --- |
| Customize | 编辑器新增 Claude / Codex 切换。Codex 使用其实际 `CODEX_HOME`、`AGENTS.md`、`.agents/skills`、执行规则、agent TOML、hooks/plugins/MCP 配置，不写 `.claude`。SSH 使用目标主机的文件与配置路径。配置编辑通常在新会话生效。 |
| 技能与自定义命令 | 原生 `skills/list` + typed `skill` 输入；另支持用户 `CODEX_HOME/prompts` 和项目 `.codex/prompts` 的 BaoCode 提示词命令。项目同名提示词覆盖用户提示词；内置命令与原生技能优先。`$ARGUMENTS` 是文本替换，不执行 shell。 |
| `/goal` | 使用原生 `thread/goal/set/get/clear`，支持设置、暂停、继续、状态和清除；恢复会话时读取服务端目标。只有服务端 `complete` 才显示达成；普通回答结束不代表目标成功。 |
| 扩展开关 | 原生 `skills/config/write` 管理技能；`config/value/write` 管理 MCP server、工具允许/禁止名单和 plugin 启用状态。写入失败或被更高优先级配置覆盖须明确反馈。Hooks 等仍可编辑真实配置，不承诺所有 Claude 开关一一同名。 |
| Bots | 设置→手机中选择各机器人的 Claude/Codex 内核；两个内核分别保留对话，切换不删除历史。Codex 使用动态工具调用现有 BaoCode 能力门禁；本机会话级只读沙箱与工具限制，不能把全局用户配置关闭来实现隔离。移动端 v1 协议不变。 |
| 安装、路径、版本 | 设置→常规支持自定义路径、检查版本和明确确认后安装/更新官方完整软件包。验证 SHA-256、解包路径与版本，保留旧版本，不修改系统 PATH、不自动修改 SSH 主机。 |
| 项目搬家 | BaoCode 自有、版本化原子元数据按会话/主机/原目录/rollout 路径映射历史，新位置恢复使用 Codex 支持的 `cwd`。不改写 Codex 数据库、历史文本或旧文件路径。现有项目搬家 UI 仍仅限本地项目。 |
| 输出速度与活动 | 根据真实流式文本和生命周期上报；文本 token 数为估计时不冒充权威计数，不把非流式完成尾部算作输出速度。 |

同时保留历史分页完整性、游标循环保护、Windows 特殊字符路径启动与 diff 文件名修复。

## 不能混同的能力

- 不复制 Claude 的 200K/1M 上下文选择器。Codex 应报告自己的实际模型容量。
- 原生目标可能自动继续执行，`/goal pause` 暂停；blocked、usageLimited、budgetLimited、paused 都不是达成。
- 自定义提示词是 BaoCode 的显式功能，不声称是 Codex CLI 原生 slash-command 实现；不执行提示词中的 shell 替换。
- Bots 仍受其能力开关、后台节奏和用户选择约束；动态工具或必要隔离配置不受安装版本支持时应失败关闭，而非回退为无限制代理。为避免未知版本静默忽略安全开关，Bots 暂限定已审查的稳定 `0.166.x` 系列；其他版本、预发布版或无法识别的版本明确拒绝此模式，普通 Codex 聊天不受该限制。
- 托管安装只在用户确认后发生。已运行的进程继续使用原版本，新建本机会话使用选中路径。账户登录仍由 Codex 自己管理。
- 搬家映射只影响 BaoCode 的项目目录归属，Codex CLI 自己的旧历史列表可能仍保留原目录；历史绝对路径不被重写。无法查询已知 Codex 历史或无法持久化映射时，搬家不能假报成功。

## Protocol evidence

Reviewed against the official `openai/codex` source on 2026-11-01. Current upstream
capabilities must not be assumed present in an arbitrary older installed CLI.

- [App-server protocol](https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol/schema/typescript/v2): `ThreadGoal*`, `SkillsList*`, `SkillsConfigWrite*`, `ConfigRead*`, `ConfigValueWrite*`, `DynamicTool*`, `ThreadResumeParams`.
- [Configuration schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json): agents, skills, hooks, plugins, MCP and feature controls.
- [Native goal processor](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/thread_goal_processor.rs): actual status transitions and user origin.
- [Official installer](https://github.com/openai/codex/blob/main/scripts/install/install.ps1): complete release package layout and integrity verification.
- [Official releases](https://github.com/openai/codex/releases): managed installations resolve the latest stable release at the user's explicit request, never execute a mutable downloaded installer script.

## Verification and Windows test build

The dedicated branch workflow runs full static analysis and focused regression
suites, then an opt-in real official-package smoke test in temporary isolated
Codex storage: download, integrity verification, extraction, version check and
non-model app-server operations, isolated configuration/skill write-and-readback,
and restricted Bots thread configuration. It does not log into an account, send a model
turn, or use API billing. Fake-transport tests are not evidence of real account,
model-provider, SSH or mobile end-to-end execution.

It builds a Windows x64 installer and a complete portable bundle, checks release
startup for 15 seconds, records source identity and checksums, and uploads Actions
artifacts. It creates no release or tag and publishes no upstream update.
Upstream application updates are disabled in this custom build so they cannot
silently replace the changes; saved update preferences remain untouched.

The installer uses BaoCode's existing installation identity and replaces an
existing installation; back up settings first. Keep all portable DLLs and the
`data` directory beside `baocode.exe`. Artifacts are unsigned. The remote-server
manifest stays pinned to published `1.7.3.23-958eff42c6ca`; these client changes
use its existing process/file operations rather than require an unpublished
remote server. New Codex features require a compatible Codex installation on
each SSH host, independently of the local managed installation.
