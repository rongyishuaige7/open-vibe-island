# Pixel mascots right slot and pixel session style

## Problem

The closed island shows agent state as a count badge or a grid of colored
tiles. agent-notch (MIT) gives each agent a pixel mascot that walks while the
agent works, which reads at a glance and gives the island some character.

## Scope

- A fourth right-slot option, `mascots`: one pixel mascot per agent tool with
  a surfaced session, carrying the most urgent state among that tool's
  sessions (waiting > running > idle). Running mascots walk, waiting ones
  breathe, idle ones stay dim.
- A fifth session-state style, `pixel`: the animated dot, replaced by a pixel
  checkmark once a session completes.
- Settings cards and live previews for both; strings in en, zh-Hans and
  zh-Hant. Defaults stay `count` and `animatedDot`.

## Non-goals

- OpenAI's Codex Pets spritesheets, which are not MIT-licensed. Codex gets an
  original terminal-window mascot and every other tool a brand-colored blob.
  Loading a user-supplied sprite from disk is left for later.
- agent-notch's "finished since you last looked" state, its panel layout and
  its open/close animation.
- Changing the pill geometry: the mascots fit the existing 44pt wing.

## Design

- `PixelMascotSprites.swift` holds the sprite data, the frame timing
  (`PixelMascotMotion`) and the checkmark bitmap, with agent-notch's MIT
  notice for the adapted parts: the Claude critter frames, the shimmer and the
  checkmark.
- `PixelMascotRow` draws every mascot in one `Canvas`. A `TimelineView` ticks
  at 8 fps only while a mascot is running or waiting, and never under Reduce
  Motion.
- Cells are 1×2pt, the aspect of the terminal block characters. Claude is
  16×10pt and Codex 10×12pt; with a 2pt gap the pair is 28pt wide, the visible
  part of the MacBook right wing at the 32pt notch height.
- `AppModel.mascotSlots(for:)` keeps at most three tools in `AgentTool` order,
  reversed so Claude sits outermost, since on a MacBook the slot's inner edge
  runs under the notch.

## Risks

- A third mascot on a MacBook sits partly under the notch.
- The 8 fps tick costs some CPU while an agent runs; check it on the packaged
  build before relying on the slot.
- The pixel art relies on whole-point positions, so a fractional pill origin
  can soften its edges.

## Verification

- `PixelMascotTests`: sprite shapes, wing width, walk, blink and alpha timing,
  the `pixel` style's timeline matching the dot's, per-tool aggregation,
  ordering and the three-tool cap, and the model's right-slot content.
- The full `swift test` run, and the packaged build on a notched MacBook.

## Delivery

One feature commit on `feat/pixel-mascot-slot`, merged into
`local/personal-build`.
