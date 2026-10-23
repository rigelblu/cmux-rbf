---
title: Code Notes
subtitle: What this code does that reading one file won't tell you
rules: |
  - One section per code area, opened by the moment to read it. Each note gives the rule, then the evidence that earned it
  - A note leaves when the code under it changes, or when the code itself says it at the site
---

# 🔵⋯ Pane headers and tab bars
*Read before changing a pane header, a tab bar, focus chrome, or a pane's layering.*
- Clear alpha is not visual transparency: verify composited pixels. The portal chain is transparent end to end. What blanked the header in `#cm-3` was cmux's own opaque per-pane fill in `TerminalPanelView.swift`, plus Ghostty reclaiming the backdrop whenever `background-image` was set
- The whole header mounts behind `if headerPresentation.rendersHeader { TabBarView(...) }` in `PaneContainerView.swift`, and `showSplitButtons` is consumed inside `TabBarView`, so hiding a header removes its tab caption and its icons together
- `TabBarVisibility` already yields `.hidden` for a single-tab pane under `.multipleTabs`; cmux sets `.adaptive` window-wide in `Sources/Workspace.swift`, which is also the main workspace's Bonsplit configuration site. The pane separator is a separate `#RRGGBBAA` hex, window-wide too
- Pane focus lives in the header: `PaneContainerView` computes `isFocused` and hands it to `TabBarView`. There is no pane-level focus chrome and no pane-level accessibility identity
- `TabBarSelectionChromeView` owns both header edges: a 1pt separator at the bottom, broken under the selected tab, and the accent indicator at the top (the view is `isFlipped`). Bonsplit clears the selected-tab fill under `usesSharedBackdrop` on purpose, so anything that retires the indicator must replace selection, not just focus
- Bonsplit's `TabItemView` and cmux's `TabItemView` in `Sources/ContentView.swift` are different types. Only cmux's carries the `Equatable` + `.equatable()` typing-latency contract
- cmux has no focus rings on purpose: `TabBarColors.focusRing` has no consumers, and 15 sites set `focusRingType = .none` (read 2026-10-26). Keyboard access is shortcuts and the palette. Don't design a focus state for cmux chrome; do design the VoiceOver label and action
- Bonsplit's split tree is binary: `SplitState` holds exactly `first` and `second` (`Internal/Models/SplitState.swift`), so every `ThemedSplitView` owns one divider and `customDividerColor` is already per divider
- The pane divider is computed, never stored: `TabBarColors.nsColorSeparator` derives it from `tabBarBackgroundHex` by luminance. `borderHex` short-circuits it, and is window-wide

# 🔵⋯ Workspace status and todo state
*Read before reading or writing a workspace's status, or staging a check on a new workspace.*
- **`WorkspaceTodoState.statusHidden` is true both by default and when you pick None, and nothing tells the two apart.** `hideTaskStatus()` (`Sources/Workspace+Todos.swift:166`) writes the same `statusHidden = true` a new workspace starts with. So a nil lane means the workspace-todo beta gate is off, the workspace was never labelled, or the user picked None. `Workspace.effectiveTaskStatus` is the lane ungated on `statusHidden`; `snapshot.taskStatus` is the gated one. 41 of 41 session manifests once persisted `taskStatusHidden: true`
- A new workspace therefore starts on None, not Auto. Put it on Auto (`workspace status set auto`) and assert `statusHidden` false before any detection check, or correct color routing reads as a defect

# 🔵⋯ Key handlers
*Read before writing or reviewing a handler that checks modifiers, in SwiftUI or AppKit.*
- **An arrow key is never "unmodified": check that none of Command, Control, Option or Shift is held, never `modifiers.isEmpty`.** Every arrow press carries the numeric-pad and function flags, and the system adds them even to a posted event whose flags were cleared. `#cm-107`'s handle guard read `press.modifiers.isEmpty`, so Up and Down did nothing. Tom caught it by hand after every accessibility check had passed, because the accessibility action reaches the same move by another path. `ReplyPanelView.isUnmodifiedStep` strips those bits, but it is `private`, so a new handler can't reuse it
