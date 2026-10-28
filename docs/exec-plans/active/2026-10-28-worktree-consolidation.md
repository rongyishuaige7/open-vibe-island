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
