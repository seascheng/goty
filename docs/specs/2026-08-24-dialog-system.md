# Dialog system (one product surface)

2026-08-24 — the "three dialogs, three designs" round.

## Rule

Every modal in this product rides ONE machinery:

```
DialogCard (chassis)  →  Dialog.presentCard(_ card:, width:, focus:)
```

- `PromptCard` (Components.swift) — the standard card `Dialog.prompt /
  promptText / confirm / error` render: title / detail / input / buttons,
  340pt.
- `WorktreeCard` (Panels/WorktreeDialog.swift) — designed cards subclass
  `DialogCard` directly; 480pt tier.
- **No dialog builds its own panel, backdrop, or card recipe.**
  `Dialog.present` is a thin builder over `PromptCard` + `presentCard`.

## Sizing (ControlMetrics — the only source)

- `inputHeight = 30`, `buttonHeight = 28`, `buttonMinWidth = 76`,
  `radius = 6`.
- `ChromeButton` owns its size: every instance is `buttonHeight` tall,
  ≥ `buttonMinWidth` wide. Call sites position buttons; they never
  resize them (the SSH editor's mismatched Save/Cancel was per-call-site
  sizing).
- `ChromeInput` is the only single-line input (SSH editor, prompt card,
  worktree card).

## Focus (the caret rule)

A dialog opened from a menu action runs inside the menu's tracking
session: `makeKeyAndOrderFront` is deferred until the menu unwinds, so
any focus call before that lands in a not-yet-key panel and the
insertion-point blink never starts (typing works, no caret).
`presentCard` therefore fires the focus closure:

1. immediately,
2. one main-queue tick later,
3. on the panel's `didBecomeKey` (the authoritative moment), once.

`ChromeInput.focus()` additionally restarts the insertion-point timer.

## Semantics

- Cancel always dismisses with visible effect. In persistent editors
  (SSH manager) Cancel = leave-editing (deselect, form → placeholder);
  a revert-only cancel reads as a dead button when nothing was typed.
- Esc routes through `DialogCard.performKeyEquivalent` → `onCancel`;
  Return → `onPrimary`. Buttons share the same routes.

## Incidents distilled here

## The full menu-path caret chain (2026-08-24, final)

Three stacked AppKit traps, all verified by probe:

1. **Main-queue starvation.** `runModal` entered from inside a
   `DispatchQueue.main.async` block (every menu action defers one
   tick) can never drain the main queue again — libdispatch is not
   reentrant. Every `async`/`asyncAfter` focus retry scheduled around
   the modal silently never fires. Retries must ride a runloop
   `Timer` registered in BOTH `.default` and the modal-panel mode.
2. **Deferred make-key.** `makeKeyAndOrderFront` during the menu's
   tracking session is deferred; the unwind hands key back to the
   PARENT. The bounded timer retries make-key until the panel holds
   it. A caret blinks only in the key window.
3. **Blink timer in the wrong runloop mode.** `becomeFirstResponder`
   running while the menu's eventTracking session still owns the
   runloop schedules the blink timer in eventTracking mode — dead the
   moment the modal loop takes over. One extra focus pass INSIDE the
   modal loop (`ChromeInput.focus()` resigns first, so the dance
   re-runs) reschedules the timer in the mode that ticks.

Rule: modal-adjacent choreography (focus, make-key, timers) goes
through runloop primitives with explicit modes — never the main
dispatch queue.

- 2026-08-23: hand-rolled modal poll starved inside a menu tracking
  session (frozen card) → real `runModal` sessions.
- 2026-08-24 (a): `Dialog.present` lost its `panel.contentView`
  assignment in a refactor — every prompt rendered as an invisible
  modal that ate input. One machinery, one assignment, tested shape.
- 2026-08-24 (b): per-call-site button sizing → unequal buttons.
  Component-owned metrics.
- 2026-08-24 (c): caret lost when focused before the panel became key
  (menu unwind) → didBecomeKey focus retry.
