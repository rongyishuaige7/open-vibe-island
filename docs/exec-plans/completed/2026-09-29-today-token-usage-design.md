# Today's token usage chip

## Problem

The island's Codex usage chip reads rate-limit windows from `~/.codex`
rollouts. With a custom `CODEX_HOME`, or a relay that returns no rate limits,
it keeps showing a stale percentage. Users who route Claude and Codex through
CC Switch already have per-request token counts in CC Switch's local log.

## Scope

- A "Today" chip in the opened island header with the Claude and Codex tokens
  logged since local midnight, cache reads and writes included, refreshed
  every 30 s. The tooltip carries exact totals, the cache-read share and
  request counts.
- A Settings > Usage toggle, on by default when `~/.cc-switch/cc-switch.db`
  exists. Strings in en, zh-Hans and zh-Hant.

## Non-goals

- Cost estimates, per-model breakdowns and history.
- Requests that bypass CC Switch.
- Writing to CC Switch's database, or relying on its daily rollup table.

## Design

- `CCSwitchUsageReader` opens the database with `SQLITE_OPEN_READONLY` and a
  200 ms busy timeout, then runs one range query over `proxy_request_logs`
  that the `(app_type, created_at)` index serves.
- `input_token_semantics` says whether `input_tokens` already contains the
  cached tokens: 1 = yes, 2 = no, 0 (older rows) = yes for Codex only.
- `TodayTokenUsageMonitor` polls on a background task, keeps today's last good
  totals when a read fails, and hides the chip when the database is missing.
- `TokenCountFormatter` keeps about three significant digits: 万/亿 (萬/億) in
  Chinese, K/M/B elsewhere.

## Risks

- CC Switch's schema is internal and can change. A failed read shows its
  SQLite error in the tooltip instead of zeros.
- CC Switch uses a rollback journal, so this read and its writes briefly block
  each other. The query is a short indexed range scan and the busy timeout
  bounds the wait.

## Verification

- `CCSwitchUsageReaderTests` on a synthetic database: per-agent sums under
  each token semantics, the local-day window, a missing database and an
  unexpected schema.
- `TokenCountFormatterTests` and `TodayTokenUsageMonitorTests`.
- The query plan checked against a real database, and the packaged build run
  against it.

## Delivery

One feature commit on `feat/today-token-usage`, merged into
`local/personal-build`. This note was added after the feature commit.
