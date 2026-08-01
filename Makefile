# Front door for cmux-rbf dev builds. Logic lives in rbf/scripts/dev.sh so it
# stays fork-owned; this file exists so `make run` works without reading docs.
#
# The build-id comes from your branch (`tom-rigelblu/cm-18` -> `cm-18`), so you
# never pick one. It is what `scripts/reload.sh --tag` takes, and it decides the
# DerivedData dir, the bundle id suffix, the debug socket and the app name — so
# two builds never collide. Override with `make run BUILD_ID=something` when
# you want a second build alongside your branch's.
.PHONY: help run build test clean-builds clean-builds-apply

DEV := rbf/scripts/dev.sh

help: ## Show this help
	@echo "cmux-rbf — dev builds. The build-id comes from your branch."
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Examples"
	@printf '  \033[36m%-29s\033[0m %s\n' \
		"make run"                    "rebuild, then launch (always rebuilds; no launch-only mode)" \
		"make build"                  "build only; prints the App path" \
		"make test"                   "run the unit tests (the only gate here)" \
		"make run BUILD_ID=spike"     "name the build yourself, instead of using the branch" \
		"make build ARGS=--prod-auth" "forward a reload.sh flag (see ./scripts/reload.sh --help)" \
		"make clean-builds"           "see what is reclaimable, then ..." \
		"make clean-builds-apply"     "... actually delete it"
	@echo
	@echo "  current build-id: $$($(DEV) build-id)   (from your branch)"

run: ## Rebuild this branch's build-id, then launch it
	@$(DEV) run $(ARGS)

build: ## Build only; prints the App path to cmd-click
	@$(DEV) build $(ARGS)

test: ## Run unit tests via the cmux-unit scheme (nothing else compiles them)
	@$(DEV) test $(ARGS)

clean-builds: ## Dry-run: show per-build-id DerivedData/sockets that could be removed
	@./scripts/cleanup-dev-builds.sh $(ARGS)

clean-builds-apply: ## Actually remove them
	@./scripts/cleanup-dev-builds.sh --apply $(ARGS)
