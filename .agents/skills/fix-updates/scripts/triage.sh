#!/usr/bin/env bash
#
# Diagnose a failing "Update Fork" run in limwa/nixpkgs.
#
# The workflow only has three failure modes, and each one announces itself
# with a single line in the job log. Reading those lines by hand means a
# dozen `gh run view --log` calls per investigation plus a lot of squinting
# at tab-separated log output, so this does the reading and prints a verdict.
#
#   Sync job   HTTP 401: Bad credentials   -> UPDATE_FORK_PAT is dead
#   Sync job   HTTP 5xx / connection error -> GitHub-side flake
#   Rebase job error: could not apply ...  -> fork commit conflicts with from
#
# For a rebase conflict it also reads the offending commit's X-Original-*
# trailers and asks the only question that decides the fix: has the upstream
# patch already reached the branch this fork branch is being rebased onto?
#
#   already there -> DROP the vendored commit, it is redundant
#   not there     -> RE-VENDOR, the fork still needs the patch
#
# This script only reads. It never reruns, never edits, never pushes.
#
# Usage:
#   triage.sh                    # the most recent failing run
#   triage.sh --run <run-id>     # a specific run
#   triage.sh --wait-minutes 90  # how recent is "too recent to bother rerunning"

set -uo pipefail

REPO="${UPDATE_FORK_REPO:-limwa/nixpkgs}"
UPSTREAM="${UPDATE_FORK_UPSTREAM:-NixOS/nixpkgs}"
WORKFLOW="${UPDATE_FORK_WORKFLOW:-update-fork.yml}"

RUN=""
EXPLICIT=0
WAIT_MINUTES="${UPDATE_FORK_WAIT_MINUTES:-90}"

while [ $# -gt 0 ]; do
  case "$1" in
    --run)          RUN="${2:-}"; EXPLICIT=1; shift 2 ;;
    --wait-minutes) WAIT_MINUTES="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              printf 'triage: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { printf 'triage: gh is not installed\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'triage: git is not installed\n' >&2; exit 1; }

# gh prints API errors to stderr; every call here is best-effort, so silence
# them and let the caller's fallback speak. Note this means a genuine failure
# to reach the API reads as "the field is empty", which is why every branch
# below says what an empty result means instead of assuming data was there.
g() { gh "$@" 2>/dev/null; }

say()  { printf '%s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# --------------------------------------------------------------------------
# Pick the run to diagnose.
# --------------------------------------------------------------------------

# "The newest run succeeded" is the answer to most invocations, and it is
# worth stating explicitly: a red run from three days ago that has since been
# followed by a green one is not a problem anybody needs to solve.
latest_run() {
  g run list -R "$REPO" --workflow="$WORKFLOW" --limit 1 \
    --json databaseId,status,conclusion,createdAt,event \
    -q '.[0] | "\(.databaseId)\t\(.status)\t\(.conclusion)\t\(.createdAt)\t\(.event)"'
}

newest_successful_after() {  # newest_successful_after <run-id> -> "id createdAt" or empty
  g run list -R "$REPO" --workflow="$WORKFLOW" --limit 30 \
    --json databaseId,conclusion,createdAt \
    -q "[.[] | select(.conclusion == \"success\")] | first | \"\(.databaseId)\t\(.createdAt)\"" \
    | while IFS=$'\t' read -r id at; do
        [ -n "$id" ] || continue
        # Only interesting if it happened after the run we are diagnosing.
        if [ "$(date -u -d "$at" +%s 2>/dev/null || echo 0)" -gt \
             "$(date -u -d "${TARGET_CREATED:-1970-01-01T00:00:00Z}" +%s 2>/dev/null || echo 0)" ]; then
          printf '%s\t%s\n' "$id" "$at"
        fi
      done
}

if [ -z "$RUN" ]; then
  LATEST="$(latest_run)"
  [ -n "$LATEST" ] || { printf 'triage: no runs of %s found in %s\n' "$WORKFLOW" "$REPO" >&2; exit 1; }

  # `status` is completed/in_progress/queued; `conclusion` is success/failure/
  # null and is only meaningful once status is completed.
  IFS=$'\t' read -r LATEST_ID LATEST_STATUS LATEST_CONCL LATEST_AT LATEST_EVENT <<<"$LATEST"

  if [ "$LATEST_STATUS" != "completed" ]; then
    say "Most recent run $LATEST_ID is '$LATEST_STATUS' - still going."
    say "Wait for it to finish before diagnosing it:"
    say "  gh run watch -R $REPO $LATEST_ID"
    exit 0
  fi

  if [ "$LATEST_CONCL" = "success" ]; then
    say "== $WORKFLOW in $REPO =="
    say ""
    say "Most recent run: $LATEST_ID  $LATEST_CONCL  ($LATEST_AT, $LATEST_EVENT)"
    say ""
    say "NOTHING TO FIX. The newest run is green, so whatever failed earlier has"
    say "already been resolved. Stop here unless you were asked about a specific"
    say "older run, in which case pass --run <run-id>."
    exit 0
  fi

  RUN="$LATEST_ID"
  say "Most recent run $RUN is '$LATEST_CONCL' ($LATEST_AT, $LATEST_EVENT) - diagnosing it."
else
  say "Diagnosing run $RUN as requested."
fi

# Naming a run means "explain this one", so the superseded check below is
# informational rather than terminal. Auto-detection is the case where a
# green successor genuinely means there is no work left.
SUPERSEDED_NOTE=""

RUN_META="$(g run view -R "$REPO" "$RUN" --json conclusion,createdAt,event,headBranch \
  -q '"\(.conclusion)\t\(.createdAt)\t\(.event)\t\(.headBranch)"')"
[ -n "$RUN_META" ] || { printf 'triage: cannot read run %s\n' "$RUN" >&2; exit 1; }
IFS=$'\t' read -r CONCL CREATED EVENT HEADBRANCH <<<"$RUN_META"
TARGET_CREATED="$CREATED"

AGE_MIN=$(( ( $(date -u +%s) - $(date -u -d "$CREATED" +%s 2>/dev/null || date -u +%s) ) / 60 ))
AGE_H="$(( AGE_MIN / 60 ))h$(( AGE_MIN % 60 ))m"

say ""
say "  conclusion  $CONCL"
say "  started     $CREATED ($AGE_H ago)"
say "  event       $EVENT   head: $HEADBRANCH"

# Only --run can land on a superseded failure: auto-detection only ever picks
# the newest run, and if that one failed then nothing newer can be green. An
# explicitly named run can be arbitrarily old, and that distinction changes the
# advice below - a flake that already healed must not be handed a "rerun it".
#
# So there is deliberately no auto-detect successor check; the green-latest
# branch above is the only one auto-detection can reach.
SUPERSEDED=0
if [ "$EXPLICIT" = "1" ]; then
  SUCCESSOR="$(newest_successful_after "$RUN")"
  if [ -n "$SUCCESSOR" ]; then
    IFS=$'\t' read -r SID SAT <<<"$SUCCESSOR"
    SUPERSEDED=1
    SUPERSEDED_NOTE="NOTE: run $SID succeeded afterwards ($SAT), so this failure is
             historical. The diagnosis below still describes what went wrong."
  fi
fi
[ -n "$SUPERSEDED_NOTE" ] && say "$SUPERSEDED_NOTE"

# --------------------------------------------------------------------------
# Helper queries.
# --------------------------------------------------------------------------

job_lines() {  # job_lines <conclusion>
  g run view -R "$REPO" "$RUN" --json jobs \
    -q ".jobs[] | select(.conclusion == \"$1\") | \"\(.name)\t\(.databaseId)\""
}

job_log() { g run view -R "$REPO" --log --job "$1"; }

# GitHub's compare API answers "is $1 already contained in $2" without us
# having to hold either history locally. `ahead` means the right-hand side
# has the left-hand side's commits, `identical` means they are the same tip;
# `behind` and `diverged` both mean no.
contained_in() {  # contained_in <sha> <branch> -> prints "yes"/"no" + compare status
  local status
  status="$(g api "repos/$UPSTREAM/compare/$1...$2" --jq .status)"
  case "$status" in
    ahead|identical) printf 'yes (%s)\n' "$status" ;;
    "")              printf 'unknown (compare API did not answer)\n' ;;
    *)               printf 'no  (%s)\n' "$status" ;;
  esac
}

# --------------------------------------------------------------------------
# Diagnose each failing job.
# --------------------------------------------------------------------------

SYNC_401=0; SYNC_FLAKE=0; SYNC_OTHER=0; REBASE_JOBS=0

failing="$(job_lines failure)"
[ -n "$failing" ] || { say ""; say "No jobs in this run have conclusion 'failure'."; exit 0; }

while IFS=$'\t' read -r NAME JOBID; do
  [ -n "$JOBID" ] || continue
  LOG="$(job_log "$JOBID")"

  case "$NAME" in
  Sync*)
    HTTP="$(printf '%s' "$LOG" | grep -oE 'HTTP [0-9]{3}' | head -1)"
    # `gh run view --log` emits "<job>\t<step>\t<timestamp><space><message>", so
    # the message is the tail of field 3, not a field of its own.
    TELL="$(printf '%s' "$LOG" | grep -E 'Bad credentials|secondary rate|abuse|HTTP [0-9]{3}|^error:|^fatal:' \
            | head -2 | sed 's/^[^\t]*\t[^\t]*\t[0-9T:.Z-]*[ \t]\{1,\}//')"
    say ""
    say "-- Sync job: $NAME"
    say "   log says : ${HTTP:-<no HTTP status; see below>}"

    case "$HTTP" in
      "HTTP 401")
        SYNC_401=$((SYNC_401 + 1))
        say "   cause    : the UPDATE_FORK_PAT secret was expired or revoked at the"
        say "              time of this run."
        [ -n "$TELL" ] && say "              $TELL"
        if [ "$SUPERSEDED" = "1" ]; then
          say "   action   : none for this run. A later run succeeded, which means the"
          say "              secret was replaced in the meantime. If the user is"
          say "              seeing 401s now, that is a fresh expiry, not this one -"
          say "              check 'gh secret list -R $REPO' for when it last changed."
        else
          say "   action   : the user must issue a new PAT (repo scope) and replace"
          say "              the UPDATE_FORK_PAT secret in the repository's Actions"
          say "              settings. Nothing else can fix this."
        fi
        ;;
      "HTTP 5"*)
        SYNC_FLAKE=$((SYNC_FLAKE + 1))
        say "   cause    : GitHub returned a server error. Transient."
        [ -n "$TELL" ] && say "              $TELL"
        # The age rule is about a failure you are waiting to see clear on the
        # next scheduled run. Once a later run has gone green the question is
        # moot - retrying a healed run just re-syncs against today's upstream.
        if [ "$SUPERSEDED" = "1" ]; then
          say "   action   : none. A later run already succeeded, so this cleared"
          say "              itself. Retrying would accomplish nothing."
        elif [ "$AGE_MIN" -lt "$WAIT_MINUTES" ]; then
          say "   action   : this run is only $AGE_H old, so leave it. The next"
          say "              scheduled run (every 6h) will retry on its own."
        else
          say "   action   : safe to retry now -"
          say "              gh run rerun $RUN --failed"
        fi
        ;;
      *)
        SYNC_OTHER=$((SYNC_OTHER + 1))
        say "   cause    : unexpected or missing status. Read the raw log:"
        say "              gh run view -R $REPO --log --job $JOBID"
        [ -n "$TELL" ] && say "              $TELL"
        ;;
    esac
    ;;

  Rebase*)
    REBASE_JOBS=$((REBASE_JOBS + 1))

    # The job name carries the matrix pair, formatted "Rebase (<from>, <to>)".
    # Parsing it beats hardcoding the pairs, which drift when the workflow's
    # matrix changes.
    FROM="$(printf '%s' "$NAME" | sed -n 's/^Rebase (\([^,]*\), .*/\1/p')"
    TO="$(printf '%s' "$NAME" | sed -n 's/^Rebase (.*, \(.*\))$/\1/p')"
    [ -n "$FROM" ] || FROM="<from>"
    [ -n "$TO" ]   || TO="<to>"

    SHORT="$(printf '%s' "$LOG" | grep -oE 'error: could not apply [0-9a-f]{7,}\.\.\.' \
             | head -1 | grep -oE '[0-9a-f]{7,}')"
    SUBJECT="$(printf '%s' "$LOG" | grep -oE 'error: could not apply [0-9a-f]+\.\.\..*' \
             | head -1 | sed 's/^error: could not apply [0-9a-f]*\.\.\. //')"
    FILES="$(printf '%s' "$LOG" | grep -oE 'Merge conflict in .*' | sed 's/Merge conflict in //' | sort -u)"

    say ""
    say "-- Rebase job: $NAME"
    say "   rebasing : $TO  ->onto->  $FROM"

    if [ -z "$SHORT" ]; then
      say "   log says : no 'could not apply' line; this is not a rebase conflict."
      say "   action   : read the raw log:"
      say "              gh run view -R $REPO --log --job $JOBID"
      continue
    fi

    say "   conflict : $SHORT  $SUBJECT"
    [ -n "$FILES" ] && printf '%s\n' "$FILES" | head -8 | sed 's/^/              /'

    # Resolve the abbreviated sha and pull the trailers straight off the API,
    # so this works even when the commit is not in the local clone.
    FULL="$(g api "repos/$REPO/commits/$SHORT" --jq .sha)"
    MSG="$(g api "repos/$REPO/commits/$SHORT" --jq .commit.message)"
    TRAILERS="$(printf '%s\n' "$MSG" | git interpret-trailers --parse 2>/dev/null | grep '^X-Original-' || true)"

    [ -n "$TRAILERS" ] || TRAILERS="(none)"

    PR="$(printf '%s\n' "$TRAILERS" | sed -n 's/^X-Original-PR: //p' | head -1)"
    RANGE="$(printf '%s\n' "$TRAILERS" | sed -n 's/^X-Original-Range: //p' | head -1)"

    say "   trailers :"
    printf '%s\n' "$TRAILERS" | sed 's/^/              /'

    # Work out which upstream commit represents this patch, then ask whether
    # it is already in the branch we are rebasing onto.
    PROBE=""; PROBE_WHY=""
    if [ -n "$PR" ]; then
      PR_STATE="$(g pr view "$PR" -R "$UPSTREAM" --json state -q .state)"
      MERGE="$(g pr view "$PR" -R "$UPSTREAM" --json mergeCommit -q '.mergeCommit.oid // ""')"
      PR_URL="$(g pr view "$PR" -R "$UPSTREAM" --json url -q .url)"
      say "   upstream : $UPSTREAM#$PR is $PR_STATE  $PR_URL"
      if [ "$PR_STATE" = "MERGED" ] && [ -n "$MERGE" ]; then
        PROBE="$MERGE"; PROBE_WHY="PR merge commit ${MERGE:0:10}"
      fi
    fi
    if [ -z "$PROBE" ] && [ -n "$RANGE" ]; then
      PROBE="${RANGE##*..}"
      PROBE_WHY="head of X-Original-Range"
    fi

    say ""
    if [ -z "$PROBE" ]; then
      say "   VERDICT  : UNDECIDED - this commit carries no X-Original-* trailers, so"
      say "              there is no upstream reference to check against. It predates"
      say "              the vendor-pr convention and was hand-carried. Ask the user"
      say "              whether it should still exist; do not guess."
      say "              To help them decide, show the commit's diff and compare the"
      say "              files it touches against $UPSTREAM/$FROM - an upstream commit"
      say "              with the same subject and a similar diff means the fork copy"
      say "              has been superseded and can be dropped."
    else
      say "   probe    : $PROBE_WHY"
      case "$(contained_in "$PROBE" "$FROM")" in
        yes*)
          say "   VERDICT  : DROP. The upstream change is already in $UPSTREAM/$FROM,"
          say "              so this vendored copy is redundant and will only conflict"
          say "              forever. Drop it during the rebase (git rebase --skip)."
          say "              Before dropping, check that $FROM really does carry an"
          say "              equivalent of the patch - 'already in the branch' proves the"
          say "              upstream commits landed, not that this fork commit was"
          say "              their counterpart."
          ;;
        no*)
          say "   VERDICT  : RE-VENDOR. The change is NOT yet in $UPSTREAM/$FROM, so the"
          say "              fork still needs it. The vendored copy is stale, though -"
          say "              the author may have pushed conflict fixes. Drop the old"
          say "              copy, then re-vendor the current PR head with the"
          say "              vendor-pr skill (drop first, or its duplicate guard trips)."
          ;;
        *)
          say "   VERDICT  : UNDECIDED - the compare API would not answer for"
          say "              $PROBE against $FROM. Check by hand before choosing."
          ;;
      esac
    fi
    say "   full sha : ${FULL:-<could not resolve>}"
    ;;

  *)
    say ""
    say "-- $NAME (unexpected job name)"
    say "   gh run view -R $REPO --log --job $JOBID"
    ;;
  esac
done <<EOF
$failing
EOF

# --------------------------------------------------------------------------
# Summary.
# --------------------------------------------------------------------------

head_ "summary"

if [ "$SYNC_401" -gt 0 ] && [ "$SYNC_FLAKE" -gt 0 ]; then
  say "Mixed sync failures ($SYNC_401 x 401, $SYNC_FLAKE x 5xx). The 401s are real and"
  say "must be fixed at the source; the 5xx ones are noise on top of that."
elif [ "$SYNC_401" -ge 2 ]; then
  say "All $SYNC_401 sync jobs failed with 401. They share one token, so a per-branch"
  say "explanation is impossible: UPDATE_FORK_PAT has expired. Only the user can fix"
  say "this, and re-running will keep failing until they do."
elif [ "$SYNC_401" -eq 1 ]; then
  say "One sync job failed with 401 while others passed. That is unusual - the same"
  say "token served them all - so confirm by rerunning before assuming expiry."
elif [ "$SYNC_FLAKE" -gt 0 ]; then
  say "$SYNC_FLAKE sync job(s) failed with a 5xx while the rest succeeded. One token,"
  say "different outcome per branch: that is a GitHub-side flake, not a credential"
  say "problem."
fi

if [ "$SYNC_OTHER" -gt 0 ]; then
  say "$SYNC_OTHER sync job(s) failed in a way this script does not recognise. Treat"
  say "those as unknown until someone has read their logs by hand."
fi

if [ "$REBASE_JOBS" -gt 0 ]; then
  say "$REBASE_JOBS rebase job(s) hit a real conflict. This is the only mode that needs"
  say "a decision from you; see the per-job verdicts above."
fi

say ""
say "Note: rebase needs sync, so a red sync run reports the rebase jobs as skipped."
say "A skipped rebase job tells you nothing - only run this against a run whose"
say "rebase job actually executed and failed."
