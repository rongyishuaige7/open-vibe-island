# Consolidate the Current Personal Runtime

## Problem and intended end state

Sixteen checkouts shared one Git repository, with large independent Swift build
directories and three sets of uncommitted changes. The running development app's
Mach-O build UUID matches `feat/dsh-integration-local` at `19d96ef`, including the
local Claude Pro usage changes. Keep that runtime's behavior as the baseline and
finish with one checkout at `/Users/rongyi/Developer/open-vibe-island-dsh-local`.

## Scope and decisions

- Preserve every branch, the pre-cleanup repository bundle, dirty-file patches,
  original modified files, package outputs, and harness artifacts. The verified
  archive is under `.git/maintenance-archives/20261028_095030/`; it moves with Git
  metadata when the retained checkout becomes the primary repository.
- Remove the ten clean historical feature worktrees whose heads are ancestors
  of the current runtime branch. This was explicitly authorized by the user.
- Retain the current Claude Pro message-deduplication changes and their tests.
- Integrate the existing `fix/audit-hardening` stability changes, resolving
  overlap against the personal runtime without dropping DSH, AGY, KEEPER,
  multi-home Codex discovery, or current presentation behavior.
- Preserve `feat/island-display-polish` as an alternative design in Git history.
  Its uncommitted idle-fold work changes panel height without wiring the view to
  the folded sections. Do not ship that incomplete behavior or replace the
  running app's presentation as part of filesystem cleanup.
- The standalone DSH implementation was adapted into the personal branch; the
  earlier `local` working-tree changes are also present in the retained tree.
- Keep upstream and old personal branch refs. Updating to upstream's additional
  agent integrations is a separate product change, not required for consolidation.

## Stages

1. Verify and archive pre-existing history, modifications, and ignored outputs;
   remove the ten redundant historical worktrees.
2. Verify and commit the current-runtime baseline on a consolidation branch.
3. Merge and verify the applicable stability work before committing integration.
4. Preserve the alternative UI work in a reachable Git snapshot; verify the
   redundant local patches against the retained tree before removing checkouts.
5. Promote the retained checkout to a normal repository, preserving its path,
   all shared refs, and the archive. Remove the obsolete primary checkout only
   after verifying the promoted repository and its recovery bundle.

## Verification

- Targeted Claude Pro tests for the preserved baseline.
- Repository CI harness: localization lint, documentation checks, Swift tests,
  and build, plus focused coverage of integrated stability behavior.
- Compare archived artifacts by file hashes and symlink targets; verify the Git
  bundle and preserved refs before destructive cleanup.
- Verify one remaining worktree, a clean retained checkout, and unchanged running
  app identity. Do not restart the user's app or install hooks during checks.

## Risks

The alternative UI commits and security branch were developed on different
baselines. Resolve conflicts deliberately and retain the original refs. Git
metadata promotion must preserve HEAD, index, reflogs, repository configuration,
and all backups. Installed apps and user data outside these project checkouts
are outside the cleanup scope.

## Integration evidence

- The preserved Claude Pro baseline passed all five reader tests; documentation
  and localization checks passed before baseline commit `e63d7dc` was pushed.
- The stability branch merged with three conflicted files. Resolution retained
  bridge observer event accounting, background transcript preloading, and the
  existing opt-in Warp keystroke check. The thread-safe Watch provider remains
  compatible with existing callers alongside the endpoint snapshot API.
- The integrated CI harness passed localization and documentation checks,
  623 Swift tests in 78 suites, and the package build.
- All ten uncommitted file patches in the old `local` checkout were checked
  against the integrated working tree and remain present.
- Original dirty trees are reachable through local `archive/20261028-*-wip`
  refs in addition to their saved patches and original file copies.

## Completion evidence — 2026-10-28

- Baseline commit `e63d7dc` and integration merge `0e93720` were pushed to
  `origin/chore/consolidate-current-runtime`.
- The retained checkout was promoted to an independent primary repository.
  Its Git common directory is now its own `.git` directory, with one registered
  worktree. Every pre-promotion ref was preserved; `git fsck --full --no-dangling`
  and verification of the final recovery bundle passed.
- The complete CI harness was run again at the final retained path after
  promotion. Localization lint, documentation checks, all 623 Swift tests in
  78 suites, and the Swift build passed. Evidence is in
  `.git/maintenance-archives/20261028_095030/logs/final-retained-ci.log`.
- Before removing the old primary checkout, its tracked tree was confirmed
  clean, all refs were compared, and all 294 archived files and symlinks were
  verified against the retained archive. Its only ignored files outside Git
  metadata were disposable `.build` files and the preserved `Package.resolved`.
- All 15 other original checkouts and the temporary integration checkout were
  removed. Only `/Users/rongyi/Developer/open-vibe-island-dsh-local` remains.
  Measured directory usage fell from approximately 12.99 GiB to 0.92 GiB,
  including retained recovery material and one build cache.
- The running installed development app was not restarted or replaced. PID
  `89392` retained build UUID `C96F1AC2-E4D0-3423-97D3-EFAE9D9BAB10`.
  The merged source changes require a later rebuild and launch to become active.
- See [the local workspace guide](../../local-workspace.md) for the version
  comparison, retained path, and recovery references. No remaining cleanup stage
  is open; a later app update is outside this consolidation task.
