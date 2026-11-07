# pi-desktop 自动更新

本文记录 pi-desktop 独立更新链的约定和当前实现；构建、发布及尚需完成的工作见 [release.md](release.md)。它使用自己的更新地址和 Ed25519 密钥。

## 当前状态

`lib/update/pi_desktop_update_config.dart` 要求同时配置清单 URL 和公钥，否则更新不可用，没有生产地址或公钥默认值。独立仓库 [zkldwxz/pi-desktop](https://github.com/zkldwxz/pi-desktop) 已发布 [0.1.2](https://github.com/zkldwxz/pi-desktop/releases/tag/pi-v0.1.2)。生产更新清单和真实 Windows 安装包已通过应用自身更新器的 HTTPS 重定向、大小、SHA-256 和 Ed25519 校验；旧版本退出、替换安装和重启的完整流程仍待真机验证。`lib/update/installer_io.dart` 为 macOS 和 Windows 创建更新器；Linux 自动更新仍关闭。当前桌面版本为 `0.1.2+3`，对应标签 `pi-v0.1.2`。桌面更新与下文的 Pi 运行时更新相互独立。

应用的更新方式仍由 `update.mode` 控制：`default` 自动检查和下载，`manual` 手动检查，`none` 关闭。更新先下载并校验，用户确认退出后才启动安装。macOS 安装器检查应用 bundle ID；当前应用有有效代码签名时还要求新版签名有效且 Team 一致。

## 配置

| 配置 | 作用 |
| --- | --- |
| `PI_DESKTOP_UPDATE_URL` | 更新清单的绝对 URL；生产环境使用 HTTPS |
| `PI_DESKTOP_UPDATE_PUBLIC_KEY` | 独立 Ed25519 公钥，base64 解码后恰好 32 字节 |
| `PI_DESKTOP_UPDATE_ALLOWED_ORIGINS` | 额外允许的精确 HTTPS origin，以逗号分隔，供资源地址和重定向使用（本地测试可按下述条件使用 HTTP loopback） |
| `PI_DESKTOP_UPDATE_ALLOW_LOCALHOST` | 值为 `true` 时允许 `localhost`、`127.0.0.1`、`::1` 的 HTTP，供本地测试 |
| `PI_DESKTOP_DOWNLOAD_URL` | 可选的手动下载页面地址，发布工作流以 Dart define 注入 |
| `PI_DESKTOP_CHANGELOG_URL` | 可选的更新日志页面地址，发布工作流以 Dart define 注入 |

更新 URL、公钥、允许来源和 localhost 开关可用构建时 Dart define 或运行时环境变量配置；运行时值优先，即使它显式为空。下载和更新日志链接使用构建时 Dart define；留空时相应链接不显示。URL 或公钥缺失、格式无效，URL 含用户信息或 fragment，或者 HTTP 未获上述本地许可时，更新器不会启用。不要在 build-only 构建中注入生产 URL 或密钥。debug 构建也可能在配置有效时启用更新；测试时使用可替换的副本。

清单来源默认允许；安装包 URL 和清单、安装包重定向的每一跳必须属于清单来源或显式配置的精确 HTTPS origin，最多跟随五次。origin 包含协议、主机和端口，不含路径。HTTP 仅供显式开启的 loopback 测试。GitHub Release 下载通常跨源重定向：检查实际完整重定向链，在 `PI_DESKTOP_UPDATE_ALLOWED_ORIGINS` 中明确配置每个所需的 GitHub 资源和重定向 origin；客户端不会自动信任 GitHub 的其他主机。

## 清单和签名

清单 JSON 顶层包含 `version`、`platforms`，可选 `pubDate`、`notes` 和 `minimumVersion`；每个平台条目包含 `url`、正整数 `size`（字节）、64 位十六进制 `sha256` 和 base64 Ed25519 `signature`。例如：

```json
{
  "version": "1.2.0+12",
  "platforms": {
    "macos-arm64": {
      "url": "https://updates.example.com/releases/pi-v1.2.0/pi-desktop-1.2.0-mac-arm64.zip",
      "size": 123456789,
      "sha256": "<64 hex characters>",
      "signature": "<base64 signature>"
    }
  }
}
```

地址和摘要是占位示例，文件名对应本地 macOS 打包脚本的更新 ZIP；当前发布工作流生成的 ZIP 则使用 `pi-desktop-<version>-macos-<arch>.zip`。清单工具实际生成 GitHub Release 资源地址，并要求 `https://github.com` 在允许的 origin 中，详见 [清单工具](release.md#清单工具)。当前工作流构建 macOS arm64、macOS x64 和 Windows x64，清单指向 macOS ZIP 和 Windows setup.exe；详见 [本地打包与资源名称](release.md#本地打包与资源名称)。macOS 使用 `macos-arm64` 或 `macos-x64`，Rosetta 下的 Intel 构建会选择 arm64。缺少当前平台条目时视为没有更新；条目格式错误则该平台检查失败。版本必须比已安装版本高；回退清单不会降级已更新的用户。

对每个文件计算 SHA-256，再用独立私钥对以下 UTF-8 文本签名，每项一行，末尾也有换行：

```text
pi-desktop-update-v1
1.2.0+12
macos-arm64
123456789
<lowercase sha256>
```

签名绑定版本、平台、大小和摘要；URL 不在签名中，但仍须符合上述 origin 策略。下载后依次验证大小、SHA-256 和签名。签名是 64 字节，base64 编码。私钥应离线备份并仅提供给独立发布流程；切勿提交仓库。已安装版本信任的公钥发生变化时需要事先设计过渡，否则用户需要手动重装。

## Pi 运行时更新

桌面包内的 Pi 运行时由 `runtime/pi/package-lock.json` 锁定，当前初始版本为 1.5.0。应用另行检查 Pi 官方稳定版本，启动后首次检查安排在 30 秒后，此后每 6 小时检查一次。`pi.autoUpdate` 默认开启；关闭它可停止自动更新，设置页仍可手动检查或更新。自动更新只安装比当前所选运行时更高的版本，并使用该版本官方发布的 package.json 和 package-lock.json 安装到应用数据目录。

激活后的运行时用于之后启动的本地 Pi 进程，包括新会话；已经运行的进程不会自动重启。显式配置的 CLI 路径或 `PI_DESKTOP_PI_CLI` 优先于托管运行时；远程 SSH 会话使用远程主机的 Pi。运行时更新不依赖桌面 Ed25519 更新清单，也不会升级桌面应用。

## 本地验证

在隔离目录准备更高版本的安装包和使用测试密钥签出的清单，将清单和包放在同一 loopback 服务器上，然后给测试应用设置：

```sh
export PI_DESKTOP_UPDATE_URL=http://127.0.0.1:8080/latest.json
export PI_DESKTOP_UPDATE_PUBLIC_KEY='<base64 test public key>'
export PI_DESKTOP_UPDATE_ALLOW_LOCALHOST=true
```

启动可替换的 macOS 测试构建，检查发现、下载、校验、退出确认和重启安装。验证错误公钥、文件篡改及未配置 origin 的重定向均被拒绝，并验证已配置 origin 的重定向。静态服务器不支持 Range 时下载会从头开始。相关自动化测试可运行 `flutter test test/update`；它们不能替代真机安装验证。

## 排查

- 更新不可用：检查更新配置、平台支持及运行时空变量是否覆盖构建时值。
- 清单或下载失败：核对 URL 的协议、主机、端口和每一跳重定向；GitHub 的资源重定向尤其需要检查。
- 校验失败：检查私钥与配置公钥的对应关系、签名上下文、版本、平台、文件大小和 SHA-256 是否与实际文件一致。
- macOS 无法安装：检查应用位置、目录写权限、bundle ID，以及已有正式签名时的签名和 Team。
