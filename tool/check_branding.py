#!/usr/bin/env python3
"""Finds the upstream's name (BaoCode) and Claude-only wording in what users
and agents read, after an upstream merge brings in new strings.

    python3 tool/check_branding.py          # report; exit 1 when there are any
    python3 tool/check_branding.py --fix    # rewrite the l10n values it can

What is checked: the values of lib/l10n/app_*.arb, and the string literals
that are written into agent prompts (lib/bots, lib/chat/chat_session.dart,
lib/stash/stash_skill.dart, lib/usage/usage_skill.dart). Identifiers, code
comments, tests and the internal `bao_*` packages are left alone on purpose:
renaming them would make every upstream merge conflict (docs/upstream-sync.md).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = '--fix' in sys.argv

# Keys that name the upstream's own services; they stay as they are until
# there is a service of ours to point to.
KEEP_KEYS = re.compile(r'^(channelSetup|mobileRelay|channel[A-Z])')
# Strings of the upstream's Claude Code installer: no Pi flow reaches them.
LEGACY_KEYS = re.compile(
    r'^(remoteStatusInstalling|remoteStatusInstallingUnsized|remoteInstallingClaude'
    r'|remoteInstallingClaudeProgress|localDownloadingClaude|remoteUploadingClaude)$'
)
NAME = re.compile(r'BaoCode|baocode\.dev')
CLAUDE = re.compile(r'Claude Code|claude\.ai|\.claude\b|CLAUDE\.md|`claude |ANTHROPIC_|CLAUDE_CODE_')
PROMPT_FILES = [
    'lib/bots/bot_prompt.dart',
    'lib/chat/chat_session.dart',
    'lib/stash/stash_skill.dart',
    'lib/usage/usage_skill.dart',
]

problems = []

for arb in sorted((ROOT / 'lib/l10n').glob('app_*.arb')):
    text = arb.read_text()
    data = json.loads(text)
    changed = False
    for key, value in data.items():
        if key.startswith('@') or not isinstance(value, str) or KEEP_KEYS.match(key) or LEGACY_KEYS.match(key):
            continue
        hit = NAME.search(value)
        if hit:
            if FIX:
                new = value.replace('BaoCode', 'pi-desktop')
                if new != value and not NAME.search(new):
                    # Textual replace, so the file's layout stays as it is.
                    old_json = json.dumps(value, ensure_ascii=False)
                    new_json = json.dumps(new, ensure_ascii=False)
                    if old_json in text:
                        text = text.replace(old_json, new_json, 1)
                        changed = True
                        continue
            problems.append(f'{arb.name}: {key}: {value[:90]}')
        elif CLAUDE.search(value):
            problems.append(f'{arb.name}: {key}: (Claude-only) {value[:80]}')
    if changed:
        arb.write_text(text)

for name in PROMPT_FILES:
    path = ROOT / name
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith('//'):
            continue
        if NAME.search(line) or re.search(r'CLAUDE_SESSION_ID|allowed-tools', line):
            problems.append(f'{name}:{n}: {line.strip()[:90]}')

if problems:
    print('\n'.join(problems))
    print(f'\n{len(problems)} to look at (see docs/upstream-sync.md)')
    sys.exit(1)
print('branding: nothing to fix')
