# pi-desktop

[English](README.md) · [日本語](README_JA.md) · [Français](README_FR.md) · [Español](README_ES.md)

pi-desktop 是使用 [Pi coding agent](https://github.com/earendil-works/pi) 的 Flutter 桌面工作区，独立分支源自 [BaoCode](https://github.com/baocode-dev/baocode)，保留 GPL 许可证与上游声明。

本分支通过 Pi 的 JSONL RPC 和受支持的标准 API 原生供应商协议工作，避免额外的协议转换。同一会话保留上下文，并在供应商提供数据时按请求记录缓存读取与写入。稳定的提示词和会话上下文可能有助于缓存复用，但目前没有实测更高命中率；结果取决于供应商、模型、提示词和缓存 TTL，也不保证速度或成本优势。

在“设置 → 模型”配置自己的 HTTPS 供应商；兼容 newapi/sub2api 的渠道配置仍在测试中。密钥使用本应用独立的密钥服务，Pi 配置和会话位于 `<数据目录>/pi-agent/`。

## 更新与平台

随包 Pi 运行时初始锁定 **1.5.0**；独立更新器在启动后 30 秒首次检查官方 Pi 发布端点，之后每六小时检查，安装到用户数据目录并供新会话使用。桌面应用使用独立发布渠道和 Ed25519 签名验证；分支更新配置已设置，首次发布后才能使用。详见[自动更新](docs/auto-update.md)和[发布说明](docs/release.md)。

计划发布版本为 **0.1.2+3**，通过 Actions 构建 macOS 和 Windows 安装包；打包及安装仍待验证。本次不构建 Linux 安装包。仓库为 [zkldwxz/pi-desktop](https://github.com/zkldwxz/pi-desktop)。

支持本地项目。直接 SSH Pi 会话使用远程已安装的 Pi 和 Node，通过批处理/密钥认证；真实 SSH stub 对话已验证，更多远程工作流仍待验证。远程 IDE 服务或语言服务器不会自动保证安装。真实 Dart 语言服务器的诊断、悬停、补全与重命名已通过冒烟检查。

## 可复现的缓存对比

对比上游时，使用相同的供应商端点、模型、参数、账号、提示词、工具定义、工作区和对话顺序；记录版本、时间戳、缓存 TTL 与供应商设置。从冷缓存开始，在 TTL 内于同一会话重复相同轮次，多次独立运行，逐请求记录供应商报告的输入、缓存读取和缓存写入 token。按供应商的指标定义比较总量和分布，说明缺失数据、提示词或时序差异；不要根据单次运行推断普遍的命中率、延迟或成本优势。

## 开发

需要 Flutter **3.47.5**、Node.js **22.19+** 和相应 Flutter 桌面工具链；macOS 构建需要完整 Xcode。

```sh
flutter pub get
npm ci --prefix runtime/pi --ignore-scripts
flutter run -d macos  # 或 windows
```

“设置 → 常规”中的 `pi.path` 和 `pi.nodePath` 可覆盖 CLI 和 Node。开发环境还支持 `PI_DESKTOP_RUNTIME_DIR`、`PI_DESKTOP_PI_CLI`、`PI_DESKTOP_NODE`。请运行与改动相关的测试，参见[贡献指南](CONTRIBUTING.md)。

应用使用独立标识和数据目录（macOS 为 `~/Library/Application Support/pi-desktop`，Windows 为 `%APPDATA%/pi-desktop`），可用 `PI_DESKTOP_DATA_DIR` 覆盖。历史文档可能仍描述上游行为。

应用采用 [GPL-3.0-only](LICENSE)，第三方组件保留各自许可证和声明。
