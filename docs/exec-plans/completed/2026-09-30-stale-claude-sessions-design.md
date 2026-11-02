# Stale Claude Sessions

## Problem

Closed Claude Code conversations kept showing in the island. The processes
were alive; the island mapped them to the wrong sessions:

- A process's session ID comes from its `--resume` / `--session-id` launch
  argument. After an in-process `/resume` or `/clear` it names a session
  that now lives in another tab (or nowhere), and pass 1 matched it anyway.
- `sessionIDsWithAliveProcesses` claimed sessions but not processes, so a
  process matched in pass 1 could keep a second session alive through the
  TTY/CWD fallback in pass 3.
- `adoptProcessTTYsForClaudeSessions` gave a process's TTY to the first
  session in the same folder, even one that already had a different TTY, and
  set `updatedAt = .now`, which then won the cwd-only tie-break.

Ended/hook flags are not persisted, so after an app restart every restored
row depends on this matching.

## Change

- One matcher, `claudeProcessSessionMatches`, pairs processes and sessions
  one to one. It backs both liveness and synthetic-row detection.
- Pass 1 ignores an ID match when the session's known TTY is held by another
  live Claude process. A TTY with no process left still matches, so resuming
  in a new tab keeps working.
- TTY adoption by folder only fills in a missing TTY. Replacing a known TTY
  needs the process to name the session (ID or transcript path). Adoption no
  longer touches `updatedAt`.

## Non-goals

- Persisting `isHookManaged` / `isSessionEnded` in the registry.
- Reading the live session from Claude's transcript files per process.

## Verification

`Tests/OpenIslandAppTests/ClaudeProcessLivenessTests.swift`: 9 tests with
fictional IDs and paths. 5 fail on the previous code (stale resume argument,
one process reviving two rows, TTY-agreeing resume, adoption stealing a known
TTY, adoption bumping `updatedAt`); 4 guard behaviour that must not change
(resume in a new tab, TTY move by a process that names the session, no
synthetic row for a stale-argument process, TTY-less discovered session).
