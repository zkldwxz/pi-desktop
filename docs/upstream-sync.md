# 同步上游（baocode-dev/baocode）

pi-desktop 是独立维护的项目：名字、内部包名、数据目录、图标全部是我们自己的。
很多功能（IDE、Git、SSH、浏览器、统计……）仍然来自上游，我们希望把它的新改动拿回来。

## 做法：先改名，再合并

上游的代码里到处是 `BaoCode` / `bao_*`，直接 `git merge` 会在每个被我们改过名字的文件上冲突。
所以不合并上游原样的提交，而是：

1. 取上游某个提交的**快照**，用 `tool/rebrand.py` 跑一遍同样的改名映射（路径和文本都改）；
2. 把改名后的快照提交到分支 `upstream-rebranded`（它的父提交是上一个快照，历史是连着的）；
3. 把 `upstream-rebranded` 合并进来。

两边用同一套名字，`git` 的三方合并只会在“我们和上游改了同一行”的地方冲突。
第一次运行会自动建立共同祖先（上游当时的状态，改名后，用 `-s ours` 记为已合并，不改我们的文件）。
2026-11 的试合并：上游多 22 个提交，改名前只有 4 个文件冲突（版本号、`pubspec.yaml`、`CONTRIBUTING.md`、一个测试）。

## 一条命令

```bash
tool/upstream_sync.sh --report   # 上游多了什么、合并会在哪些文件冲突（试合并，随后撤销）
tool/upstream_sync.sh            # 在 sync/upstream-<日期> 分支上合并
tool/upstream_sync.sh --check    # 合并后：品牌检查、flutter analyze、被改动目录对应的测试
```

`.github/workflows/upstream-sync.yml` 每周自动跑一次：能干净合并就开 PR，有冲突就开 issue 列出冲突文件，
并把 `upstream-rebranded` 推到 origin，本地再跑一次 `tool/upstream_sync.sh` 即可接着解决。
`git config rerere.enabled true`（脚本会设）会记住解决过的冲突。

## `tool/rebrand.py` 改什么、不改什么

| 改 | 为 |
| --- | --- |
| `BaoCode` / `baocode` → `pi-desktop`；标识符里的 → `PiDesktop` / `piDesktop` / `pi_desktop_` | 名字 |
| `bao_*` → `pi_*`（`packages/bao_editor` → `packages/pi_editor` 等）、`BAO_*` → `PI_*`、`dev.baocode.*` → `dev.pi.desktop.*` | 内部包、原生符号、bundle id |
| `github.com/baocode-dev/baocode` 和 `*.baocode.dev` 的网址 → 本仓库地址；散文里的 `baocode.dev` → “the pi-desktop site” | 上游自己的服务，我们没有 |
| `defaultLinkRelays` → `.invalid` 占位地址 | 没有我们自己的中继，不经过别人的服务器 |

**不改**（`EXEMPT` / `IN_PLACE`，见脚本）：`LICENSE*` / `NOTICE*`（上游的版权声明必须保留，文件跟着目录搬家但内容不动）、
`README*`、`release-notes/`、`site/` 和 `site-worker/`（官网是另一件事）、同步工具自己，以及三个专门证明
“上游的数据目录、环境变量、更新签名上下文**不会**被我们接受”的测试（它们需要保留旧名字）。

脚本是幂等的：对已经改过名的树再跑一遍不会有变化。

## 我们与上游分叉的地方（合并时重点看）

- **内核**：`lib/kernel/pi/**`、`runtime/pi/**`、`kernel_registry.dart`（只注册 Pi）。上游改 `claude_code/`、`codex/` 的提交通常可以直接留上游的。
- **Customize**：`lib/customize/**` 是 Pi 版（技能、提示词、AGENTS.md、MCP、Pi 包商店）。上游若改它，要人工移植意图，不要照搬 Claude 的 `.claude/`、插件、hooks。
- **Skill / 工具名**：Stash、Usage 的 skill 写进 Pi 的 agent 目录，工具名是 `mcp__pi_desktop__*`（`ClaudeSdkTools.server = 'pi_desktop'`）。
- **主题与图标**：默认 `Pi Dark` / `Pi Light`（`packages/pi_editor/assets/textmate/themes/theme-pi/`）；图标源文件 `assets/branding/app_icon.svg`、`logo.svg`。
- **版本与发布**：`pubspec.yaml`、`lib/update/version.dart`、`.github/workflows/`、`docs/release.md` 是我们自己的。
- **删掉的功能**：手机链接（`lib/link/`、`packages/pi_link`、`packages/pi_iroh` 的 Rust 库）、Bots（`lib/bots/`）和设置里的“手机”页，以及它们的测试、`pi_iroh.yml`、`pi-iroh-prebuilt`/`setup-rust` 两个 action。上游改这些文件时合并会报“我们删了、它改了”的冲突：直接保留删除（`git rm`）。上游若有别的地方开始依赖它们，再单独处理。
- **没有我们自己的服务**：推荐上游列表、渠道账号、统计上报、更新源。这些代码还在，但默认指向不存在的地址或需要显式配置。远程服务器不再内置：CI 把它们发布成 GitHub Release `server-<版本>`，应用只带 `servers.json`，连 SSH 时下载。

## 解决冲突的规则

1. `pubspec.yaml`、`lib/update/version.dart`、`CONTRIBUTING.md`、`README*`、`release-notes/`、`.github/workflows/`：**留我们的**，只手工补上游新增的依赖行。
2. `lib/l10n/*.arb`：两边都留，合并后运行 `flutter gen-l10n`，再 `python3 tool/check_branding.py --fix`。
3. 冲突在 `claude_code/`、`codex/`：通常留上游的（我们不用，留着减少以后的差异）。
4. 冲突在 `lib/customize/`、`lib/stash/stash_skill.dart`、`lib/usage/usage_skill.dart`、`lib/theme/`、`main.dart`：留我们的结构，吸收上游的新逻辑。
5. 测试冲突：以代码为准，改测试。

## 合并之后一定要做的

1. `python3 tool/check_branding.py`：上游新增的文案里出现 `Claude Code`、`claude.ai` 等会列出来（`--fix` 改得了的 l10n 它会直接改）。
2. 新功能依赖的是不是 Claude 才有的能力：看 `kernel/agent_kernel.dart` 里的能力接口（如 `ManagesMcpServers`、`RewindsConversation`），`PiKernel` 没实现的界面上本来就不会出现；要给 Pi 做，是在 `lib/kernel/pi/` 里实现接口，不是改 UI。
3. `flutter analyze`，再跑被改动目录的测试（`tool/upstream_sync.sh --check` 做这两件事）。不要一上来就跑全量测试，很慢。
4. 上游新增了对外服务地址（新的域名、下载站）？`rebrand.py` 会把带协议的网址换成本仓库地址，但可能不合语义，看一眼 diff。
5. 上游新增的文件名或标识符里带 `Bao`/`bao`？如果映射漏了，在 `tool/rebrand.py` 的 `TEXT_RULES` 里加规则，重新生成快照。

## 挑着拿（cherry-pick）

某个上游修复很急、又不想合并全部，可以对 `upstream-rebranded` 上的对应提交 `git cherry-pick -x <sha>`（它已经是改过名的）。
`-x` 会在提交信息里记下来源，之后整体合并时 git 会自然去重。
