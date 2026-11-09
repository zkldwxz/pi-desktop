# 同步上游（baocode-dev/baocode）

pi-desktop 是独立维护的项目，但很多功能（IDE、Git、SSH、浏览器、统计……）来自上游。
把上游的新提交拿回来不难：**两边的历史是连着的**，用普通的 `git merge` 就行。
2026-11 做过一次试合并：上游比我们多 22 个提交，只有 4 个文件冲突
（版本号、`pubspec.yaml`、`CONTRIBUTING.md`、一个测试）。

## 一条命令

```bash
tool/upstream_sync.sh --report   # 上游多了什么、合并会在哪些文件冲突（试合并，随后撤销，什么都不改）
tool/upstream_sync.sh            # 在 sync/upstream-<日期> 分支上合并
tool/upstream_sync.sh --check    # 合并后：品牌检查、flutter analyze、被改动目录对应的测试
```

`.github/workflows/upstream-sync.yml` 每周自动跑一次：能干净合并就开一个 PR，有冲突就开一个
issue 列出冲突文件。也可以在 Actions 里手动触发。

`git config rerere.enabled true`（脚本会设）会记住你解决过的冲突，下次同样的冲突自动套用。

## 为什么合并便宜：只改我们的“身份”，不改内部命名

要保持便宜，就要克制。**每多改一处上游也在改的行，以后就多一次冲突。**

| 我们改了（用户看得见/会冲突） | 我们刻意没改（改了就处处冲突） |
| --- | --- |
| 应用名、包名、bundle id、可执行文件名、数据目录 | `packages/bao_*` 内部包名 |
| 面向用户和面向 Pi 的文案（l10n、提示词、skill） | 注释、文档字符串、测试里的样例文字 |
| 主题（`theme-pi`）、思考动画颜色 | 原生层转给 Dart 的内部 scheme `baocode://` |
| 临时目录、请求头、日志抬头等标识 | `lib/kernel/claude_code/`、`codex/`（保留，不再使用） |
| Pi 内核 `lib/kernel/pi/`、`runtime/pi/` | `site/`（官网，另行处理） |

不要对整个仓库做 `BaoCode → pi-desktop` 全局替换。

## 我们与上游分叉的地方（合并时重点看）

- **内核**：`lib/kernel/pi/**`、`runtime/pi/**`、`kernel_registry.dart`（只注册 Pi）。上游改 `claude_code/` 的提交通常可以直接忽略。
- **Customize**：`lib/customize/**` 已是 Pi 版（技能、提示词、AGENTS.md、MCP、Pi 包商店）。上游若改它，要人工移植意图，不要照搬 Claude 的 `.claude/`、`settings.json`、插件、hooks。
- **Skill / 工具名**：Stash、Usage 的 skill 写进 Pi 的 agent 目录，工具名是 `mcp__pi_desktop__*`（`ClaudeSdkTools.server = 'pi_desktop'`）。上游新增的工具在 skill 文本里的名字要跟着改。
- **主题**：默认 `Pi Dark` / `Pi Light`（`packages/bao_editor/assets/textmate/themes/theme-pi/`）。
- **版本与发布**：`pubspec.yaml`、`lib/update/version.dart`、`.github/workflows/`、`docs/release.md`、`release-notes/` 是我们自己的。

## 解决冲突的规则

1. `pubspec.yaml`、`lib/update/version.dart`、`CONTRIBUTING.md`、`README*`、`release-notes/`、`.github/workflows/`：**留我们的**，只手工补上游新增的依赖行。
2. `lib/l10n/*.arb`：两边都留，合并后运行 `flutter gen-l10n`，再 `python3 tool/check_branding.py --fix`。
3. 冲突在 `claude_code/`、`codex/`：通常留上游的（我们不用，留着减少以后的差异）。
4. 冲突在 `lib/customize/`、`lib/stash/stash_skill.dart`、`lib/usage/usage_skill.dart`、`lib/theme/`、`main.dart`：留我们的结构，吸收上游的新逻辑。
5. 测试冲突：以代码为准，改测试。

## 合并之后一定要做的

1. `python3 tool/check_branding.py`：上游新增的 l10n 文案或提示词里出现 `BaoCode`、`Claude Code`、`claude.ai` 时会列出来（`--fix` 改得了的 l10n 它会直接改）。
2. 看新增功能依赖的是不是 Claude 才有的能力：`kernel/agent_kernel.dart` 里的能力接口（如 `ManagesMcpServers`、`RewindsConversation`），`PiKernel` 没实现的，界面上本来就不会出现；如果要给 Pi 做，是在 `lib/kernel/pi/` 里实现接口，不是改 UI。
3. `flutter analyze lib test`，再跑被改动目录的测试（`tool/upstream_sync.sh --check` 做这两件事）。不要一上来就跑全量测试，很慢。
4. 有新的 `ClaudeSdkTools.register` 的工具？Pi 通过 `runtime/pi/desktop-extension.mjs` 桥接全部已注册工具，名字自动是 `mcp__pi_desktop__<name>`，但要核对相关 skill/提示词里写的名字。

## 挑着拿（cherry-pick）

某个上游修复很急、又不想合并全部，可以 `git cherry-pick -x <sha>`。`-x` 会在提交信息里记下来源，
之后整体合并时 git 会自然去重。
