#!/usr/bin/env python3
"""Rewrites the upstream's name (BaoCode) to ours, in a tree.

The same mapping, applied to paths and to text, so that it can be run on this
repository once and on every new snapshot of the upstream afterwards
(tool/upstream_sync.sh): a merge of two trees that went through the same
mapping conflicts only where the two sides changed the same lines.

    python3 tool/rebrand.py                 # this repository, in place
    python3 tool/rebrand.py --tree DIR      # another tree (an upstream checkout)
    python3 tool/rebrand.py --dry-run       # what would change, nothing written

What is never rewritten: licences and notices (the upstream's copyright
stays), the README attribution, release history, the upstream-sync tools
themselves, and the website (site/), which is its own piece of work.
"""
import os
import re
import sys
from pathlib import Path

PRODUCT = 'pi-desktop'
REPO = 'github.com/zkldwxz/pi-desktop'

# Paths (relative, with /) left exactly as they are.
EXEMPT = [
    r'(^|/)\.git/',
    r'(^|/)(LICENSE|LICENCE|NOTICE|COPYING)[^/]*$',
    r'^README[^/]*\.md$',
    r'^release-notes/',
    r'^site/',
    r'^site-worker/',
    r'^wrangler\.jsonc$',
    r'^docs/upstream-sync\.md$',
    r'^tool/(rebrand|upstream_sync|check_branding)\.(py|sh)$',
    r'^\.github/workflows/upstream-sync\.yml$',
    r'(^|/)(build|node_modules|\.dart_tool)/',
    r'(^|/)third_party/',
]
EXEMPT_RE = [re.compile(p) for p in EXEMPT]

BINARY_SUFFIXES = {
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.icns', '.webp', '.ttf', '.otf',
    '.woff', '.woff2', '.gz', '.zip', '.so', '.dylib', '.dll', '.a', '.lib',
    '.exe', '.pdf', '.wav', '.mp3', '.ogg', '.bin', '.onig', '.dat',
}

# (regex, replacement), in order. The services of the upstream come first:
# there is nothing of ours behind those addresses.
TEXT_RULES = [
    (r'https://github\.com/baocode-dev/baocode(?:\.git)?', f'https://{REPO}'),
    (r'github\.com/baocode-dev/baocode', REPO),
    (r'https?://(?:[a-z0-9-]+\.)?baocode\.dev(?:/[^\s\'"<>)`\\$]*)?', f'https://{REPO}'),
    (r'(?<![A-Za-z0-9/.@-])(?:[a-z0-9-]+\.)?baocode\.dev', 'the pi-desktop site'),
    (r'noreply@baocode\.dev', 'noreply@github.com'),
    (r'dev\.baocode\.', 'dev.pi.desktop.'),
    # Identifiers (from here on the rules are also those of paths)
    (r'(?<=[A-Za-z0-9])(?:BaoCode|Baocode)', 'PiDesktop'),
    (r'BaoCode(?=[A-Za-z0-9_])', 'PiDesktop'),
    (r'baoCode(?=[A-Z])', 'piDesktop'),
    (r'baocode(?=[A-Z])', 'piDesktop'),
    (r'BAOCODE_', 'PI_DESKTOP_'),
    (r'BAOCODE', 'PI-DESKTOP'),
    (r'baocode_', 'pi_desktop_'),
    (r'(?<=[A-Za-z0-9_]\.)baocode\b(?!\.[a-z])', 'piDesktop'),
    # The name, in prose, paths and strings
    (r'BaoCode|Baocode|baocode', PRODUCT),
    # The internal packages and native symbols
    (r'(?<![A-Za-z0-9])bao_', 'pi_'),
    (r'(?<=lib)bao_', 'pi_'),
    (r'(?<![A-Za-z0-9])bao-', 'pi-'),
    (r'(?<![A-Za-z0-9])Bao(?=[A-Z])', 'Pi'),
    (r'(?<![A-Za-z0-9])BAO_', 'PI_'),
]
TEXT_RE = [(re.compile(p), r) for p, r in TEXT_RULES]
FIRST_NAME_RULE = 6  # TEXT_RULES[6:] are the rules of paths too
PATH_RULES = TEXT_RE[FIRST_NAME_RULE:]

# Rules for one kind of file, after the above.
FILE_RULES = [
    # No relays of ours: the phone link keeps to direct connections.
    (r'(^|/)relays\.dart$',
     re.compile(r"const defaultLinkRelays = \[[^\]]*\];", re.S),
     'const defaultLinkRelays = <String>[];'),
]


def exempt(rel: str) -> bool:
    return any(p.search(rel) for p in EXEMPT_RE)


def rebrand_text(text: str, rel: str = '') -> str:
    for where, pattern, repl in FILE_RULES:
        if re.search(where, rel):
            text = pattern.sub(repl, text)
    for pattern, repl in TEXT_RE:
        text = pattern.sub(repl, text)
    return text


def rebrand_path(rel: str) -> str:
    out = []
    for part in rel.split('/'):
        for pattern, repl in PATH_RULES:
            part = pattern.sub(repl, part)
        out.append(part)
    return '/'.join(out)


def main() -> int:
    args = sys.argv[1:]
    dry = '--dry-run' in args
    root = Path(args[args.index('--tree') + 1]) if '--tree' in args else Path(
        __file__).resolve().parent.parent
    root = root.resolve()
    files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('.git', 'build', 'node_modules', '.dart_tool')]
        for name in names:
            path = Path(base) / name
            if path.is_symlink():
                continue
            files.append(path.relative_to(root).as_posix())
    changed = renamed = 0
    for rel in sorted(files):
        if exempt(rel):
            continue
        path = root / rel
        target = rebrand_path(rel)
        if Path(rel).suffix.lower() not in BINARY_SUFFIXES:
            try:
                text = path.read_text(encoding='utf-8')
            except (UnicodeDecodeError, OSError):
                text = None
            if text is not None:
                new = rebrand_text(text, rel)
                if new != text:
                    changed += 1
                    if not dry:
                        path.write_text(new, encoding='utf-8')
        if target != rel:
            renamed += 1
            if not dry:
                dest = root / target
                dest.parent.mkdir(parents=True, exist_ok=True)
                os.replace(path, dest)
    if not dry:
        # Folders left empty by the renames.
        for base, dirs, names in os.walk(root, topdown=False):
            if not dirs and not names and Path(base) != root and '.git' not in base:
                try:
                    os.rmdir(base)
                except OSError:
                    pass
    print(f'{"would change" if dry else "changed"} {changed} file(s), '
          f'{"would rename" if dry else "renamed"} {renamed}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
