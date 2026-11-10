# pi-desktop 版本与发布

本文描述当前 pi-desktop 桌面发布工作流、清单工具及其限制。更新客户端、清单格式和安全边界见 [auto-update.md](auto-update.md)。本链使用 `pi-v` 标签、独立仓库配置和独立更新密钥。

## 当前状态与边界

当前源码版本为 `0.1.3+4`，将通过 `pi-v0.1.3` 标签发布本次上游配置和界面修复。前一版本 [pi-v0.1.2 Release](https://github.com/zkldwxz/pi-desktop/releases/tag/pi-v0.1.2) 已发布。macOS arm64、macOS x64、Windows x64 三个 Actions 构建均成功；`.github/workflows/release.yml` 使用 `tool/release_manifest.dart` 生成并签名独立桌面更新清单。生产 GitHub 清单和 Windows 安装包已通过应用自身更新器的真实下载、重定向策略、大小、SHA-256 和 Ed25519 验证。Apple Silicon 应用已验证深度代码签名、随包运行时和隔离目录启动。视觉 GUI、Windows 交互安装和旧版本自动替换安装仍待验证；本次不构建 Linux 桌面安装包，Linux 自动更新关闭。GitHub 下载的重定向来源必须显式配置。Pi 官方运行时更新独立于桌面更新，见 [auto-update.md](auto-update.md#pi-运行时更新)。

## 版本和标签

版本沿用 `pubspec.yaml` 和 `lib/update/version.dart` 的 `主.次.修订+build` 约定，两处保持一致；每次发布递增 build，更新只接受更高版本。桌面版标签使用 marketing 版本，例如 `pi-v1.2.0` 对应 `1.2.0+12`。发布前检查标签与源码版本一致，并准备独立的发布说明。`release-notes/0.1.2.en.md` 和 `release-notes/0.1.2.zh.md` 为本版本发布说明；发布工作流使用英文说明作为 GitHub Release 正文。

`pi-v*` 标签推送触发发布，工作流验证标签与 `pubspec.yaml` 的 marketing 版本一致，并运行版本一致性测试检查更新器版本。`workflow_dispatch` 手动运行只构建并上传 Actions 产物，不注入生产更新配置。标签运行要求工作流变量 `PI_DESKTOP_UPDATE_URL` 为 HTTPS 清单地址，以及非空的 `PI_DESKTOP_UPDATE_PUBLIC_KEY`；通过 `PI_DESKTOP_UPDATE_ALLOWED_ORIGINS` 配置资源及重定向所需的额外精确 HTTPS origin，以逗号分隔。各平台构建将三者作为 Dart define 注入。签名步骤使用 secret `PI_DESKTOP_UPDATE_SIGNING_KEY` 中的 base64 私钥 seed。发布目标通过工作流变量 `PI_DESKTOP_RELEASE_REPOSITORY` 指定为 `owner/repo`；发布使用 secret `PI_DESKTOP_RELEASE_TOKEN`，未设置时使用 `github.token`。跨仓库发布需要有目标仓库 contents 写权限的 token，且目标仓库须预先有指向同一提交的同名标签。

工作流构建 macOS arm64、macOS x64 和 Windows x64，上传两个 macOS ZIP、两个 DMG、Windows setup.exe 和清单；清单的更新条目指向 ZIP 和 Windows 安装器。发布先创建包含所有资源和清单的草稿，再公开草稿；已有 Release 会使发布失败，不覆盖资源。中断后检查草稿和资源，确认无人使用后手动处理草稿，或发布新版本；已公开版本应保持不变。macOS 先把 `flutter build` 产出的通用应用瘦成目标单架构（`ditto --arch`），检查主程序包含目标架构，并确认 `pi-runtime/desktop-extension.mjs` 在应用里，再签名框架、浏览器宿主和 Finder 扩展，以 ad-hoc 签名封装应用；这不保证所有嵌入组件的架构均正确。重试工作流只在首次标签发布运行失败且存在失败的 `Build ` 作业时，重新运行失败作业一次。构建产物已生成，Apple Silicon 包签名与运行时验证已通过；实际交互安装和完整升级仍需真机验证。

远程服务器（IDE 侧，不是 Pi）不随应用携带：`remote` 作业构建 Linux x64 和 arm64 的服务器，发布为 GitHub Release `server-<版本>`（版本号由构建内容决定，只发布一次），应用只带 `VERSION` 和 `servers.json`（下载地址与 SHA-256），第一次连接 SSH 主机时下载并校验；macOS 和 Windows 作为被连接的主机暂不支持。直接 SSH Pi 会话使用远程已安装的 Pi 和 Node，通过批处理/密钥认证；真实 SSH stub 对话已验证，其他远程工作流仍需验证，不保证自动安装远程 IDE 服务或语言服务器。

## 本地打包与资源名称

以下脚本的产物位于 `build/installers/`，版本均为不含 build 号的 marketing 版本。工作流将 Windows 脚本产物复制到 `dist/`；macOS 工作流 ZIP 名称为 `pi-desktop-<version>-macos-<arch>.zip`。本地脚本支持的其他架构不表示当前工作流会发布它们。

- macOS：`dart run tool/build_macos.dart` 构建通用应用并按架构打包，生成 `pi-desktop-<version>-<arm64|x64>.dmg` 和更新用的 `pi-desktop-<version>-mac-<arm64|x64>.zip`。`--channel` 在扩展名前追加 `-channel`；`--skip-build` 使用已有构建。
- Windows：`dart run tool/build_windows.dart --arch x64` 生成 `pi-desktop-<version>-setup.exe`；`--arch arm64` 生成 `pi-desktop-<version>-setup-arm64.exe`。`--channel` 分别生成 `...-setup-channel.exe` 和 `...-setup-arm64-channel.exe`。

macOS 本地打包在加入运行时等文件后重新签名应用；未设置身份时使用 ad-hoc 签名。正式分发可将 `PI_DESKTOP_MACOS_SIGN_IDENTITY` 设为钥匙串中 Developer ID Application 证书的名称或 SHA-1，并设置 App Store Connect API 密钥路径 `PI_DESKTOP_NOTARY_KEY`、密钥 ID `PI_DESKTOP_NOTARY_KEY_ID` 和 issuer ID `PI_DESKTOP_NOTARY_ISSUER`。脚本签名 DMG，提交公证并将票据装订到 DMG 和应用后再制作更新 ZIP；仅设置身份而不配置公证不会执行公证。ad-hoc 或未公证的构建可能被其他机器的 Gatekeeper 拒绝。发布工作流使用的是单独的 ad-hoc 签名流程，不执行此公证步骤。

## 清单工具

在安全位置生成密钥，保存输出的公钥；工具不会覆盖已有密钥文件：

```sh
dart run tool/release_manifest.dart --generate-key /secure/pi-update-seed
export PI_DESKTOP_UPDATE_SIGNING_KEY=/secure/pi-update-seed
dart run tool/release_manifest.dart --public-key
```

私钥文件包含 base64 编码的 32 字节 seed，只提供给签名步骤，勿提交仓库或放入应用。签名时还需设置 `PI_DESKTOP_RELEASE_REPOSITORY`、`PI_DESKTOP_UPDATE_URL`、与私钥匹配的 `PI_DESKTOP_UPDATE_PUBLIC_KEY`，以及需要的 `PI_DESKTOP_UPDATE_ALLOWED_ORIGINS`。例如，对实际最终文件签名：

```sh
export PI_DESKTOP_RELEASE_REPOSITORY=zkldwxz/pi-desktop
export PI_DESKTOP_UPDATE_URL=https://github.com/zkldwxz/pi-desktop/releases/latest/download/latest.json
export PI_DESKTOP_UPDATE_PUBLIC_KEY='<base64 public key>'
dart run tool/release_manifest.dart \
  --macos-arm64 path/to/mac-arm64.zip --macos-x64 path/to/mac-x64.zip \
  --notes-en path/to/notes-en.txt --notes-zh path/to/notes-zh.txt \
  --manifest build/installers/latest.json
```

工具默认从 `pubspec.yaml` 读取完整版本，也可用 `--version` 覆盖；支持 `--minimum-version`，以及文本或文件形式的 `--notes-en`、`--notes-zh`。可签名的文件选项还有 `--windows`、`--windows-arm64`、`--linux-x64`、`--linux-arm64`，清单工具接受每个文件选项的 `-channel` 形式；工具支持的选项不代表当前工作流会发布对应平台。`--dmg-arm64` 和 `--dmg-x64`（也支持 `-channel`）只添加到 `downloads`，不产生签名的更新平台条目。默认输出为 `build/installers/latest.json`；同版本的已有清单会校验原条目签名后合并，新版本则不保留原条目。`--build-only` 只输出提示，不生成、签名或发布清单；`--help` 显示完整选项。工具生成文件但不上传它们。

工具目前只生成指向 `https://github.com/<owner>/<repo>/releases/download/pi-v<marketing>/<文件名>` 的资源 URL。清单可以由其他 HTTPS 地址提供，但必须在允许的 origin 中明确配置 `https://github.com`。GitHub Release 下载通常会跨源重定向，还须检查实际完整重定向链并显式配置每个所需的 HTTPS origin；没有默认信任的 GitHub 重定向主机。发布前用实际客户端验证完整链路；先上传实际文件，再使核对过的清单可供客户端读取。

用已安装的旧版本在真实 macOS 和 Windows 机器上验证发现、下载、校验、退出确认、安装和重启。不要覆盖用户可能装过的同版本：应用不会把相同版本视为更新，已有清单的摘要也会与替换后的文件不一致。有问题时发布更高版本；将清单退回旧版不能自动降级。

## Pi 运行时打包

桌面发布不携带 Node 和 Pi（它们合计约 200 MB），只携带运行时的文件（桌面扩展、配置、运行时管理脚本和 `package.json` 与 `package-lock.json`，约 170 KB），Pi 版本由它们锁定，当前为 1.5.0。构建流程调用 `tool/bundle_pi_runtime.dart` 放入这些文件（加 `--full` 才会打包 Node 和 Pi 做离线包）。应用第一次启动时安装锁定的 Pi：用机器上 22.19 以上的 Node，没有就从 nodejs.org 下载并校验 SHA-256，进度显示在输入框上方（`lib/kernel/pi/pi_runtime_install.dart`）。之后运行时可以独立更新；见 [Pi 运行时更新](auto-update.md#pi-运行时更新)。

## 发布前配置与验证

- 配置独立目标仓库、发布权限、签名私钥和面向客户端的 HTTPS 更新源；不要把私钥写进仓库、日志或构建产物。
- 确认所有资源 URL 及每次重定向的精确 origin 已获配置；用实际客户端验证，而不仅是浏览器下载。
- 检查清单版本、平台键、文件大小、摘要和签名与最终上传文件一致；验证错误密钥和篡改文件被拒绝。
- 检查平台安装身份、升级兼容性及代码签名需求；macOS 正式签名的已安装版本要求更新来自同一 Team。
- build-only 运行不依赖生产配置；检查其构建产物和日志没有生产更新配置或发布凭据。
- 运行与改动相关的测试并进行真实机器验证；不要将未完成的自动化或测试描述为已上线。
