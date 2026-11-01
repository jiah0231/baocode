# 定制版 Windows 自动更新

专属通道只读取 `jiah0231/baocode` 的公开 GitHub Releases；不会用上游版本覆盖定制功能。首次需安装一次支持此通道的 **Setup 安装版**。以后默认启动 10 秒后检查、每 5 分钟复查，后台下载完整安装包，提示“重启更新”。可以稍后更新/跳过/在设置中关闭。不会自行重启或跳过运行中 agent、未保存文件的退出确认。

## 发布前配置（需要仓库所有者授权）

- 独立 Ed25519 密钥，私钥为 base64 编码的 32 字节 seed。
- Repository Variable `BAOCODE_CUSTOM_UPDATE_KEY`：相应的 base64 公钥，编译进应用。
- Repository Secret `BAOCODE_CUSTOM_UPDATE_SIGNING_KEY`：私钥 seed。受保护 Environment/reviewer 是未来可选硬化，不是首次启用条件；本 workflow 不自动创建 Environment。
- 仓库及 Release 必须公开以便无令牌下载。不要在应用内保存 GitHub token。
- 密钥备份由所有者安全保管；丢失密钥会导致已安装应用不能再信任新包，需要手动重装。公钥变更需要旧钥签过渡包，不能直接换掉。

代码不会生成密钥。未配置公钥时构建命令拒绝启用；直接构建缺钥 custom 版本时更新服务不可用，不回退到上游。custom 模式忽略 `BAOCODE_UPDATE_URL`，且忽略清单中的强制更新字段。

## 构建与发布

1. 每次交付同时增加 `pubspec.yaml` 的 version 和 `lib/update/version.dart` 的 appVersionString；首次为 `1.7.3+24`，后续 build 号严格递增。不能重用版本号。
2. 首轮无需改 main：先让普通 `fix/codex-parity-windows-20261101` 分支 CI 验证候选。所有者明确发布时，创建 `custom-publish/v<完整版本>/<完整已验证SHA>` 分支，指向该 SHA。workflow 使用 **create 事件**（不是假设创建分支会产生 push），只接受精确版本/SHA 名称、固定仓库和 owner。两个 job 都 checkout 不可变事件 SHA，普通代码 push 不发布。
   可选 workflow_dispatch 入口默认 `publish=false`，还必须填写 `expected_commit`；GitHub 要求该 workflow 存在默认分支后才可手动 dispatch。不能为了此入口擅改 main。
3. workflow 在同一提交上运行 analyze、更新/退出测试、Codex/性能回归，构建并启动 smoke-test；只有全部成功，发布 job 才会取得私钥。
4. `tool/custom_release_manifest.dart` 验证版本与两份源码一致，用私钥签署版本、平台、字节数、SHA256，并自验签。私钥临时文件结束即删除，不打印。
5. 先创建唯一的 `custom-v<完整版本>` Release（如 `custom-v1.7.3+24`），上传 Setup，再公开它；最后上传/替换 `custom-stable` Release 的 `latest.json`。失败的测试或只构建的 commit 不会被应用发现。

固定清单：`https://github.com/jiah0231/baocode/releases/download/custom-stable/latest.json`

固定包：`https://github.com/jiah0231/baocode/releases/download/custom-v<版本>/BaoCode-<版本名>-setup.exe`

下载初始 URL 必须为上述仓库的 HTTPS、版本化 Setup 路径；重定向只允许 HTTPS GitHub Release CDN。保存后检查长度、SHA256、独立 Ed25519 签名；任何一项失败均不安装。断网保留 `.part` 供重试。只接受比当前版本更高的版本。

## 安装、恢复与限制

- Windows 用户级安装更新沿用原目录和安装模式；机器级安装仍可能弹 UAC。不关闭系统安全设置、不绕过 UAC/SmartScreen。
- portable 版本不能原地自动替换：需用 Setup 安装一次，恢复链接指向本 fork 的 Releases。
- 下载失败保留当前程序；启动安装失败阻止退出。拒绝 UAC 或安装未完成，下次启动报告失败并提供日志/手动下载链接；不声称 Windows 安装具备事务回滚。
- `custom-stable` 可暂时回指上个可信清单来停止分发；已装新版不会自动降级，需更高版本修复包。
- 本改动未新增 Windows Authenticode 证书，首次安装可能仍显示 SmartScreen；自动更新包的应用级签名是 Ed25519。
- 目前只支持此定制版 Windows standard edition；拒绝 `--channel` 组合。未改变学习气泡相关代码。

## 验证

CI：`flutter test test/update`；另以 custom dart-defines 运行 `test/update/custom_update_channel_test.dart`。真机还需验证旧 Setup→新 Setup、运行中 agent 取消退出、断网重试、用户/机器安装模式和 UAC 拒绝恢复。单元测试和启动 smoke-test 不替代真实安装升级验证。

发布中断后的安全恢复：当前脚本拒绝覆盖任何已有版本 Release。若已创建 draft/版本 Release 但 stable 尚未成功发布，先检查该 Release 的提交和资产 SHA256，再经授权补传相应已签清单；不要删除重建/替换版本包或盲目 rerun。也可增加版本号发布修复版本。

CI 还安装校验过 SHA256 的固定基线 Setup，再在 runner 临时用户级目录安装候选 Setup，验证 Windows 资源中的四段数字 ProductVersion、exe/AOT 文件哈希、保留测试数据和升级后启动。安装使用 silent/current-user 模式，不触发默认安装后自动启动；不测试用户机 UAC、交互重启或完整线上下载链。首次发布已通过旧 build 23→24 升级。后续基线固定为公开 `custom-v1.7.3+24` Release 的 Setup，SHA256 `853a407a383d8629dc51170f65817df0dbc200aeb54b54b1c59e393e910a79f2`，不依赖会过期的 Actions artifact 或 GitHub token。每次先核固定哈希再运行；基线被删除或替换时明确失败，不跳过安全校验。当前版本等于基线时验证同版本替换，后续 build 25+ 验证从 build 24 升级。
