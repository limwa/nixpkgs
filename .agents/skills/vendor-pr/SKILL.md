---
name: vendor-pr
description: Vendor an upstream NixOS/nixpkgs pull request or commit range into the limwa/nixpkgs fork as a single squashed commit, with provenance trailers. Use this whenever the user wants to cherry-pick, backport, copy, apply, or "vendor" a patch or PR from NixOS/nixpkgs into a fork branch. Reach for this even if the user does not say "vendor" — "apply PR 12345 to the fork", "backport this chatgpt change", or "carry that upstream fix over" all mean this skill.
---

## Preamble

`limwa/nixpkgs` is a fork that carries a handful of upstream patches on top of upstream branches, so that things land in this fork before they propagate upstream on their own. The `Update Fork` workflow (defined in @.github/workflows/update-fork.yml) periodically rebases those fork branches onto their upstream counterparts, which means a vendored patch is a commit that will be dragged forward by every rebase. Vendoring therefore has to produce exactly one commit per patch: several commits rebase into several conflict-prone units, and the rebase job has no way to reason about them.

The reason this is not just `git cherry-pick` is noise. GitHub watches every commit pushed anywhere in a repository's network, and emails the author of a pull request whenever a commit message references that PR with `#123` or `owner/repo#123`. Carrying upstream's squash-merge commit across verbatim trips that detection, because nixpkgs squash-merges with `(#123)` in the subject. Vendoring ten patches would page ten unrelated maintainers for no reason. The trailers below record the same provenance in a form GitHub does not interpret as a reference.

    <title>

    Co-Authored-By: <author>
    ...

    X-Original-PR: <number>            # only when the patch came from a PR
    X-Original-Range: <base>..<head>   # always; a bare SHA when it is one commit

`X-Original-Range` is the trailer that earns its keep later. The commit is rewritten on every rebase, so nothing about it stays comparable to upstream, but this range does not move: pasting it into `git log` months later lists exactly the upstream commits that went into the patch, which is how you answer "what has upstream landed since that I am still missing?" and "did the PR move under me?". A single-commit patch records the bare SHA, which `git log <sha>` reads the same way.

The script at `scripts/vendor-patch.sh` does all of this. Do not hand-roll the `git am` plus squash dance — neither `git am` nor `git format-patch` has a `--squash` flag, and the details that matter (verbatim message cleanup, full-SHA ranges, the duplicate check) are easy to get subtly wrong.

## Instructions

0. Satisfy two preconditions before anything else: the script must be run from a working copy with `limwa-gh` checked out, **and** with a clean working tree. It refuses to run otherwise — wrong branch, detached HEAD, outside a repository, or any modified, staged, or untracked file — and says what to do about it.

   ```bash
   git rev-parse --abbrev-ref HEAD   # must print: limwa-gh
   git status --porcelain            # must print nothing
   git switch limwa-gh               # if the first does not match
   ```

   The branch precondition exists because the script is invoked by path from `.agents/`, so the working directory it lands in carries no guarantee about which branch is checked out there, while vendoring is maintenance on this repository's own working copy. The clean-tree precondition is not just about the apply: the checkout to the target branch would carry local edits along, and `git apply --index` would fold unrelated changes into the vendored commit and its diffstat. Untracked files count too.

   Both checks run ahead of every `gh` call, so a failure costs nothing and names the offending paths instead of failing after a round trip to GitHub. Only `--help` is exempt. Both are independent of `--branch`: that argument still takes any branch the rebase job carries, including `dotfiles`.

1. Establish two things before touching anything: **which branch** to vendor into, and **which patch**.

   The valid branches are the ones the rebase job in @.github/workflows/update-fork.yml carries, and the script knows them: run it with no `--branch` and it lists the accepted names. This is not arbitrary — those are the only branches that get rebased, so a patch on any other branch would never be carried forward. If the user did not name a branch, ask rather than guessing, because the choice is load-bearing (see step 3).

   The patch is either an upstream PR number or an upstream commit range (`<base>..<head>`). If the user gave neither, ask.

2. Preview before committing. Run with `--dry-run`, which resolves everything and prints the exact commit message and diffstat without touching the working tree:

   ```bash
   .agents/skills/vendor-pr/scripts/vendor-patch.sh --branch <branch> --pr <number> --dry-run
   # or
   .agents/skills/vendor-pr/scripts/vendor-patch.sh --branch <branch> --range <base>..<head> --dry-run
   ```

   Show the user the message and confirm before proceeding. The co-author list and the title come from upstream, and both are worth a look before they become permanent history.

   Note that `--dry-run` enforces the step 0 preconditions too — it refuses a dirty tree just as a real run does, rather than previewing against state it would refuse to act on.

3. Read the guards. The script hard-stops in three situations, and each one means "do not vendor this":

   - **Already vendored, or overlapping it.** The patch overlaps a range already recorded in some `X-Original-Range` trailer on that branch. Comparing ranges rather than grepping for a head SHA matters: given a recorded `A..B`, a later request for `A..C` where C descends from B mentions a SHA that appears nowhere in any message, so a string search waves it through and the patch silently re-applies B's commits as duplicate hunks. The check is per-branch, since the target branches are independent of each other.
   - **Already propagated upstream.** The change is already in the upstream branch that the target is rebased onto. This check is per-branch on purpose, because each target branch tracks a different upstream branch, and a change routinely reaches one of them days before it reaches another. The same patch is therefore redundant for one target and still worth vendoring for another. For a PR the check probes with its merge commit; for a range it probes with the head commit. When the probe cannot be answered — an unmerged PR, or a commit GitHub has never seen — the check stands down rather than guessing, so mention that you relied on the other guards instead. When the script does stop, report which upstream branch it checked so the user can see the reasoning, and ask whether they meant a different target branch.
   - **Title contains `#123`.** An upstream title that references another PR would notify that PR's authors. Ask the user for a replacement title and amend by hand.

   When the script stops, relay the reason and stop. Do not look for a workaround; every one of these guards exists to prevent a commit that the periodic rebase would fight forever.

4. Vendor for real. Re-run the same command without `--dry-run`. It applies the diff, commits with `--cleanup=verbatim`, and prints the new SHA. It checks out the target branch if you are not already on it, and rolls back to the pre-vendor commit if the diff conflicts.

   When the target is not `limwa-gh`, the script checks that branch out to make the commit and switches back to `limwa-gh` before it exits — including when it fails partway, so the working copy is left the way it was found and step 0 still holds for the next run. It does not reset away an uncommitted apply in order to force that switch; if the working copy is dirty enough to block it, the script says so and stays put.

5. Confirm the result and hand back the push. Check the commit landed as one commit with the expected trailers:

   ```bash
   git log -1 --format='%H%n%n%B'
   ```

   Report the SHA, the trailers, and the diffstat to the user. Leave the push to them unless they asked for it — the `Update Fork` workflow force-pushes these same branches with `--force-with-lease`, so a push that races the workflow will be rejected, and the user is better placed to retry.

## Notes

- The vendored tree should equal upstream's post-PR state for the files the patch touches. If the branch has drifted, the script retries with `git apply --3way` and still refuses if anything conflicts; a clean `--3way` is worth mentioning to the user since it means the patch landed with fuzz.
- A vendored commit does not automatically disappear when the patch finally propagates upstream. Once it does, drop the vendored commit during a rebase rather than vendoring again — that is the point of the hard stop in step 3.
- A rebase conflict on a fork branch is often a local commit that upstream has since merged in a different form. Before replacing the stale copy, compare patch-ids (`git show <sha> | git patch-id --stable`) against the upstream commit. If they differ, the local copy is a deliberate local change rather than a stale duplicate, and should be reworked rather than dropped — and that check needs real history, so unshallow the clone first.
