---
name: cmux-release
description: "cmux release workflow, version bumping, changelog updates, pretag guard, release tags, and release asset expectations. Use when preparing or troubleshooting a cmux release."
---

# cmux Release

Prefer the `/release` command. It determines the new version (minor by default), gathers commits since the last tag, updates `CHANGELOG.md`, runs `./scripts/bump-version.sh`, commits, runs `./scripts/release-pretag-guard.sh`, then tags and pushes.

The docs changelog page at `web/app/[locale]/(landing)/docs/changelog/page.tsx` renders from `CHANGELOG.md`, so there is no separate docs changelog source to update.

## Version bumping

```bash
./scripts/bump-version.sh          # minor (0.15.0 -> 0.16.0)
./scripts/bump-version.sh patch    # 0.15.0 -> 0.15.1
./scripts/bump-version.sh major    # 0.15.0 -> 1.0.0
./scripts/bump-version.sh 1.0.0    # explicit version
```

This updates `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number auto-increments and must increase for Sparkle auto-update to work. Bump the minor version unless explicitly asked otherwise.

## Tagging

<!-- cmux-rbf: pruned upstream text — removed the manual tag-and-publish steps (`git tag`/`git push origin`/`gh run watch --repo manaflow-ai/cmux`), the Apple GitHub secrets, the `cmux-macos.dmg` asset and README download button — this fork has no signing secrets, no release workflow and publishes no DMG. `release-pretag-guard.sh` also cannot pass here: its first check compares our `CURRENT_PROJECT_VERSION` against upstream's appcast and both are build 100, and `set -euo pipefail` means its later checks — including the `cmux-unit` compile, the only real gate — never run; run `make test` yourself instead. Release in this fork is `deliver-feat local` plus `rbf/VERSION` and `rbf/CHANGELOG.md`, in jj (see rbf/AGENTS.md). Reject this hunk on upstream sync. -->

```bash
jj bookmark set <name> -r @      # then tag/push per rbf/AGENTS.md
jj git push --bookmark <name>
```

## Detailed reference

- [references/release-checklist.md](references/release-checklist.md): changelog tone, failure triage, and asset-rename fallout.
