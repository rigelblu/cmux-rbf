---
title: Use skills when starting work with the product and its projects
---

# 🔵⋯ Common Project Rules
Session memory, the product plan, and pickup notes live on the external
rb-drive — not in this repo. Don't start cold; resume.

## 🟠⋯ Session lifecycle
- **Start** — `session-block-pick-up minimal generalist`: loads prior memory, the ship plan, and what to pick up
- **Before designing or building anything** — `conduct-product-dimensions`
- **End** — `session-block-wrap-up`: writes memory and pickup notes back

### 🟣⋯ The exemption has to speak
Both of the above may be skipped for a genuine throwaway one-off. **Say so before your first edit, or you have not taken the exemption — you have skipped the rule.**
> Treating this as a one-off, so no dimensions pass: `<why>`.

The trigger is **your first edit to a source file**, not your read of whether the request is "a feature". That distinction is the whole point.
e.g. *"lower the contrast of the background color of workspaces"* was classified as a one-off and built, tested and handed back before `conduct-product-dimensions` was invoked. It was a feature: it earned a ship-plan entry, a design finding that redirected the next change, and it exposed a latent renderer-drift defect in the code it touched. Nothing about the opening request looked like that.

So the rule cannot key on the request. An agent that has already decided "this is small" will not recognise itself in *"when starting a new feature."* It will recognise itself in *"I am about to edit a file and I have not said which mode I am in."* One visible sentence costs nothing when the call is right, and when it is wrong it surfaces in the second message instead of the eighth.

**Refuse this rationalization:** *"I'll do the pass afterwards if it turns out to matter."* → It did turn out to matter here, and the pass then ran on an existing implementation, which ratifies rather than verifies. A gate downstream of the thing it gates is not a gate.

## 🟠⋯ Where it lives (reference — the skills above resolve these for you)
`prj-use` fills `<PROJECT_NAME>`. If a path here ever disagrees with reality, trust the skill.

### 🟣⋯ Session block — `rb-drive/agents/<PROJECT_NAME>/`
- **Core Memories:** `agents-core-memories.md`
- **Turning Memories:** `agents-turning-memories.md`
- **Find My Bearings:** `agents-find-my-bearings.md`
- **Agent & Human Shared Understanding:** `agents-shared-understanding.md`
- **What to pick up next session:** `agents-pickup.md`

### 🟣⋯ Product — `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/`
- **Product/Feature Ship Plan:** `product-ship-plan.md`
- **Released Features:** `product-ship-released.md`

### 🟣⋯ Project — `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/`
- **Project Workblock Plan:** `project-wb-plan.md`

---

# 🔵⋯ Custom Project Rules
## 🔴 There is no CI. Nothing runs on push or on a PR.
`.github/workflows/ci.yml` has exactly one trigger, `workflow_dispatch`, and 26 of 40 workflows carry no `push`/`pull_request`/`schedule` trigger at all.
**We are our own fork and we do not run one. Never propose wiring up CI as a prerequisite for other work.**

`CLAUDE.md` is upstream's file and assumed CI throughout. **Those claims have been pruned out of it** — each removal left an inline `<!-- cmux-rbf: pruned upstream text ... -->` comment naming what was cut and why, ending "Reject this hunk on upstream sync." Read those comments as the record of what upstream says and we don't.

Grep them at any time:

```bash
rg -n "cmux-rbf: pruned upstream text" CLAUDE.md skills/ docs/ .claude/commands/
```

**Two places still carry upstream's version wholesale**, banner-warned rather than pruned, because they are mostly upstream changelog or upstream procedure: `docs/ghostty-fork.md` and `.claude/commands/release*.md`. Trust their banners over their bodies.

### 🟣⋯ Build, run and test: `make`
The front door, so you never invent a **build-id** or hunt a DerivedData path.

**Where the build-id comes from: your jj bookmark first, then a git branch.** `tom-rigelblu/cm-19` → `cm-19`. jj keeps git's HEAD detached permanently, so in this checkout `git branch --show-current` is *empty* — the jj lookup is the one that fires, and the git path only matters in the git worktrees used for isolated builds. If neither resolves you get `detached-<sha>` **and a warning on stderr**, because that mints a fresh ~6GB DerivedData dir per commit.

The build-id is what `scripts/reload.sh --tag` takes. It decides the DerivedData dir, the debug socket, the app name, and the bundle id suffix — so two dev builds never collide. It is a *component* of the bundle id, not a peer: build-id `cm-18` gives `com.cmuxterm.app.debug.cm.18` (reload.sh maps non-alnum runs to dots, so the hyphen does not survive). That is why changing it resets TCC grants and keychain-backed sign-in — the same mechanism behind `#cm-17`'s "sign-in does not migrate".

```bash
make run                       # build this branch's build-id and launch it
make build                     # build only; prints the App path
make test                      # cmux-unit scheme — nothing else compiles the unit tests
make clean-builds              # reclaim ~6GB per build-id; keeps running/most-recent/current, no branch check (-plan previews)
make install-rbf               # build + install `cmux RBF.app` (install-rbf-plan previews)
make run BUILD_ID=spike        # a second build alongside your branch's
make build ARGS=--prod-auth    # extra flags → reload.sh (for `make test`, → xcodebuild)
make help
```

Logic lives in `rbf/scripts/dev.sh`, except what `make install-rbf` also needs — that lives in `rbf/scripts/lib/`, because `make install-rbf` calls `rbf/scripts/install-rbf.sh` directly and never passes through `dev.sh`.

### 🟣⋯ How to hand a build back
**Give Tom the command, not the path.** When a change is ready to look at, end with the `make` line he should run:

```
Ready to look at:  make run
```

Name a non-default build-id only when the work genuinely needs one (`make run BUILD_ID=spike`), and say why in the same breath.

**Never hand back a `file://` link to a `.app`** — that is upstream's convention and it is pruned from `CLAUDE.md`. A path addresses a bundle *that was already built*, so it keeps resolving after the tree moves on and launches the previous build without saying so. Observed 2026-08-02 on `#cm-20`: a link offered as the fix pointed at the prior value of the constant, because the intervening command was `make test`, which builds `cmux-unit` and never touches the app. `make run` rebuilds, so it cannot be stale; a link cannot know whether it is.

The same holds for pasting a DerivedData path as prose, and `BUILD_ID` takes a **build-id**, never a filename — `BUILD_ID=cm-17.app` mints `cmux DEV cm-17.app.app` with its own ~6GB DerivedData dir and its own bundle id, which resets TCC grants and keychain sign-in.

#### 🟡⋯ If you did not build in Tom's checkout, say where you built
Bare `make run` means *"whatever your current directory's branch resolves to"*. Run in Tom's tree it builds **Tom's** branch, not yours — so an agent working in its own worktree that hands back bare `make run` is handing back someone else's build. Give the directory:

```
Ready to look at:  make -C /Volumes/Tom's HDD/tmp/<your-worktree> run
```

Absolute path, always. `make -C` moves make's working directory before anything runs, and the derivation is **cwd-relative** (`derive_build_id()` tests `.jj` and `git branch --show-current` in `$PWD`), so `-C` is what makes it read *your* branch.

**Do not reach for `BUILD_ID` to do this.** The build-id names the *output slot*; the checkout names the *source*. `make run BUILD_ID=<yours>` in Tom's tree compiles **his** working copy into a slot wearing **your** name — wrong code, right-looking app, no error. That is strictly worse than a stale link, which at least shows an app someone really built.

`BUILD_ID` has exactly one use in a multi-agent session: **two agents on the same branch name**. Distinct branches already isolate everything — build-id, DerivedData, debug socket, bundle id — with no flag at all. Same branch in two worktrees collides on all four, and one of the two must pass `BUILD_ID=<something>` and say so.

Before handing back, confirm the tree you built is the tree you are naming: `make -C <path> help` prints `current build-id:` and costs nothing.

### 🟣⋯ How to hand a build back
**Give Tom the command, not the path.** When a change is ready to look at, end with the `make` line he should run:

```
Ready to look at:  make run
```

Name a non-default build-id only when the work genuinely needs one (`make run BUILD_ID=spike`), and say why in the same breath.

**Never hand back a `file://` link to a `.app`** — that is upstream's convention and it is pruned from `CLAUDE.md`. A path addresses a bundle *that was already built*, so it keeps resolving after the tree moves on and launches the previous build without saying so. Observed 2026-08-02 on `#cm-20`: a link offered as the fix pointed at the prior value of the constant, because the intervening command was `make test`, which builds `cmux-unit` and never touches the app. `make run` rebuilds, so it cannot be stale; a link cannot know whether it is.

The same holds for pasting a DerivedData path as prose, and `BUILD_ID` takes a **build-id**, never a filename — `BUILD_ID=cm-17.app` mints `cmux DEV cm-17.app.app` with its own ~6GB DerivedData dir and its own bundle id, which resets TCC grants and keychain sign-in.

#### 🟡⋯ If you did not build in Tom's checkout, say where you built
Bare `make run` means *"whatever your current directory's branch resolves to"*. Run in Tom's tree it builds **Tom's** branch, not yours — so an agent working in its own worktree that hands back bare `make run` is handing back someone else's build. Give the directory:

```
Ready to look at:  make -C /Volumes/Tom's HDD/tmp/<your-worktree> run
```

Absolute path, always. `make -C` moves make's working directory before anything runs, and the derivation is **cwd-relative** (`derive_build_id()` tests `.jj` and `git branch --show-current` in `$PWD`), so `-C` is what makes it read *your* branch.

**Do not reach for `BUILD_ID` to do this.** The build-id names the *output slot*; the checkout names the *source*. `make run BUILD_ID=<yours>` in Tom's tree compiles **his** working copy into a slot wearing **your** name — wrong code, right-looking app, no error. That is strictly worse than a stale link, which at least shows an app someone really built.

`BUILD_ID` has exactly one use in a multi-agent session: **two agents on the same branch name**. Distinct branches already isolate everything — build-id, DerivedData, debug socket, bundle id — with no flag at all. Same branch in two worktrees collides on all four, and one of the two must pass `BUILD_ID=<something>` and say so.

Before handing back, confirm the tree you built is the tree you are naming: `make -C <path> help` prints `current build-id:` and costs nothing.

**Two build landmines, both disarmed below every entrypoint rather than at one:**

- **XcodeProj resolves forward.** Capped to `"9.0.0" ..< "9.15.0"` in `Packages/macOS/CMUXProjectModel/Package.swift`; 9.15.0 adds a case that makes `XcodeProjectAdapter.swift:706` non-exhaustive. The build that *does* the drift succeeds and the next one fails, so it presents as "it worked yesterday." `dev.sh` also defaults `CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=1` as a second line.
- **ghostty pins Zig 0.15.2 exactly** and a stock PATH here is 0.16.0. `rbf/scripts/lib/rbf-zig.sh` resolves it and exports both `CMUX_ZIG` and `PATH`. `make install-rbf` enforces it (`--required`) before building; `dev.sh` only warns, since a cached GhosttyKit may carry the build there.

Each was first patched at whichever entrypoint surfaced it, and each then failed again at the next one — XcodeProj at `build`, then `test`, then `install`; Zig at `build`/`run`, then `install`. **A guard written inside one entrypoint cannot be inherited by a second; only a copy can, and nobody copies what they don't know exists.** Put new ones in `Package.swift` or `rbf/scripts/lib/`.

**Quit any running tagged app before `make test`**, or the run dies with "Test runner never began executing tests", exit 65, zero tests run.

### 🟣⋯ `/Applications` holds **two** cmux apps — check which one you are in
Since v0.9.0 (`#cm-17`) the flavour installs beside upstream rather than replacing it:

| App                          | Bundle id              | What it is                                           |
| ---                          | ---                    | ---                                                  |
| `/Applications/cmux RBF.app` | `com.cmuxterm.app.rbf` | **ours** — `make install-rbf` builds and installs it |
| `/Applications/cmux.app`     | `com.cmuxterm.app`     | upstream's, never read or written by the installer   |

**`env \| grep CMUX_BUNDLE_ID` is how a session tells which one hosts it**, and this matters beyond documentation. `#cm-17`'s opening measurement was exactly this reading — it found that every fork feature shipped to date was running in *upstream's* app, which is the finding that motivated the whole slice. An agent that assumes `/Applications/cmux.app` is the fork will draw wrong conclusions from a running app, and they will look like product bugs.

Do not read About to answer this. It reports `0.64.20 / 100` in **both** apps — the fork inherited both version keys at the fork point — until `#cm-17.3` lands in v0.10.0.

Two more consequences worth knowing before debugging something odd:

- `~/.config/cmux/cmux.json` resolves from `$HOME`, **not** the bundle id, so both apps share it. A settings change in one appears in the other; that is the design, not a leak.
- Everything else is bundle-id scoped — workspaces, window layout, session order, reopen history, and keychain auth. A separate bundle starts signed out **by construction**, and no file copy fixes it.

### 🟣⋯ `release-pretag-guard.sh` cannot complete here
Its first check compares our `CURRENT_PROJECT_VERSION` against **upstream's** appcast; both are build 100, inherited at the fork point, so it can never pass. With `set -euo pipefail` that also means its **later checks never run — including the `cmux-unit` compile, which is the only automated release gate this fork has.** Run `make test` yourself instead; do not read the guard's failure as "the release is unsafe" or its absence as "the tests build."

### 🟣⋯ A green result exists only if you personally produced it.
- Never close a task on "CI will catch it," and never report a check as passing that you did not run yourself.
- Run these by hand whenever you touch what they guard:
  - `./scripts/lint-pbxproj-test-wiring.sh` (any `cmuxTests/` file)
  - `python3 scripts/check-workspace-package-groups.py --check` (any package move)
  - `python3 scripts/check-package-resolved-policy.py` (any SwiftPM change)

### 🟣⋯ The gate that does exist is the manual suite plus dogfood
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

### 🟣⋯ When you already wrote the test and the code together
It happens, especially for a new pure type where the test cannot compile until the type exists. The recovery is **mutation testing**, not a shrug: deliberately break the implementation one behaviour at a time and confirm the matching test fails.

A mutation nothing catches is the finding. Either the test does not discriminate, or the code is redundant because something downstream already compensates — both are worth knowing, and neither is visible from a green run. Restore from a backup copy afterwards, never by hand.
