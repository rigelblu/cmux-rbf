# Front door for cmux-rbf dev builds. Logic lives in rbf/scripts/dev.sh so it
# stays fork-owned; this file exists so `make run` works without reading docs.
#
# The build-id comes from your branch (`tom-rigelblu/cm-17` -> `cm-17`), so you
# never pick one. It is what `scripts/reload.sh --tag` takes, and it decides the
# DerivedData dir, the bundle id suffix, the debug socket and the app name — so
# two builds never collide. Override with `make run BUILD_ID=something` when
# you want a second build alongside your branch's.
#
# NAMING LAW, and it is load-bearing: THE PLAIN NAME ACTS, A `-plan` SUFFIX
# PREVIEWS. It shipped the other way round once — `install` was the dry run, and
# Tom ran it and expected an install. The help said "Dry-run:" on that very line
# and it did not register, because a command's NAME is read as an assertion and
# its description as commentary; when they disagree the name wins. Safety cannot
# live in help text.
#
# Two corollaries, each already broken once:
#   - A `-plan` target takes NO `$(ARGS)`. Forwarding flags to a preview lets
#     `make clean-builds-plan ARGS=--apply` delete 85 GB from a target whose
#     name promises it writes nothing.
#   - A plain name that cannot safely act must REFUSE, not quietly preview.
#     `clean-tmp` deletes only what you name and errors with no `REMOVE=`.
#
# THE TWO `clean-*` TARGETS HAVE DIFFERENT GUARDS ON PURPOSE, and the difference
# is not arbitrary. `clean-builds` can decide for itself — a DerivedData dir is
# rebuildable, and running / most-recent / current are checkable — so it deletes
# on invocation. `clean-tmp` cannot: those dirs are named by task, several hold
# git worktrees with uncommitted work, and nothing distinguishes dead from
# dormant. So it refuses without an explicit list. Read the descriptions, not the
# shared `clean-` prefix; a dogfooder assumed symmetry and predicted backwards.
.PHONY: help setup run build test install install-rbf install-rbf-plan clean-builds clean-builds-plan clean-tmp clean-tmp-plan

DEV := rbf/scripts/dev.sh

help: ## Show this help
	@echo "cmux-rbf — dev builds. The build-id comes from your branch."
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Examples"
	@printf '  \033[36m%-29s\033[0m %s\n' \
		"make run"                    "rebuild, then launch (~10 min; always rebuilds, no launch-only)" \
		"make build"                  "build only, ~10 min; prints the App path" \
		"make test"                   "run the unit tests, ~10 min (the only gate here)" \
		"make run BUILD_ID=spike"     "name the build yourself, instead of using the branch" \
		"make build ARGS=--prod-auth" "forward a flag: reload.sh for run/build, xcodebuild for test" \
		"make clean-builds"           "reclaim disk; keeps running + most-recent + current only" \
		"make clean-builds-plan"      "DRY RUN - list what that would delete" \
		"make clean-tmp-plan"         "DRY RUN - list external-tmp build dirs with sizes" \
		"make clean-tmp REMOVE=\"a b\"" "delete those two by name; refuses live ones" \
		"make install-rbf"            "build + REPLACE /Applications/cmux RBF.app (~10 min)" \
		"make install-rbf-plan"       "DRY RUN - preview only, nothing is written"
	@echo
	@if [ -n "$(BUILD_ID)" ]; then \
		echo "  current build-id: $$($(DEV) build-id)   (from BUILD_ID=, overriding your branch)"; \
	else \
		echo "  current build-id: $$($(DEV) build-id)   (from your branch)"; \
	fi

run: ## Rebuild this branch's build-id, then launch it
	@$(DEV) run $(ARGS)

build: ## Build only; prints the App path to cmd-click
	@$(DEV) build $(ARGS)

test: ## Run unit tests via the cmux-unit scheme (nothing else compiles them)
	@$(DEV) test $(ARGS)

setup: ## First-time checkout setup - submodules, GhosttyKit, pbxproj hook
	@./scripts/setup.sh
	@echo
	@echo "Zig is handled for you: rbf/scripts/lib/rbf-zig.sh finds 0.15.2 on this"
	@echo "machine. Do NOT 'brew install zig' — that gives 0.16.0, which ghostty rejects."

# Renamed from `install`. Every package manager uses `install` for "fetch my
# dependencies", so in a list reading build / test / install it scans as the
# safe, setup-shaped end of the progression. Here it is the most destructive
# non-delete target in the file: it replaces the app you work in. A dogfooder
# hit exactly that prior. `install` itself now refuses and points here, rather
# than silently doing something far bigger than the name promises.
install-rbf: ## Build and install `cmux RBF.app` into /Applications (replaces it)
	@rbf/scripts/install-rbf.sh

install-rbf-plan: ## DRY RUN - print the install plan, build nothing, write nothing
	@rbf/scripts/install-rbf.sh --dry-run

install: ## (renamed) Use install-rbf - this is NOT dependency setup
	@echo 'make install was renamed to `make install-rbf`.'
	@echo
	@echo 'It does not fetch dependencies — it builds this checkout and REPLACES'
	@echo '/Applications/cmux RBF.app, the app you work in. The old name read like'
	@echo 'npm install and did something much larger.'
	@echo
	@echo '  make install-rbf-plan   see exactly what it would do, writes nothing'
	@echo '  make install-rbf        do it'
	@echo '  make setup              first-time checkout setup (what you may want)'
	@exit 2

# The description says what the script DOES, not what its name suggests.
# It said "for branches that are gone" and that check does not exist: nothing in
# cleanup-dev-builds.sh consults git or jj. Its real protections are the running
# app, /tmp/cmux-last-cli-path, --keep and --older-than. `--keep <this build-id>`
# is added here because losing the branch you are on is the one deletion nobody
# would accept, and it was protected only by the accident of being the most
# recent reload.
clean-builds: ## Delete per-build-id DerivedData, EXCEPT running/most-recent/current — no branch check
	@./scripts/cleanup-dev-builds.sh --apply --keep "$$($(DEV) build-id)" $(ARGS)

# `--keep` is repeated from `clean-builds` on purpose: a preview that does not
# pass it lists your CURRENT build-id as deletable and then the act keeps it, so
# the plan overstates the damage — and a plan you have caught lying once is a
# plan nobody reads twice. The two lines must carry the same guards.
#
# No $(ARGS) here, deliberately: this is a preview, and forwarding arbitrary
# flags to it lets `make clean-builds-plan ARGS=--apply` delete 85 GB from a
# target whose name promises it writes nothing. A preview has no parameters
# worth the hole. Same reason `install-rbf`/`install-rbf-plan` take no ARGS.
clean-builds-plan: ## DRY RUN - list what clean-builds would delete, remove nothing
	@./scripts/cleanup-dev-builds.sh --keep "$$($(DEV) build-id)"

clean-tmp: ## Delete the external-tmp build dirs named in REMOVE="a b"
	@if [ -z "$(REMOVE)" ]; then \
		echo 'make clean-tmp needs REMOVE="<dir> <dir>" — it never deletes by pattern,'; \
		echo 'because these dirs are named by task and nothing can decide which are dead.'; \
		echo 'Run `make clean-tmp-plan` to see the list.'; \
		exit 2; \
	fi
	@case "$(REMOVE)" in \
		*[*?[]*) \
			echo 'make clean-tmp: REMOVE takes exact names, never a pattern.'; \
			echo 'Unquoted, your shell expands the glob against the REPO ROOT, not the'; \
			echo 'tmp dir — so REMOVE="cmux-*" becomes cmux-Bridging-Header.h and the'; \
			echo 'error names a file you never meant. Nothing is deleted either way.'; \
			echo 'Run `make clean-tmp-plan` and copy the names you want.'; \
			exit 2 ;; \
	esac
	@rbf/scripts/clean-tmp-builds.sh --remove $(REMOVE)

clean-tmp-plan: ## DRY RUN - list external-tmp build dirs with sizes, remove nothing
	@rbf/scripts/clean-tmp-builds.sh
