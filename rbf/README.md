---
title: "Cmux RBF"
---

This directory holds this flavour's docs, scripts, changelog, and version metadata. The upstream cmux README and changelog remain at the repository root.

# 🔵⋯ Use
This is for my personal use and shared publicly for those curious. I'm not accepting issues or contributions here.

# 🔵⋯ Context
This is my ~~fork~~ flavour of [cmux](https://github.com/manaflow-ai/cmux): a terminal workspace adapted around how I organize and move through active work.

# 🔵⋯ Features
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
