---
name: cmux-release
description: "cmux release workflow, version bumping, changelog updates, pretag guard, release tags, and release asset expectations. Use when preparing or troubleshooting a cmux release."
---

# cmux Release

Use the `/release` command to prepare a new release. This will:

1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

## Version bumping

```bash
./scripts/bump-version.sh
./scripts/bump-version.sh patch
./scripts/bump-version.sh major
./scripts/bump-version.sh 1.0.0
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. The build number is auto-incremented and is required for Sparkle auto-update to work.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

If it fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry tagging.

<!-- cmux-rbf: pruned upstream text — removed the manual tag-and-publish steps (`git tag`/`git push origin`/`gh run watch --repo manaflow-ai/cmux`), the Apple GitHub secrets, the `cmux-macos.dmg` asset and README download button — this fork has no signing secrets, no release workflow and publishes no DMG. `release-pretag-guard.sh` also cannot pass here: its first check compares our `CURRENT_PROJECT_VERSION` against upstream's appcast and both are build 100. Release in this fork is `deliver-feat local` plus `rbf/VERSION` and `rbf/CHANGELOG.md`, in jj (see rbf/AGENTS.md). Reject this hunk on upstream sync. -->

## Notes

- Bump the minor version for updates unless explicitly asked otherwise.
- Update `CHANGELOG.md`; docs changelog is rendered from it.

## Detailed reference

- Read [references/release-checklist.md](references/release-checklist.md) for a more detailed release checklist and common failure handling.
