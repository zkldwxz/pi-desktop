#!/usr/bin/env bash
# Brings the upstream's (baocode-dev/baocode) new commits into this project.
# See docs/upstream-sync.md for how it works and how to settle conflicts.
#
#   tool/upstream_sync.sh --report     what is new, and how a merge would go
#                                      (a trial merge, undone; nothing changes)
#   tool/upstream_sync.sh              merge it on a branch sync/upstream-<date>
#   tool/upstream_sync.sh --check      after a merge: branding, analysis, and
#                                      the tests of what the merge touched
#
# The upstream's names are rewritten by tool/rebrand.py in every snapshot of
# it first, kept on the branch `upstream-rebranded`; that is what is merged.
# Both sides then speak the same names, so a merge conflicts only where the
# two really changed the same lines.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/baocode-dev/baocode.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
REBRANDED=upstream-rebranded
mode="${1:-merge}"

cd "$(git rev-parse --show-toplevel)"

if [ "$mode" = "--check" ]; then
  python3 tool/check_branding.py || echo "→ settle the branding above (tool/check_branding.py --fix does the l10n ones)"
  flutter pub get >/dev/null
  flutter analyze
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
if git ls-remote --exit-code --heads origin "$REBRANDED" >/dev/null 2>&1 \
   && ! git rev-parse -q --verify "refs/heads/$REBRANDED" >/dev/null; then
  git fetch --no-tags origin "$REBRANDED:$REBRANDED"
fi

# A snapshot of the upstream at $1, rebranded, as a commit on $REBRANDED (its
# parent: the last snapshot, or $2 the first time, so the history is shared).
snapshot() {
  local rev="$1" parent="$2" tmp tree commit
  tmp=$(mktemp -d)
  git worktree add -q --detach "$tmp/src" "$rev"
  python3 tool/rebrand.py --tree "$tmp/src" >/dev/null
  git -C "$tmp/src" add -A >/dev/null
  tree=$(git -C "$tmp/src" write-tree)
  commit=$(git commit-tree "$tree" -p "$parent" -m "upstream $(git rev-parse --short "$rev"), rebranded")
  git update-ref "refs/heads/$REBRANDED" "$commit"
  git worktree remove --force "$tmp/src"
  rm -rf "$tmp"
}

# A shallow clone needs more history before the two sides meet.
for _ in 1 2 3 4 5 6; do
  git merge-base HEAD "upstream/$UPSTREAM_BRANCH" >/dev/null 2>&1 && break
  git fetch --no-tags --deepen=300 upstream "$UPSTREAM_BRANCH"
  git fetch --no-tags --deepen=300 origin HEAD 2>/dev/null || true
done
base=$(git merge-base HEAD "upstream/$UPSTREAM_BRANCH")

# Once: the rebranded snapshot of the last upstream commit this project has,
# recorded as merged (keeping our files), to be the common ancestor.
if ! git rev-parse -q --verify "refs/heads/$REBRANDED" >/dev/null; then
  echo "First run: recording the upstream's state at $(git rev-parse --short "$base") as the common ancestor."
  snapshot "$base" "$base"
  git merge -q -s ours --no-edit -m "chore: record the rebranded upstream $(git rev-parse --short "$base") as the common ancestor" "$REBRANDED"
fi

last=$(git rev-parse "$REBRANDED")
count=$(git rev-list --count "$(git merge-base HEAD "$REBRANDED")..upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "?")
echo "upstream/$UPSTREAM_BRANCH: $(git rev-parse --short "upstream/$UPSTREAM_BRANCH"); the last rebranded snapshot: $(git log -1 --format=%s "$REBRANDED")"
if [ "$mode" = "--bootstrap" ]; then exit 0; fi

# Not again for what is already there.
if [ "$(git log -1 --format=%s "$REBRANDED" | sed -E 's/^upstream ([0-9a-f]+),.*/\1/')" = "$(git rev-parse --short "upstream/$UPSTREAM_BRANCH")" ]; then
  echo "Nothing new in the upstream since the last snapshot."
  git merge-base --is-ancestor "$REBRANDED" HEAD && exit 0
else
  snapshot "upstream/$UPSTREAM_BRANCH" "$last"
fi

echo; echo "What changed, by folder (not counting the adapters we do not use):"
git diff --dirstat=files,0 "$last" "$REBRANDED" \
  | grep -v "kernel/claude_code\|kernel/codex\|^ *[0-9.]*% site/" || true
echo; git log --oneline "$(git merge-base HEAD upstream/$UPSTREAM_BRANCH)..upstream/$UPSTREAM_BRANCH" | head -60

here=$(git rev-parse --abbrev-ref HEAD)
if [ "$mode" = "--report" ]; then
  git checkout -q --detach
  if git merge --no-commit --no-ff "$REBRANDED" >/dev/null 2>&1; then
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
if git merge --no-ff -m "chore: merge upstream $(git rev-parse --short "upstream/$UPSTREAM_BRANCH") (rebranded)" "$REBRANDED"; then
  echo; echo "Merged on $branch. Next: tool/upstream_sync.sh --check"
else
  echo; echo "Conflicts on $branch, in:"; git diff --name-only --diff-filter=U | sed 's/^/  /'
  echo "Settle them as docs/upstream-sync.md says, 'git commit', then tool/upstream_sync.sh --check"
  exit 2
fi
