---
title: "Cmux RBF Changelog"
---

Fork releases use the version in `rbf/VERSION`; upstream release history remains in the root `CHANGELOG.md`.

# 🔵⋯ [Unreleased]
(empty)

---

# 🔵⋯ v0.4.0 (2026-07-31) — #cm-10
## 🟠⋯ Added for End Users
- 2026-07-31 - feat (ux) | recognize a workspace by its colour and see which one is active at a glance — the colour stays as an identity strip down the row's leading edge over a quiet wash, and selecting a workspace fills the row with a contrast-corrected version of its own colour instead of a generic highlight (#cm-10)
- 2026-07-31 - feat (ux) | tell two similar workspace colours apart while one is selected — the active row's strip wears a pale tint of that workspace's own colour, where before every selected row drew the same black or white edge and only the fill carried identity (#cm-10)
- 2026-07-31 - feat (ux) | the colour strip curves into the row along the row's own corner instead of ending in a blunt or rounded tip (#cm-10)

## 🟠⋯ Removed for End Users
- 2026-07-31 - feat (ux) | the **Workspace Color Indicator** setting is gone, along with the Left Rail and Solid Fill styles — workspace colours now render one way, so there is nothing to choose between (#cm-10)

## 🟠⋯ Known Limitations
- A `workspaceColors.indicatorStyle` value left in `~/.config/cmux/cmux.json` is ignored rather than reported. It selects nothing and can be deleted; cmux stays silent rather than warning about a key it retired itself.
- Increase Contrast, Reduce Transparency, and VoiceOver were not exercised for this release. The treatment is designed so the full-strength strip and opaque active fill survive them with the colour wash only supplemental, but that is unverified — and the wash is the part that composites against the translucent sidebar material those settings remove.

---

# 🔵⋯ v0.3.0 (2026-07-31) — #cm-13
## 🟠⋯ Added for End Users
- 2026-07-31 - feat (ux) | see one terminal `background-image` spanning the whole window instead of a separately cropped copy in every pane, so a split no longer breaks the picture at each divider (#cm-13)

## 🟠⋯ Fixed for End Users
- 2026-07-31 - fix (ux) | terminal background images render the right way up; every image was drawn vertically mirrored (#cm-13)

## 🟠⋯ Known Limitations
- The window-wide image is only visible when `background-opacity` is below `1`. At full opacity each pane still paints an opaque fill over the shared backdrop and hides it. Removing that per-pane fill is `#cm-12`, which is not in this release.

## 🟠⋯ Changed for Developers
- 2026-07-31 - chore (dx) | `ghostty` now resolves to `rigelblu/ghostty-rbf`, carrying `macos-background-image-from-layer` so the host can own the terminal background image

---

# 🔵⋯ v0.2.0 (2026-07-31) — #cm-3
## 🟠⋯ Added for End Users
- 2026-07-31 - feat (ux) | read a pane with one surface as a labeled caption instead of a single tab that suggests there is somewhere to switch to, with the existing tab strip returning the moment a second surface appears (#cm-3)
- 2026-07-31 - feat (ux) | see which pane you are working in at a glance — a focused single-surface caption draws a contrast-safe rule along its header, only when more than one pane is on screen and only while the window is active (#cm-3)

## 🟠⋯ Fixed for End Users
- 2026-07-31 - fix (ux) | caption text stays legible at any `background-opacity`, including `0`, instead of flipping to dark text on a dark terminal below roughly 57% (#cm-3)
- 2026-07-31 - fix (ux) | a non-active window drops its pane-focus rule instead of drawing one identical to the active state, which under the Graphite system accent made active and inactive windows pixel-identical (#cm-3)
- 2026-07-31 - fix (ux) | the pane header keeps its bottom separator in caption mode and in embedded panes that never opted into captions (#cm-3)
- 2026-07-31 - fix (ux) | clicking anywhere in an unfocused pane's header focuses it, including the area left of a centered caption, which previously did nothing (#cm-3)
- 2026-07-31 - fix (ux) | a zoomed pane no longer draws a focus rule when it is the only pane on screen (#cm-3)
- 2026-07-31 - fix (ux) | dragging a surface onto a caption pane's empty header shows where it will land before you release (#cm-3)
- 2026-07-31 - fix (ux) | a new caption fades in centered instead of flashing left-aligned for a frame and jumping (#cm-3)
- 2026-07-31 - fix (a11y) | VoiceOver can focus a pane and toggle its zoom from the caption, which previously exposed no actions (#cm-3)
- 2026-07-31 - fix (dx) | dev builds sign with a stable identity when `CMUX_DEV_CODESIGN_IDENTITY` is set, so macOS permission grants survive a rebuild instead of re-prompting every time

## 🟠⋯ Changed for Developers
- 2026-07-31 - chore (dx) | Bonsplit moved from a git submodule to a `git subtree` at `Packages/macOS/Bonsplit`, so a feature spanning cmux and Bonsplit is one repository, one diff, and one bisect
- 2026-07-31 - chore (dx) | the unused `homebrew-cmux` submodule was dropped — three submodules down to one

---

# 🔵⋯ v0.1.0 (2026-07-29) — #cm-2
## 🟠⋯ Added for End Users
- 2026-07-29 - feat (ux) | put a new terminal pane exactly where it belongs by splitting left, right, above, or below from menus, the Command Palette, pane controls, or customizable shortcuts (#cm-2)
