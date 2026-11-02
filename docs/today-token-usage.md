# Today's token usage

The "Today" chip in the island header opens **今日 Token 消耗统计**, one row per
source. Every number is local: there is no server and no telemetry.

| Row | Source |
|---|---|
| Claude, Codex | `~/Library/Application Support/cc-switch/cc-switch.db` (CC Switch request log) |
| Claude Pro | `ClaudeProUsageReader` local logs |
| AGY 普通池 / AGY Pro 个人池 | KEEPER, `/opt/homebrew/var/cpa-usage-keeper/app.db` |
| DSH | DeepSeek Harness host plugin ledger |

KEEPER exposes today's totals in `usage_overview_hourly_stats`, joined to
`usage_identities` for the account name. The reader cuts the window at the
user's local midnight, not KEEPER's business time zone.

## Antigravity pool vs Pro

KEEPER records no Antigravity plan: `plan_type` is empty for every
Antigravity identity and its rows carry no tier, so "Pro" cannot be derived
from the database. The island names the Pro accounts instead:

- Settings → Setup → Usage → **AGY Pro 账号**.
- Stored under the `usage.agyProAccounts` `UserDefaults` key as one
  free-form string; commas, spaces and newlines all separate accounts.
- The `@domain` is optional, matching is case-insensitive.
- Empty falls back to `KeeperUsageReader.defaultAgyProAccounts`.

Rows from those accounts land in **AGY Pro 个人池**; every other
Antigravity account lands in **AGY 普通池**, where the per-account
breakdown is available from the disclosure arrow.

## Why an external sync is needed

An Antigravity Pro profile (`~/.gemini/antigravity-cli-pro`) talks to Google
directly, not through CPA, so KEEPER never sees those requests on its own.
A local sync tool reads the profile's conversation transcripts and inserts
them into KEEPER's usage inbox under the Pro account. When that sync stops,
the Pro row reads 0 while the pool row keeps working — the pool is CPA
traffic and needs no sync.

The island only reads KEEPER. If the Pro row is 0, check the sync before
changing anything here:

```sh
launchctl print gui/$(id -u)/com.antigravity.pro-usage-sync | grep state
sqlite3 "file:/opt/homebrew/var/cpa-usage-keeper/app.db?mode=ro" \
  "SELECT COUNT(*), MAX(timestamp) FROM usage_events WHERE auth_index='1980de4a6cafcf2d'"
```

Changing the Pro account therefore means updating both the app setting and
the sync tool's target account.
