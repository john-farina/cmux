# Sync Upstream

Pull the latest manaflow-ai/cmux changes into this fork and push them to origin.

Remotes in this repo: `origin` = john-farina/cmux (the fork), `upstream` = manaflow-ai/cmux. Never push to upstream.

## Steps

1. `git fetch upstream`
2. If not on main: note the current branch, `git checkout main`
3. `git merge upstream/main --no-edit`
   - On conflicts: fork-local files (`scripts/reloadp-local.sh`, `.claude/settings.json`, `.claude/commands/sync-upstream.md`, the "Fork notes" section at the bottom of CLAUDE.md) keep OUR side; upstream code keeps THEIRS. Anything ambiguous — stop and ask.
4. `git submodule update --init --recursive`
5. `git push origin main`
6. If a feature branch was checked out in step 2: `git checkout <branch> && git rebase main`. Do not force-push the branch without asking.
7. If GhosttyKit changed (ghostty submodule pointer moved), run `./scripts/setup.sh` to refresh the prebuilt xcframework, then rebuild: `./scripts/reload.sh --tag john`
8. Report: commits pulled, submodules moved, conflicts resolved, whether a rebuild happened.
