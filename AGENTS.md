# AGENTS.md — Workflow Rules

## Repository Structure

- **`origin`** = `danvitv/Glaze` (your fork) — all development happens here
- **`upstream`** = `hydall/Glaze` (upstream project) — PRs are merged here
- **`upstream/dev`** = integration branch, target for feature PRs
- **`upstream/main`** = release branch, only hotfixes and release merges go here

## Branching Strategy

### Feature Branches

Each feature = isolated branch from `upstream/dev`. Merge when done.

```
upstream/dev ─┬─► feat/memory-draft-fix ─► PR ─► merged ─► deleted
              ├─► feat/request-preview   ─► PR ─► merged ─► deleted
              └─► feat/multi-vector      ─► PR ─► merged ─► deleted
```

```bash
# Sync dev before starting
git fetch upstream && git push origin upstream/dev:refs/heads/dev

# Create feature branch
git checkout -b feat/my-feature upstream/dev

# Work, commit, push
git push -u origin feat/my-feature

# Create PR targeting upstream/dev
gh pr create --repo hydall/Glaze --base dev ...
```

### Dependent Features

If feature B depends on unmerged feature A:

```bash
git checkout -b feat/B feat/A
# When A merges: rebase B onto updated dev
git fetch upstream && git push origin upstream/dev:refs/heads/dev
git rebase upstream/dev
```

### Hotfixes

Hotfixes branch from **`main`** (not dev), then merge into both `main` and `dev`.

```
upstream/main ─► fix/critical-crash ─┬─► PR to main ─► merged
                                      └─► cherry-pick / merge to dev
```

```bash
git checkout -b fix/critical-crash upstream/main
# ... fix the bug ...
git push -u origin fix/critical-crash
# PR to main
gh pr create --repo hydall/Glaze --base main ...
# After merge, backport to dev
git fetch upstream
git checkout -b fix/critical-crash-backport upstream/dev
git cherry-pick <commit-hash>
git push -u origin fix/critical-crash-backport
gh pr create --repo hydall/Glaze --base dev ...
```

## Release Cadence

- **Ship features as they're ready**, don't batch for weeks
- Each version has a plan (tracked in Trello): bugfixes, features, etc.
- A feature is "ready" when it works without breaking the app
- Hotfixes ship ASAP — don't make people wait

## Rules

- **No direct commits to `dev` or `main`** — always use feature branches
- **All feature PRs target `upstream/dev`**, never `main`
- **Hotfix PRs target `upstream/main`**, then backport to `dev`
- **Delete merged branches** — both local and remote
- **Keep `origin/dev` in sync** with upstream before creating new branches
- **Run `npm run lint && npm run build`** before committing

## Current Branches

| Branch | Purpose | PR |
|--------|---------|----|
| `origin/dev` | Mirror of upstream integration branch | No PR |
| `refactor/cloud-sync` | Async integrity, composable decomposition, cloud sync | #122 |
| `fix/memorybook-draft-and-request-preview` | macro_name in drafts, request preview cleanup | #123 |

## Before Starting Work

1. `git branch --show-current` — make sure you're on the right branch
2. `git fetch upstream && git push origin upstream/dev:refs/heads/dev` — sync
3. `git checkout -b feat/xxx upstream/dev` — create feature branch
4. `npm run lint && npm run build` — verify before committing

## Code Rules (lazy-loaded)

Detailed rules are split into topic files. CLAUDE.md tells you which to read when.
When in doubt, read all that apply before editing:

| Topic | File |
|-------|------|
| Generation lifecycle, abort, genId, streaming | `docs/rules/generation.md` |
| Race conditions, async boundaries, ownership | `docs/rules/race-conditions.md` |
| Vue components, composables, state modules | `docs/rules/vue-components.md` |
| IndexedDB, patchChatData, crash recovery | `docs/rules/database.md` |
| Formal invariants with code references | `docs/INVARIANTS.md` |

## Roadmap Maintenance

- `docs/Roadmap.md` must be kept current during implementation, not updated retroactively.
- Break roadmap work into smaller concrete subtasks instead of leaving large vague items.
- For each task: record completion (`done`/`not done`) and testing (`tested`/`not tested`).
- Partial work → split into separate follow-up subtasks, don't leave ambiguous mixed-status items.

## Cleanup Checklist After Merge

- [ ] Delete local branch: `git branch -D feat/xxx`
- [ ] Delete remote branch: `git push origin --delete feat/xxx`
- [ ] Sync `origin/dev`: `git fetch upstream && git push origin upstream/dev:refs/heads/dev`
- [ ] Verify no stale references: `git branch -a`
