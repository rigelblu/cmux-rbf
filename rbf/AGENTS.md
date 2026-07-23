---
title: Use skills when starting work with the product and its projects
---

Session memory, the product plan, and pickup notes live on the external
rb-drive — not in this repo. Don't start cold; resume.

# 🔵⋯ Session lifecycle
- **Start** — `session-block-pick-up minimal generalist`: loads prior memory, the ship plan, and what to pick up (skip only for a throwaway one-off)
- **Before designing or building a feature** — `conduct-product-dimensions`
- **End** — `session-block-wrap-up`: writes memory and pickup notes back

# 🔵🏗️ Testing — keep the proof, drop the ceremony
cmux-rbf does **not** use the two-commit red/green structure in `CLAUDE.md`. That policy exists to prove a test's worth to upstream maintainers through the GitHub PR Commits tab. This fork reviews its own work, so the doubled commits buy nothing — and they force stub commits whenever the test covers a type that doesn't exist yet.

What survives is the part that carries the evidence:
- Run each new behaviour test against the **unfixed** code first
- Confirm it fails *for the intended reason* — not a compile error, not a typo, not an unwired target
- Record the observed failure — the assertion message or the actual value — in the commit body or the feature brief
- Then implement, and commit **once**

A test never observed failing proves nothing, and this repo ships several ways to be fooled:
- An unwired `cmuxTests/` file reports `Executed 0 tests` and still passes review — `./scripts/lint-pbxproj-test-wiring.sh` catches it
- The `cmux` scheme compiles no unit tests and still prints `TEST BUILD SUCCEEDED` — use `cmux-unit`
- `-only-testing:` names a **class**, not a file; an unmatched filter runs nothing and still reports `TEST SUCCEEDED`
- A test guarding a production gate that has no consumer stays green no matter what the fix does

## 🟠⋯ When you already wrote the test and the code together
It happens, especially for a new pure type where the test cannot compile until the type exists. The recovery is **mutation testing**, not a shrug: deliberately break the implementation one behaviour at a time and confirm the matching test fails.

A mutation nothing catches is the finding. Either the test does not discriminate, or the code is redundant because something downstream already compensates — both are worth knowing, and neither is visible from a green run. Restore from a backup copy afterwards, never by hand.

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
