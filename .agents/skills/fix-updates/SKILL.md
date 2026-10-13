---
name: fix-updates
description: Diagnose and fix a failing "Update Fork" workflow run in the limwa/nixpkgs fork. Covers all three failure modes - a transient GitHub API error, an expired UPDATE_FORK_PAT, and rebase conflicts where a vendored patch fights with upstream. Use whenever the user says the Update Fork action or workflow is failing, red, or hasn't run, or asks why one of the fork's branches has fallen behind upstream, or asks to rebase a fork branch onto its upstream counterpart. Reaches for this even without the workflow name - "why is the rebase stuck", "the fork sync keeps erroring", "update-fork is broken" all mean this skill.
---

## Preamble

The `Update Fork` workflow (@.github/workflows/update-fork.yml) keeps the fork's branches current. It has two jobs, and they fail for unrelated reasons:

- **sync** runs `gh repo sync <repo> -b <branch>` once per branch in a matrix. Those branches are pure mirrors with nothing of the fork's own on top, so the only things that can go wrong are the `UPDATE_FORK_PAT` secret and GitHub having a bad day.
- **rebase** runs once per `from`/`to` pair in a matrix: check out `to`, `git rebase <from>`, then `git push --force-with-lease`. The `to` branches carry the fork's own patches, and those are what the rebase fights over.

Do not hardcode branch names from memory or from this document — the matrix changes, and a stale name sends `git` off to rebase the wrong branch. Read the pairs out of the workflow file, and read the pair for a specific failure out of that job's **name**, which is formatted `Rebase (<from>, <to>)`. `triage.sh` already parses it that way.

Two consequences of that shape are worth internalising before reading any log. First, rebase `needs: [sync]`, so a dead PAT hides the rebase entirely — the rebase jobs report as `skipped`, and a skipped job says nothing about whether the rebase would have worked. Second, because rebase ends in a force-push, any fix has to be pushed the same way; a fix that only exists in a local clone is erased by the next scheduled run.

## Instructions

1. **Triage first.** Run:

   ```bash
   .agents/skills/fix-updates/scripts/triage.sh
   ```

   It picks the run, classifies every failing job from the one log line that distinguishes the three modes, and for a rebase conflict reads the offending commit's trailers and works out whether the upstream patch has already landed in the branch being rebased onto. Read its verdict and do what it says — the classification below exists to explain *why* it decided what it did, and to catch the case where it does not recognise a signature.

   Pass `--run <id>` when the user names a specific run. That switch also means "explain this one", so it keeps going even when a later run already succeeded. Without it, a green successor ends the investigation, because a red run from last week that has since been followed by a green one is nobody's problem.

   A `skipped` rebase job is not a diagnosis. If sync failed, fix sync and re-diagnose the run that follows.

2. **Transient GitHub error (HTTP 5xx).** GitHub's API returned a server error. Nothing is wrong with the repository, and the evidence is in the shape of the failure: usually one sync job fails while its siblings, using the very same token moments later, succeed.

   Before recommending anything, establish whether this failure is still live. A user asking about a run from last week is often describing a problem that has since resolved itself, and telling them to rerun a healed run is worse than saying nothing — a rerun re-syncs against *today's* upstream, so it cannot reproduce a fault from ten days ago.

   ```bash
   gh run list -R limwa/nixpkgs --workflow=update-fork.yml --limit 5
   ```

   If a later run succeeded, there is nothing to fix; say so, and mention what did resolve it. Only if the failure is the current state does the timing rule apply, and it exists because the workflow runs on a six-hour cron: a failure younger than roughly ninety minutes will most likely clear on the next tick by itself, and rerunning immediately just spends API budget against an endpoint that is already struggling. Past that, retry it:

   ```bash
   gh run rerun <run_id> --failed
   ```

   Either way this mode needs no repository changes, so there is nothing to verify afterwards beyond the rerun turning green.

3. **Expired PAT (HTTP 401 on every sync job).** The `UPDATE_FORK_PAT` secret was dead. This is the one mode the agent cannot fix: only the user can mint a new PAT and replace the secret in the repository's Actions settings.

   Check whether it still is, though, before sending someone off to rotate a working token. `gh secret list -R limwa/nixpkgs` reports when the secret was last changed, and a 401 followed by a green run usually means it was already rotated:

   ```bash
   gh secret list -R limwa/nixpkgs
   ```

   If 401s are current, tell the user plainly and stop. Do not rerun — the token is the same one that just failed, so a rerun fails identically, and a stream of red runs is harder to read than one clear explanation.

4. **Rebase conflict.** This is the only mode that needs a decision, and the rest of these steps are for it. If triage printed `DROP` or `RE-VENDOR`, follow that verdict. If it printed `UNDECIDED`, the commit carries no `X-Original-*` trailers, so there is no upstream reference to check it against — it was hand-carried before the convention existed. Do not guess; show the user the commit, its diff, and the conflicted files, and ask.

   Reproduce the failure locally before changing anything. Rebase conflicts are history-dependent, so a clone that cannot see enough of the graph will either fail to reproduce or reproduce something subtly different:

   ```bash
   git fetch origin <from> <to>
   git rev-parse --is-shallow-repository    # 'true' means the clone is too shallow to rebase
   ```

   If it is shallow, deepen it for these two branches (`git fetch --unshallow origin <to>`, then fetch `<from>`) and check again. A `git merge-base` that returns nothing despite both branches existing is the symptom.

   Then redo exactly what the workflow does, on a scratch branch so the real one is never mid-rebase:

   ```bash
   git switch -c fix/<to> origin/<to>
   git rebase origin/<from>
   ```

   Git stops at the first conflicting commit, and the log's `error: could not apply <sha>...` names it. Confirm it is the same commit triage identified.

5. **Drop the stale commit, or replace it.** Both verdicts start the same way — get the offending commit off the branch — and differ in what goes on top.

   ```bash
   git rebase --skip
   ```

   This is the "drop" half of either fix, and it is not a workaround: skipping is the correct resolution precisely when the vendored copy is redundant or superseded. Git then replays the remaining commits, and **it may stop again on the next one** — each vendored patch is its own conflict-prone unit, so expect a loop of `--skip` and `git rebase --continue` until the rebase finishes. Check what you ended up with before going further:

   ```bash
   git log --oneline origin/<from>..HEAD
   ```

   For `DROP`, that is the end of the repair. The commit is gone, upstream's version of the files is already in the branch, and pushing restores the workflow.

   **Sound the DROP out before acting on it.** "The upstream commit is in `<from>`" is weaker evidence than it looks: it proves those upstream commits landed, not that this fork commit was their counterpart. Two different patches can both be present and still conflict with each other perfectly legitimately, and dropping on that evidence alone loses work. Compare the dropped commit's diff against what `<from>` actually contains for those same files — if `<from>` carries a commit with the same subject and a near-identical diff, the fork copy was genuinely superseded and dropping is right. If the two implementations really differ, the fork commit is a deliberate local change rather than a stale duplicate, and it should be reworked, not dropped. Getting this wrong is the one way this skill can destroy work rather than merely delay it.

   For `RE-VENDOR`, the patch is still needed but the vendored copy is stale — typically because the PR author pushed conflict fixes after the fork vendored it. Re-vendor the current head, which picks up those fixes:

   The vendor-pr script has two preconditions it enforces itself, but satisfy them deliberately rather than letting it refuse: it must be invoked with its own required branch checked out (named in its step 0 and in `REQUIRED_CHECKOUT` at the top of the script) and with a clean tree.

   ```bash
   git status --porcelain                    # must print nothing
   git switch <vendor-pr's required branch>
   .agents/skills/vendor-pr/scripts/vendor-patch.sh --branch <to> --pr <number> --dry-run
   ```

   Show the user the preview and confirm before the real run, then run it without `--dry-run`.

   **Order matters here, and the reason is the vendor-pr script's first guard.** It refuses to vendor a patch whose `X-Original-Range` overlaps one already recorded on the target branch — which the stale commit is still doing if it has not been dropped yet. So the skip above has to happen before the re-vendor, not after. Skipping first also removes a commit that would otherwise conflict again on the very next rebase.

6. **Push.** The workflow force-pushes these branches, so the repair has to as well, and `--force-with-lease` is what keeps it from clobbering a concurrent workflow push:

   ```bash
   git push --force-with-lease origin <local-scratch-branch>:<to>
   ```

   Confirm with the user before pushing — it rewrites a shared branch, and the vendor-pr skill's habit of handing the push back to them applies here too. If the push is rejected, the workflow moved the branch in between; re-fetch and redo rather than reaching for `--force`.

   Push only after the whole repair is settled, never in between. A half-applied repair left on the remote leaves the next scheduled run to trip over the same conflict, and if it is a `DROP` the intermediate state is a branch missing a patch that the next run may not be able to reconstruct.

7. **Verify by triggering the workflow.** A fix that was never exercised is not a fix:

   ```bash
   gh workflow run update-fork.yml -R limwa/nixpkgs
   ```

   Then watch it. If it is green, report what was wrong, what was done, and the new head of the branch. If it fails again, the re-diagnose from step 1 — a second failure on the same branch usually means another vendored commit needs the same treatment, not that the first repair was wrong.

## Notes

- **The three modes have distinguishable shapes, not just distinguishable messages.** One sync job failing while its siblings succeed points at GitHub; all of them failing identically points at the token. The triage script leans on this, which is why it looks at all failing jobs rather than the first one it finds.
- **`skipped` is not `success`.** A run whose sync jobs died reports its rebase jobs as skipped. Judging the rebase by those jobs tells you nothing about whether the rebase works, so do not treat an all-skipped run as a healthy one.
- **More than one vendored commit can conflict.** The log's `Rebasing (3/5)` is the count of commits left, not the number that will fail. Iterate.
- **Force-pushing `to` races the cron.** If a scheduled run starts while a repair is in flight it will push the same branch, and one of the two pushes loses. That is what `--force-with-lease` is for — a rejected push means re-fetch and redo, not `--force`.
- **`git rebase --skip` is a decision, not a dodge.** It is right when the vendored commit is redundant or superseded, and wrong when the fork genuinely needs a patch that upstream has not taken. The trailers are what tell the two apart; without them, ask rather than skip.
- **A green run does not mean the fork's patches survived.** A rebase conflict resolved by dropping commits leaves the branch green and the patches gone, and nothing in the workflow notices. When a repair drops commits, check afterwards what the branch carries versus what it used to — `git log <from>..<to>` should still show the fork's own work.
