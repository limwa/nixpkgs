#!/usr/bin/env bash
#
# Vendor an upstream patch into a limwa/nixpkgs branch as a single commit.
#
# The point of this script is to keep GitHub from notifying upstream PR authors.
# GitHub watches every commit pushed anywhere in a repository's network and
# emails the author of a pull request whenever a commit message references it
# with "#123" or "owner/repo#123". Vendoring a PR the obvious ways (cherry-picking
# the squash-merge commit, or carrying over a "(#123)" suffix) trips that
# detection. This script therefore records provenance in non-reference trailers
# that still round-trip through `git log --grep`:
#
#     <title>
#
#     Co-Authored-By: <author>
#     ...
#     X-Original-PR: <number>            # only when the patch came from a PR
#     X-Original-Range: <base>..<head>   # always; bare SHA if one commit
#
# X-Original-Range is the important one: pasting it into `git log` months later
# lists exactly the upstream commits that went into the patch, which is how you
# answer "what has upstream landed since that I am still missing?".
#
# Usage:
#   vendor-patch.sh --branch <branch> --pr <number> [--dry-run]
#   vendor-patch.sh --branch <branch> --range <base>..<head> [--dry-run]
#
# Must be run from a working copy with the `limwa-gh` branch checked out.

set -euo pipefail

UPSTREAM_REPO="${VENDOR_UPSTREAM_REPO:-NixOS/nixpkgs}"
FORK_REPO="${VENDOR_FORK_REPO:-limwa/nixpkgs}"

# The only branches that may be vendored into are the `config.to` values of the
# rebase job in .github/workflows/update-fork.yml. The matching `config.from`
# is the upstream branch that the fork branch is periodically rebased onto, and
# it is what the "has this already propagated upstream?" check compares against.
#
#   dotfiles  <- nixos-unstable
#   limwa-gh  <- master
#
# If that workflow's matrix ever changes, change it here too.
declare -A BASE_OF=(
  [dotfiles]="nixos-unstable"
  [limwa-gh]="master"
)

VALID_BRANCHES="$(printf '%s\n' "${!BASE_OF[@]}" | sort | tr '\n' ' ')"

# The branch that must be checked out in the working directory for this script
# to run at all. Note this is independent of --branch, which may still name any
# of the branches above: this guards where the script is *invoked from*, not
# what it vendors into.
REQUIRED_CHECKOUT="limwa-gh"

BRANCH=""
PR=""
RANGE=""
DRY_RUN=0

# Armed only once this run has actually moved HEAD off REQUIRED_CHECKOUT, so
# early failures — where we never left it — do not trigger a pointless switch
# back. Read by the EXIT trap.
RESTORE_BRANCH=""

die() {
  printf 'vendor-patch: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<EOF
usage: vendor-patch.sh --branch <branch> (--pr <number> | --range <base>..<head>) [--dry-run]

  --branch   branch to vendor into; one of: $VALID_BRANCHES
  --pr       upstream pull request number to vendor
  --range    upstream commit range to vendor, as <base>..<head>
  --dry-run  print the commit message that would be used and exit without
             touching the working tree

Must be run with '$REQUIRED_CHECKOUT' checked out in the working directory.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --pr)     PR="${2:-}"; shift 2 ;;
    --range)  RANGE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$BRANCH" ] || { usage >&2; die "--branch is required"; }
[ -n "${BASE_OF[$BRANCH]+set}" ] || die "'$BRANCH' is not a valid target branch (expected one of: $VALID_BRANCHES)"
[ -n "$PR" ] || [ -n "$RANGE" ] || { usage >&2; die "one of --pr or --range is required"; }
[ -n "$PR" ] && [ -n "$RANGE" ] && die "--pr and --range are mutually exclusive"
[ "$PR" ] && [[ ! "$PR" =~ ^[0-9]+$ ]] && die "--pr expects a number, got '$PR'"

# The script is invoked by path from the repository's .agents directory, so the
# working directory it lands in carries no guarantee about which branch is
# checked out there. Vendoring is maintenance on this repository's own working
# copy, so require the canonical branch and refuse otherwise instead of operating
# on whatever branch the caller happened to leave in place.
#
# This sits ahead of every `gh` call on purpose: a wrong working directory then
# fails immediately, rather than after a round trip to GitHub, and without
# having spent the duplicate-check or propagation-check API budget.
git rev-parse --git-dir >/dev/null 2>&1 \
  || die "not inside a git repository; run this from a checkout of $FORK_REPO"

CURRENT_CHECKOUT="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$CURRENT_CHECKOUT" ] \
  || die "HEAD is detached; check out '$REQUIRED_CHECKOUT' first (git switch $REQUIRED_CHECKOUT)"
[ "$CURRENT_CHECKOUT" = "$REQUIRED_CHECKOUT" ] \
  || die "must be run with '$REQUIRED_CHECKOUT' checked out, but HEAD is on '$CURRENT_CHECKOUT'; run 'git switch $REQUIRED_CHECKOUT' first"

# A dirty tree makes everything downstream untrustworthy, not just the apply:
# the checkout further down would carry the changes onto the target branch, and
# `git apply --index` would fold unrelated edits into the vendored commit and its
# diffstat. Refuse here rather than after resolving the patch over the network,
# so a dirty tree costs nothing and names the offending paths. Untracked files
# count, since `git checkout` will refuse to clobber them anyway.
#
# This also means the checkout below always moves a clean tree, which is what
# lets the EXIT trap switch back without having to reset anything away.
DIRTY="$(git status --porcelain)"
[ -z "$DIRTY" ] \
  || die "$(printf 'working tree is dirty; commit or stash first:\n%s' "$DIRTY" \
          | awk 'NR <= 10; END { if (NR > 10) printf "  ... and %d more\n", NR - 10 }')"

BASE_BRANCH="${BASE_OF[$BRANCH]}"

# ---------------------------------------------------------------------------
# Resolve the patch into the five things we need: title, provenance trailers,
# co-author lines, head SHA, and the diff itself.
# ---------------------------------------------------------------------------

TMPDIR_VENDOR="$(mktemp -d)"

# Two jobs on the way out: drop the temp dir, and hand the working copy back
# the way we found it. The exit status is saved and re-raised explicitly, since
# a trap that ends in a failing command would otherwise mask the real result.
cleanup() {
  local rc=$?
  trap - EXIT

  rm -rf "$TMPDIR_VENDOR"

  if [ -n "$RESTORE_BRANCH" ]; then
    # A failure here usually means the tree still carries an uncommitted apply
    # (git commit having failed, say). Do not reset that away to force the
    # switch — say so and leave the user on the branch, where they can recover.
    if git switch -q "$RESTORE_BRANCH" 2>/dev/null; then
      printf 'vendor-patch: switched back to %s\n' "$RESTORE_BRANCH"
    else
      printf 'vendor-patch: could not switch back to %s; still on %s with local changes\n' \
        "$RESTORE_BRANCH" "$BRANCH" >&2
    fi
  fi

  exit "$rc"
}
trap cleanup EXIT

if [ -n "$PR" ]; then

  # `gh` embeds its own jq, so use `gh ... -q` rather than piping to a separate
  # jq binary — jq is not installed everywhere gh is.
  pr_field() { gh pr view "$PR" -R "$UPSTREAM_REPO" --json "$1" -q "$2" 2>/dev/null; }

  pr_field title .title >/dev/null \
    || die "could not read $UPSTREAM_REPO#$PR (does it exist?)"

  TITLE="$(pr_field title .title)"
  HEAD_SHA="$(pr_field headRefOid .headRefOid)"
  STATE="$(pr_field state .state)"
  PROBE_SHA="$(pr_field mergeCommit 'if .mergeCommit then .mergeCommit.oid else "" end')"
  URL="$(pr_field url .url)"

  # A PR that is not merged has no upstream commit to look for in the
  # propagation check, and an open PR genuinely is not upstream yet.
  [ "$STATE" = "MERGED" ] || PROBE_SHA=""

  # `authors` on each commit is GitHub's merged view: the linked account(s) for
  # the commit plus anyone picked up from Co-authored-by: trailers in the message.
  # That superset is what we credit, so nobody who contributed gets dropped.
  # The reduce keeps first-appearance order, since the trailers are appended in
  # roughly the order people helped.
  COAUTHORS="$(gh pr view "$PR" -R "$UPSTREAM_REPO" --json commits --jq '
    reduce .commits[].authors[] as $a
      ([]; if any(.[]; ((.login // .email) == ($a.login // $a.email)))
           then . else . + [$a] end)
    | .[] | "Co-Authored-By: \(.name) <\(.email)>"')"

  gh pr diff "$PR" -R "$UPSTREAM_REPO" > "$TMPDIR_VENDOR/patch.diff" \
    || die "could not fetch the diff for $UPSTREAM_REPO#$PR"

  BASE_SHA="$(pr_field baseRefOid .baseRefOid)"
  COMMIT_COUNT="$(gh pr view "$PR" -R "$UPSTREAM_REPO" --json commits -q '.commits | length')"

  # X-Original-Range has to survive being pasted into `git log` months later, so
  # always spell it as full SHAs. A single-commit patch gets the bare SHA, which
  # `git log <sha>` also reads as "just this one commit".
  if [ "$COMMIT_COUNT" = "1" ]; then
    RANGE_TRAILER="$HEAD_SHA"
  else
    RANGE_TRAILER="$BASE_SHA..$HEAD_SHA"
  fi

  PROVENANCE=$(printf 'X-Original-PR: %s\nX-Original-Range: %s' "$PR" "$RANGE_TRAILER")
  SOURCE_DESC="$UPSTREAM_REPO#$PR"
else
  case "$RANGE" in
    *..*) ;;
    *) die "--range expects <base>..<head>, got '$RANGE'" ;;
  esac
  RANGE_BASE="${RANGE%%..*}"
  RANGE_HEAD="${RANGE##*..}"

  git rev-parse --verify --quiet "${RANGE_BASE}^{commit}" >/dev/null \
    || die "'$RANGE_BASE' is not a commit in this repository"
  git rev-parse --verify --quiet "${RANGE_HEAD}^{commit}" >/dev/null \
    || die "'$RANGE_HEAD' is not a commit in this repository"

  # Resolve to full SHAs up front so the trailer is unambiguous later, and so the
  # duplicate check has a stable string to grep for.
  BASE_SHA="$(git rev-parse "${RANGE_BASE}^{commit}")"
  HEAD_SHA="$(git rev-parse "${RANGE_HEAD}^{commit}")"
  COMMIT_COUNT="$(git rev-list --count "$BASE_SHA..$HEAD_SHA")"

  TITLE="$(git log -1 --format=%s "$HEAD_SHA")"
  STATE="n/a"
  URL=""

  # A range has no merge commit to probe with, but the head commit answers the
  # same "has this reached the base branch yet?" question. Leaving this empty
  # would silently skip the check, which is exactly the hole a raw range falls
  # into. If the head is not an upstream commit at all the compare call simply
  # fails and we proceed, which is the right way to fail.
  PROBE_SHA="$HEAD_SHA"

  # No PR means no GitHub-parsed author graph, so fall back to the literal
  # authors recorded in the commits themselves.
  COAUTHORS="$(git log --format='%an <%ae>' "$BASE_SHA..$HEAD_SHA" \
    | awk '!seen[$0]++' \
    | sed 's/^/Co-Authored-By: /')"

  git diff "$BASE_SHA..$HEAD_SHA" > "$TMPDIR_VENDOR/patch.diff" \
    || die "could not diff $RANGE"

  if [ "$COMMIT_COUNT" = "1" ]; then
    RANGE_TRAILER="$HEAD_SHA"
  else
    RANGE_TRAILER="$BASE_SHA..$HEAD_SHA"
  fi

  PROVENANCE="X-Original-Range: $RANGE_TRAILER"
  SOURCE_DESC="range $RANGE"
fi

[ -s "$TMPDIR_VENDOR/patch.diff" ] || die "$SOURCE_DESC has an empty diff; nothing to vendor"

# A PR title can itself contain "#123", which is exactly the reference syntax we
# are trying to avoid. Catch it here rather than let it reach a push.
if printf '%s' "$TITLE" | grep -qE '#[0-9]+'; then
  die "PR title contains a '#<number>' reference ('$TITLE'), which would notify upstream authors; rename the vendored commit by hand"
fi

{
  printf '%s\n\n' "$TITLE"
  [ -n "$COAUTHORS" ] && printf '%s\n' "$COAUTHORS"
  printf '%s\n' "$PROVENANCE"
} > "$TMPDIR_VENDOR/message.txt"

# ---------------------------------------------------------------------------
# Guards. Each of these is a hard stop: continuing past any of them produces a
# redundant commit that the periodic rebase will fight forever.
# ---------------------------------------------------------------------------

# 1. Does this range overlap work already vendored on this branch?
#
#    Not a containment query over the fork's branches, because there isn't
#    anything to contain: vendoring rewrites the patch into a commit with a new
#    SHA, so the upstream head is never in this branch's history. `merge-base`
#    and `branches-where-head` both come back empty for exactly that reason.
#
#    The durable record is X-Original-Range, which every vendored commit carries,
#    so read the ranges already recorded on the branch and ask the upstream repo
#    whether this one overlaps them. A plain string grep for the head SHA is not
#    enough: given a recorded `A..B`, a later request for `A..C` where C
#    descends from B mentions a SHA that appears nowhere in the message, so the
#    grep waves it through and the patch re-applies B's commits as duplicate
#    hunks. Comparing the ranges catches that, and also covers the same upstream
#    work vendored earlier under the other input form, since both forms record
#    the same head.
recorded_ranges() {
  git log --format='%B' "$BRANCH" 2>/dev/null \
    | grep '^X-Original-Range:' | cut -d' ' -f2- | sort -u
}

# "ahead" and "identical" both mean the left side is an ancestor-or-equal of the
# right, which is the only sense in which a commit is "in" a branch.
contains() { # contains <commit> <branch-or-range-endpoint>
  case "$(gh api "repos/$UPSTREAM_REPO/compare/$1...$2" --jq .status 2>/dev/null || echo unknown)" in
    ahead|identical) return 0 ;;
    *)              return 1 ;;
  esac
}

while read -r RECORDED; do
  [ -n "$RECORDED" ] || continue

  # Cheapest case first: an exact re-vendor needs no API call at all.
  [ "$RECORDED" = "$RANGE_TRAILER" ] && \
    die "'$BRANCH' already vendors exactly $RANGE_TRAILER; nothing to do"

  case "$RECORDED" in
    *..*) REC_HEAD="${RECORDED##*..}" ;;
    *)    REC_HEAD="$RECORDED" ;;
  esac

  # Disjoint when the recorded head is already inside the new range's base —
  # everything vendored before is simply older than where this patch starts.
  contains "$REC_HEAD" "$BASE_SHA" && continue

  # Otherwise the recorded work is not in the new base, so if it *is* reachable
  # from the new head, this patch would re-apply commits that are already here.
  if contains "$REC_HEAD" "$HEAD_SHA"; then
    die "'$BRANCH' already vendors $RECORDED, which overlaps $RANGE_TRAILER; re-vendoring would duplicate those commits"
  fi
done <<EOF
$(recorded_ranges)
EOF

# 2. Already upstream? Only relative to the branch this fork branch is actually
#    rebased onto. A PR can sit on master for days before it propagates to
#    nixos-unstable, and that is exactly the case where vendoring into `dotfiles`
#    is still the right call. For a PR we probe with its merge commit; for a
#    range we probe with the head commit, which answers the same question.
#    A probe that cannot be answered (unmerged PR, non-upstream commit) leaves
#    PROBE_SHA empty or errors out, and we proceed — failing open here is
#    correct, since the other guards still apply.
if [ -n "$PROBE_SHA" ]; then
  STATUS="$(gh api "repos/$UPSTREAM_REPO/compare/$PROBE_SHA...$BASE_BRANCH" --jq .status 2>/dev/null || echo "unknown")"
  case "$STATUS" in
    ahead|identical)
      die "$SOURCE_DESC is already merged into $UPSTREAM_REPO/$BASE_BRANCH (the branch '$BRANCH' is rebased onto); vendoring it would duplicate work upstream already did" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Apply.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  printf '=== would vendor %s into %s (rebased onto %s) ===\n\n' "$SOURCE_DESC" "$BRANCH" "$BASE_BRANCH"
  cat "$TMPDIR_VENDOR/message.txt"
  # Listing the vendored commits is a convenience, but it is only trustworthy
  # when the clone actually contains that history. In a shallow clone the range
  # resolves against a grafted boundary and `git log` walks unrelated commits,
  # so say so rather than print something misleading.
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    printf '\n--- vendored commits (%s) ---\n' "$COMMIT_COUNT"
    printf '  (not listed: this is a shallow clone, so git cannot resolve that range)\n'
  else
    VENDORED_LOG="$(git log --oneline --max-count=25 "$BASE_SHA..$HEAD_SHA" 2>/dev/null || true)"
    if [ -n "$VENDORED_LOG" ]; then
      printf '\n--- vendored commits (%s, first 25) ---\n' "$COMMIT_COUNT"
      printf '%s\n' "$VENDORED_LOG" | sed 's/^/  /'
    fi
  fi
  printf '\n--- diffstat ---\n'
  git apply --stat "$TMPDIR_VENDOR/patch.diff" 2>/dev/null || true
  exit 0
fi

git config user.name >/dev/null 2>&1 || die "git user.name is unset; the commit would fail"
git config user.email >/dev/null 2>&1 || die "git user.email is unset; the commit would fail"

# The guard above constrains where the script is *started* from, but the target
# may still be a different branch. Checking it out moves HEAD off
# REQUIRED_CHECKOUT, so arm the trap's restore; it puts the user back where the
# guard expects them for the next run, rather than leaving them parked on
# `dotfiles` where any subsequent invocation would be refused.
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT" != "$BRANCH" ]; then
  git checkout "$BRANCH"
  RESTORE_BRANCH="$REQUIRED_CHECKOUT"
fi
PRE_VENDOR="$(git rev-parse HEAD)"

# Plain apply first: it is the common case and leaves the index staged so the
# commit needs no separate `git add`. If the branch has drifted from the PR's
# base, retry with --3way, which resolves most of it from blob hashes.
if ! git apply --index "$TMPDIR_VENDOR/patch.diff" 2>/dev/null; then
  printf 'vendor-patch: clean apply failed, retrying with --3way\n' >&2
  if ! git apply --3way --index "$TMPDIR_VENDOR/patch.diff"; then
    git reset --hard -q "$PRE_VENDOR"
    die "the diff does not apply to '$BRANCH' even with --3way; working tree restored to $PRE_VENDOR"
  fi
  CONFLICTS="$(git diff --name-only --diff-filter=U)"
  if [ -n "$CONFLICTS" ]; then
    git reset --hard -q "$PRE_VENDOR"
    die "conflicts in: $(printf '%s' "$CONFLICTS" | tr '\n' ' '); working tree restored to $PRE_VENDOR"
  fi
fi

# --cleanup=verbatim because the default cleanup would eat a title line that
# happens to start with '#', and because we want the trailers byte-for-byte.
git commit --cleanup=verbatim -F "$TMPDIR_VENDOR/message.txt" -q

NEW_SHA="$(git rev-parse HEAD)"

cat <<EOF

vendored $SOURCE_DESC into $BRANCH as $NEW_SHA
$(printf '%s' "$URL" | grep -q . && printf 'source: %s\n' "$URL")

$(git show --stat --format='' "$NEW_SHA" | sed '/^$/d')

next:
  git push origin $BRANCH
EOF
