---
title: "Cmux RBF"
---

This directory holds this flavour's docs, scripts, changelog, and version metadata. The upstream cmux README and changelog remain at the repository root.

# 🔵⋯ Use
This is for my personal use and shared publicly for those curious. I'm not accepting issues or contributions here.

# 🔵⋯ Context
This is my ~~fork~~ flavour of [cmux](https://github.com/manaflow-ai/cmux): a terminal workspace adapted around how I organize and move through active work.

# 🔵⋯ Features
## 🟠⋯ Read a pane at a glance, not as a one-item tab strip
A pane holding a single surface shows a centered caption instead of a lone tab, because one tab implies somewhere to switch to. Add a second surface and the familiar tab strip returns.

- The header keeps its icon, status marks, actions, and context menu — only the tab treatment goes.
- Drag and middle-click close stay on the caption itself; clicking the empty header focuses the pane.
- A focused pane draws a contrast-safe rule along its header, but only when more than one pane is on screen and only while the window is active.

## 🟠⋯ One background image across the whole window
A terminal `background-image` spans the window instead of being cropped separately into every pane, so splitting no longer breaks the picture at each divider.

- Requires `background-opacity` below `1`. At full opacity each pane still paints an opaque fill that hides the shared backdrop; removing that fill is tracked separately.
- Honors Ghostty's own `background-image-fit`, `-position`, `-opacity`, and `-repeat` settings.

## 🟠⋯ Put a new pane exactly where it belongs
Create a terminal pane to the left, right, above, or below the pane you are working in.

- Use the View menu, Command Palette, terminal context menu, configurable tab-bar actions, or customizable keyboard shortcuts.
- Existing Split Right and Split Down defaults stay unchanged.
- Split Left and Split Up are available to bind without adding new default shortcuts or tab-bar buttons.
- Actions invoked from a pane-specific surface target that pane, even when another pane or window owns global focus.
- Unsupported remote-tmux directions stop without substituting another direction or changing the local layout.

# 🔵⋯ Versions
- The flavour version lives in `rbf/VERSION`.
- Flavour release notes live in `rbf/CHANGELOG.md`.
- Upstream cmux version and release history remain in `cmux.xcodeproj/project.pbxproj` and the root `CHANGELOG.md`.
- Local flavour releases update the three `rbf/` release files without rewriting upstream release metadata.

# 🔵⋯ Build
Initialize the checkout once:

```sh
./scripts/setup.sh
```

Build an isolated Debug app with a descriptive tag:

```sh
./scripts/reload.sh --tag <tag>
```

The reload script prints the built `.app` path. It does not launch the app unless you pass `--launch`.
