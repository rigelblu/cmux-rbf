# Xcode Project Normalization

The pin (`.xcode-version`, `objectVersion = 60`), the pre-commit hook, and the guard are described in [../SKILL.md](../SKILL.md) — run `scripts/check-pbxproj.sh` yourself after touching the pbxproj; nothing runs it for you. <!-- cmux-rbf: pruned upstream text — was 'the CI guard' — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

## Bumping the Xcode pin

1. Edit `.xcode-version`.
2. Open `cmux.xcodeproj` in the new Xcode so it rewrites `objectVersion`.
3. Add a case in `scripts/check-pbxproj.sh` mapping the new Xcode major to the `objectVersion` that major writes.
4. Run `scripts/normalize-pbxproj.py`.

Do not change `objectVersion` opportunistically as part of unrelated project edits.
