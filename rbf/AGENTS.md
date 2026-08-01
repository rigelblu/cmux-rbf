---
title: Use skills when starting work with the product and its projects
---

Session memory, the product plan, and pickup notes live on the external
rb-drive — not in this repo. Don't start cold; resume.

# 🔵⋯ Session lifecycle
- **Start** — `session-block-pick-up minimal generalist`: loads prior memory, the ship plan, and what to pick up (skip only for a throwaway one-off)
- **Before designing or building a feature** — `conduct-product-dimensions`
- **End** — `session-block-wrap-up`: writes memory and pickup notes back

# 🔵⋯ Where it lives (reference — the skills above resolve these for you)
`prj-use` fills `<PROJECT_NAME>`. If a path here ever disagrees with reality, trust the skill.

## 🟠⋯ Session block — `rb-drive/agents/<PROJECT_NAME>/`
- **Core Memories:** `agents-core-memories.md`
- **Turning Memories:** `agents-turning-memories.md`
- **Find My Bearings:** `agents-find-my-bearings.md`
- **Agent & Human Shared Understanding:** `agents-shared-understanding.md`
- **What to pick up next session:** `agents-pickup.md`

## 🟠⋯ Product — `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/`
- **Product/Feature Ship Plan:** `product-ship-plan.md`
- **Released Features:** `product-ship-released.md`

## 🟠⋯ Project — `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/`
- **Project Workblock Plan:** `project-wb-plan.md`

# 🔴 There is no CI. Nothing runs on push or on a PR.
`.github/workflows/ci.yml` has exactly one trigger, `workflow_dispatch`, and 26 of 40 workflows carry no `push`/`pull_request`/`schedule` trigger at all.
**We are our own fork and we do not run one. Never propose wiring up CI as a prerequisite for other work.**

`CLAUDE.md` is upstream's file and assumed CI throughout. **Those claims have been pruned out of it** — each removal left an inline `<!-- cmux-rbf: pruned upstream text ... -->` comment naming what was cut and why, ending "Reject this hunk on upstream sync." Read those comments as the record of what upstream says and we don't.

Grep them at any time:

```bash
rg -n "cmux-rbf: pruned upstream text" CLAUDE.md skills/ docs/ .claude/commands/
```

**Two places still carry upstream's version wholesale**, banner-warned rather than pruned, because they are mostly upstream changelog or upstream procedure: `docs/ghostty-fork.md` and `.claude/commands/release*.md`. Trust their banners over their bodies.

## 🟠⋯ Build, run and test: `make`
The front door, so you never invent a **build-id** or hunt a DerivedData path.

**Where the build-id comes from: your jj bookmark first, then a git branch.** `tom-rigelblu/cm-19` → `cm-19`. jj keeps git's HEAD detached permanently, so in this checkout `git branch --show-current` is *empty* — the jj lookup is the one that fires, and the git path only matters in the git worktrees used for isolated builds. If neither resolves you get `detached-<sha>` **and a warning on stderr**, because that mints a fresh ~6GB DerivedData dir per commit.

The build-id is what `scripts/reload.sh --tag` takes. It decides the DerivedData dir, the debug socket, the app name, and the bundle id suffix — so two dev builds never collide. It is a *component* of the bundle id, not a peer: build-id `cm-18` gives `com.cmuxterm.app.debug.cm.18` (reload.sh maps non-alnum runs to dots, so the hyphen does not survive). That is why changing it resets TCC grants and keychain-backed sign-in — the same mechanism behind `#cm-17`'s "sign-in does not migrate".

```bash
make run                       # build this branch's build-id and launch it
make build                     # build only; prints the App path
make test                      # cmux-unit scheme — nothing else compiles the unit tests
make clean-builds              # dry run; clean-builds-apply actually deletes (~6GB each)
make run BUILD_ID=spike        # a second build alongside your branch's
make build ARGS=--prod-auth    # extra flags → reload.sh (for `make test`, → xcodebuild)
make help
```

Logic lives in `rbf/scripts/dev.sh`. It defaults `CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=1`, because XcodeProj is declared `from: "9.0.0"` (open upper bound) and a freely-resolving build drifts the lockfile to a version where `XcodeProjectAdapter.swift` stops compiling — and the build that *does* the drift succeeds, so it surfaces as "it worked yesterday."

**Quit any running tagged app before `make test`**, or the run dies with "Test runner never began executing tests", exit 65, zero tests run.

## 🟠⋯ `release-pretag-guard.sh` cannot complete here
Its first check compares our `CURRENT_PROJECT_VERSION` against **upstream's** appcast; both are build 100, inherited at the fork point, so it can never pass. With `set -euo pipefail` that also means its **later checks never run — including the `cmux-unit` compile, which is the only automated release gate this fork has.** Run `make test` yourself instead; do not read the guard's failure as "the release is unsafe" or its absence as "the tests build."

## 🟠⋯ A green result exists only if you personally produced it.
- Never close a task on "CI will catch it," and never report a check as passing that you did not run yourself.
- Run these by hand whenever you touch what they guard:
  - `./scripts/lint-pbxproj-test-wiring.sh` (any `cmuxTests/` file)
  - `python3 scripts/check-workspace-package-groups.py --check` (any package move)
  - `python3 scripts/check-package-resolved-policy.py` (any SwiftPM change)

## 🟠⋯ The gate that does exist is the manual suite plus dogfood
- Every feature is shipped through these, not through a pipeline
- In `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/test-suite/`:
  - `done-full-suite.md`: is the accumulated regression suite across shipped features
  - `released-cm-N.md` is per feature
  - `review.md` holds in-flight scenarios
- So before starting a large change, work out how long it will take Tom to re-run done-full-suite.md by hand. That is the real cost — not the coding time — and for something like a bulk upstream merge it dominates everything else.

# 🔵🏗️ Testing — keep the proof, drop the ceremony
- cmux-rbf does **not** use the two-commit red/green structure in `CLAUDE.md`. **Commit once.**

That red/green policy exists to show upstream's maintainers a red check turning green in the GitHub PR Commits tab. With no CI here (above), both commits would sit grey forever, so the structure proves nothing to anyone. It also forces stub commits whenever the test covers a type that doesn't exist yet.

What survives is the part that carries the evidence:
- Run each new behaviour test against the **unfixed** code first
- Confirm it fails *for the intended reason* — not a compile error, not a typo, not an unwired target
- Record the observed failure — the assertion message or the actual value — in the commit body or the feature brief
- Then implement, and commit **once**

A test never observed failing proves nothing, and this repo ships several ways to be fooled:
- An unwired `cmuxTests/` file reports `Executed 0 tests` and still passes review
- `./scripts/lint-pbxproj-test-wiring.sh` catches it, **but only when you run it yourself**; upstream's PR job does not fire here
- The `cmux` scheme compiles no unit tests and still prints `TEST BUILD SUCCEEDED` — use `cmux-unit`
- `-only-testing:` names a **class**, not a file; an unmatched filter runs nothing and still reports `TEST SUCCEEDED`
- A test guarding a production gate that has no consumer stays green no matter what the fix does

## 🟠⋯ When you already wrote the test and the code together
It happens, especially for a new pure type where the test cannot compile until the type exists. The recovery is **mutation testing**, not a shrug: deliberately break the implementation one behaviour at a time and confirm the matching test fails.

A mutation nothing catches is the finding. Either the test does not discriminate, or the code is redundant because something downstream already compensates — both are worth knowing, and neither is visible from a green run. Restore from a backup copy afterwards, never by hand.
