#!/usr/bin/env bash
# Brings the upstream's (baocode-dev/baocode) new commits into this project.
# See docs/upstream-sync.md for the policy and how to settle conflicts.
#
#   tool/upstream_sync.sh --report     what is new, and how a merge would go
#                                      (a trial merge, undone; nothing changes)
#   tool/upstream_sync.sh              merge it on a branch sync/upstream-<date>
#   tool/upstream_sync.sh --check      after a merge: branding, analysis, and
#                                      the tests of what the merge touched
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/baocode-dev/baocode.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
mode="${1:-merge}"

cd "$(git rev-parse --show-toplevel)"

if [ "$mode" = "--check" ]; then
  python3 tool/check_branding.py || echo "→ settle the branding above (tool/check_branding.py --fix does the l10n ones)"
  flutter pub get >/dev/null
  flutter analyze lib test
  # Only the tests of the folders the merge changed: the full suite is slow.
  changed=$(git diff --name-only HEAD^1 HEAD -- lib | awk -F/ 'NF>2{print $2}' | sort -u)
  tests=()
  for d in $changed; do [ -d "test/$d" ] && tests+=("test/$d"); done
  if [ ${#tests[@]} -gt 0 ]; then flutter test "${tests[@]}"; else echo "no matching test folders"; fi
  exit 0
fi

git config rerere.enabled true   # a conflict settled once is settled again by itself
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "The working tree has changes: commit or stash them first." >&2
  exit 1
fi

git fetch --no-tags upstream "$UPSTREAM_BRANCH"
# A shallow clone needs more history before the two sides meet.
for _ in 1 2 3 4 5 6; do
  git merge-base HEAD "upstream/$UPSTREAM_BRANCH" >/dev/null 2>&1 && break
  git fetch --no-tags --deepen=300 upstream "$UPSTREAM_BRANCH"
  git fetch --no-tags --deepen=300 origin HEAD 2>/dev/null || true
done
base=$(git merge-base HEAD "upstream/$UPSTREAM_BRANCH")
count=$(git rev-list --count "$base..upstream/$UPSTREAM_BRANCH")
echo "upstream/$UPSTREAM_BRANCH is $count commit(s) ahead of the last common point ($(git rev-parse --short "$base"))."
[ "$count" -eq 0 ] && { echo "Nothing to bring in."; exit 0; }

echo; echo "What changed, by folder (not counting the Claude and Codex adapters we do not use):"
git diff --dirstat=files,0 "$base" "upstream/$UPSTREAM_BRANCH" \
  | grep -v "kernel/claude_code\|kernel/codex\|^ *[0-9.]*% site/" || true
echo; git log --oneline "$base..upstream/$UPSTREAM_BRANCH" | head -60

here=$(git rev-parse --abbrev-ref HEAD)
if [ "$mode" = "--report" ]; then
  git checkout -q --detach
  if git merge --no-commit --no-ff "upstream/$UPSTREAM_BRANCH" >/dev/null 2>&1; then
    echo; echo "A merge would go through without conflicts."
  else
    echo; echo "A merge would conflict in:"; git diff --name-only --diff-filter=U | sed 's/^/  /'
  fi
  git merge --abort 2>/dev/null || git reset -q --hard
  git checkout -q "$here"
  exit 0
fi

branch="sync/upstream-$(date +%Y%m%d)"
git checkout -q -b "$branch"
if git merge --no-ff -m "chore: merge upstream $(git rev-parse --short "upstream/$UPSTREAM_BRANCH") ($count commits)" "upstream/$UPSTREAM_BRANCH"; then
  echo; echo "Merged on $branch. Next: tool/upstream_sync.sh --check"
else
  echo; echo "Conflicts on $branch, in:"; git diff --name-only --diff-filter=U | sed 's/^/  /'
  echo "Settle them as docs/upstream-sync.md says, 'git commit', then tool/upstream_sync.sh --check"
  exit 2
fi
