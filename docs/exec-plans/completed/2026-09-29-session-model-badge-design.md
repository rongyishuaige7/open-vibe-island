# Session row model badge

## Scope

Session rows show the terminal name (e.g. `Ghostty`) as a side badge. With
several sessions in the same terminal every row carries the same word. Replace
it with the model the session is running on, and keep the terminal as the
fallback and in the hover text.

Non-goals: changing jump targets, the closed island, or adding a setting.

## Data flow

- Claude: `ClaudeSessionMetadata.model` already exists. It comes from the
  SessionStart hook and from assistant `message.model` in transcripts.
  Transcript discovery now skips `<synthetic>` (locally generated error or
  interrupt replies), so a trailing API error no longer hides the real model.
- Codex: `CodexSessionMetadata` gains `model`. It is filled from the required
  `model` field of hook payloads, and from `turn_context.model` in rollouts,
  which Codex writes on every turn, so `/model` switches show up on the next turn.
  The bridge merge, discovery merge and rollout reducer carry it through.
- `SessionState` keeps the known Codex model when a metadata update has none,
  because tail-only rollout watchers can emit updates before they see a
  `turn_context`.
- OpenCode, Cursor and Pi already store `model`; they use the same badge.

## Display

`SessionModelLabel.display(for:)` in OpenIslandCore:

- `claude-opus-5-5` / `claude-opus-5.5` → `Opus 5.5`, `claude-3-5-sonnet-20241022` → `Sonnet 3.5`;
  Bedrock/Vertex suffixes, `[1m]` and provider prefixes are dropped.
- Other ids stay as-is (`gpt-5-codex`), clipped to 18 characters.
- Empty values and `<synthetic>` give no label.

The row badge uses the model label first, then the terminal name. Hover shows
`<raw model> · <terminal>`.

## Risks

- A Claude session that never reported a model (older transcripts, hook-only
  sessions before the first assistant reply) still shows the terminal.
- Persisted sessions decode without `model`; the field is optional.

## Verification

`SessionModelLabelTests` covers the label rules, model precedence, the rollout
reducer, the SessionState fallback, the hook payload mapping and legacy decoding.
Full suite: `swift test --skip KeystrokeInjectorTests`.
