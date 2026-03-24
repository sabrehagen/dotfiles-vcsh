#!/bin/sh
# Test vcsh unclobber hooks and overlays.
#
# Covered scenarios:
#   1. vcsh clone          — pre/post-merge hooks
#   2. vcsh run git checkout / vcsh <repo> checkout — run-unclobber overlay
#   3. vcsh run git pull / vcsh <repo> pull         — run-unclobber overlay
#   4. vcsh pull (all repos)                        — pull-unclobber overlay
#
# In every case: original files are restored after the operation and
# appear as unstaged changes in git.

set -e

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

check_eq() {
	desc="$1"; expected="$2"; actual="$3"
	if [ "$actual" = "$expected" ]; then pass "$desc"
	else fail "$desc (expected: '$expected', got: '$actual')"
	fi
}
check_not_exists() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1 ($2 should not exist)"; fi; }
check_modified()   {
	_status="$(git --git-dir="$GIT_DIR" --work-tree="$WORKTREE" status --porcelain)"
	if printf '%s\n' "$_status" | grep -q "$2"; then pass "$1"
	else fail "$1 (not modified: $2)"
	fi
}

# ── Setup ────────────────────────────────────────────────────────────────────

TESTDIR=$(mktemp -d /tmp/vcsh-test.XXXXXX)
WORKTREE="$TESTDIR/home"
REMOTE="$TESTDIR/remote.git"
REPO_D="$TESTDIR/repo.d"
mkdir -p "$WORKTREE" "$REPO_D"

cleanup() { unset VCSH_BASE VCSH_REPO_D; rm -rf "$TESTDIR"; }
trap cleanup EXIT

export VCSH_BASE="$WORKTREE"
export VCSH_REPO_D="$REPO_D"
GIT_DIR="$REPO_D/test-repo.git"

# ── Build remote ─────────────────────────────────────────────────────────────
# master:  .bashrc, notes.txt
# feature: .bashrc, notes.txt, extra.txt  (extra.txt new on this branch)

WORK=$(mktemp -d)
git -C "$WORK" init -q
git -C "$WORK" checkout -q -b master
printf 'repo .bashrc\n'   > "$WORK/.bashrc"
printf 'repo notes.txt\n' > "$WORK/notes.txt"
git -C "$WORK" add .
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "master"
git -C "$WORK" checkout -q -b feature
printf 'repo extra.txt\n' > "$WORK/extra.txt"
git -C "$WORK" add .
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "feature adds extra.txt"
git clone -q --bare "$WORK" "$REMOTE"
git -C "$REMOTE" symbolic-ref HEAD refs/heads/master
rm -rf "$WORK"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Accept repo versions so git is clean, then recreate pre-existing conflicts
reset_and_conflict() {
	git --git-dir="$GIT_DIR" --work-tree="$WORKTREE" checkout -q -- .
	printf 'my .bashrc\n'   > "$WORKTREE/.bashrc"
	printf 'my notes.txt\n' > "$WORKTREE/notes.txt"
}

# ── 1. clone ──────────────────────────────────────────────────────────────────

printf '\n=== 1. clone (pre/post-merge hooks) ===\n'
printf 'my .bashrc\n'   > "$WORKTREE/.bashrc"
printf 'my notes.txt\n' > "$WORKTREE/notes.txt"
vcsh clone "$REMOTE" test-repo 2>&1 | grep -v '^vcsh: info'

check_eq    ".bashrc original content after clone"  "my .bashrc"   "$(cat "$WORKTREE/.bashrc")"
check_eq    "notes.txt original content after clone" "my notes.txt" "$(cat "$WORKTREE/notes.txt")"
check_not_exists "no .bashrc.vcsh-unclobber"   "$WORKTREE/.bashrc.vcsh-unclobber"
check_not_exists "no notes.txt.vcsh-unclobber" "$WORKTREE/notes.txt.vcsh-unclobber"
check_modified   "git sees .bashrc modified"   ".bashrc"
check_modified   "git sees notes.txt modified" "notes.txt"

# ── 2. branch switch ──────────────────────────────────────────────────────────

printf '\n=== 2. branch switch (run-unclobber overlay) ===\n'
git --git-dir="$GIT_DIR" fetch -q origin feature
printf 'my extra.txt\n' > "$WORKTREE/extra.txt"

vcsh run test-repo git checkout feature 2>&1

check_eq    "extra.txt original content after checkout" "my extra.txt" "$(cat "$WORKTREE/extra.txt")"
check_not_exists "no extra.txt.vcsh-unclobber after checkout" "$WORKTREE/extra.txt.vcsh-unclobber"
check_modified   "git sees extra.txt modified after checkout" "extra.txt"

# Shorthand form
git --git-dir="$GIT_DIR" --work-tree="$WORKTREE" checkout -q -- extra.txt
vcsh test-repo checkout master 2>&1
printf 'my extra.txt\n' > "$WORKTREE/extra.txt"
vcsh test-repo checkout feature 2>&1

check_eq    "extra.txt preserved via shorthand checkout" "my extra.txt" "$(cat "$WORKTREE/extra.txt")"
check_not_exists "no extra.txt.vcsh-unclobber via shorthand" "$WORKTREE/extra.txt.vcsh-unclobber"

# ── 3. vcsh <repo> pull ───────────────────────────────────────────────────────

printf '\n=== 3. vcsh <repo> pull (run-unclobber overlay) ===\n'

# Switch back to master; add a new commit to remote master introducing new.txt
git --git-dir="$GIT_DIR" --work-tree="$WORKTREE" checkout -q -- extra.txt
vcsh test-repo checkout master 2>&1

WORK=$(mktemp -d)
git clone -q "$REMOTE" "$WORK"
git -C "$WORK" checkout -q master
printf 'repo new.txt\n' > "$WORK/new.txt"
git -C "$WORK" add .
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "master adds new.txt"
git -C "$WORK" push -q origin master
rm -rf "$WORK"

# Pre-existing conflict for the incoming file
printf 'my new.txt\n' > "$WORKTREE/new.txt"

vcsh test-repo pull 2>&1

check_eq    "new.txt original content after pull" "my new.txt" "$(cat "$WORKTREE/new.txt")"
check_not_exists "no new.txt.vcsh-unclobber after pull" "$WORKTREE/new.txt.vcsh-unclobber"
check_modified   "git sees new.txt modified after pull" "new.txt"

# ── 4. vcsh <repo> p (git alias for pull) ────────────────────────────────────

printf '\n=== 4. vcsh <repo> p (git alias for pull) ===\n'

WORK=$(mktemp -d)
git clone -q "$REMOTE" "$WORK"
git -C "$WORK" checkout -q master
printf 'repo aliased.txt\n' > "$WORK/aliased.txt"
git -C "$WORK" add .
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "master adds aliased.txt"
git -C "$WORK" push -q origin master
rm -rf "$WORK"

printf 'my aliased.txt\n' > "$WORKTREE/aliased.txt"

vcsh test-repo p 2>&1

check_eq    "aliased.txt original content after vcsh <repo> p" "my aliased.txt" "$(cat "$WORKTREE/aliased.txt")"
check_not_exists "no aliased.txt.vcsh-unclobber after vcsh <repo> p" "$WORKTREE/aliased.txt.vcsh-unclobber"
check_modified   "git sees aliased.txt modified after vcsh <repo> p" "aliased.txt"

# ── 5. pull with tracked files locally modified ───────────────────────────────

printf '\n=== 5. pull with locally modified tracked files ===\n'

# Push a change to .bashrc on remote (already tracked and locally modified)
WORK=$(mktemp -d)
git clone -q "$REMOTE" "$WORK"
git -C "$WORK" checkout -q master
printf 'repo .bashrc v2\n' > "$WORK/.bashrc"
git -C "$WORK" add .
git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm "update .bashrc"
git -C "$WORK" push -q origin master
rm -rf "$WORK"

# .bashrc is tracked and locally modified (has "my .bashrc" not "repo .bashrc")
vcsh test-repo p 2>&1

check_eq    ".bashrc preserved after pull with tracked modification" \
	"my .bashrc" "$(cat "$WORKTREE/.bashrc")"
check_not_exists "no .bashrc.vcsh-unclobber after tracked pull" \
	"$WORKTREE/.bashrc.vcsh-unclobber"
check_modified   "git sees .bashrc modified after tracked pull" ".bashrc"

# ── 6. cleanup on failed operation ────────────────────────────────────────────

printf '\n=== 6. cleanup on failed operation ===\n'

# Force a checkout to a nonexistent ref — this will fail, but any files
# moved to .vcsh-unclobber beforehand must still be restored.
printf 'my .bashrc\n' > "$WORKTREE/.bashrc"

vcsh run test-repo git checkout nonexistent-branch-that-does-not-exist 2>&1 || true

check_eq    ".bashrc restored after failed checkout" "my .bashrc" "$(cat "$WORKTREE/.bashrc")"
check_not_exists "no .bashrc.vcsh-unclobber after failed checkout" "$WORKTREE/.bashrc.vcsh-unclobber"

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
