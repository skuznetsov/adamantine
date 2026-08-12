SHELL := /bin/bash

EDITOR_SRC := src/editor.cr
EDITOR_BIN := bin/editor
LSP_PATH ?= $(CRYSTAL_EDITOR_LSP)

.PHONY: build run harness spec spec-smoke check ci ci-fast fmt fmt-check help

build:
	crystal build $(EDITOR_SRC) -o $(EDITOR_BIN)

run:
	crystal run $(EDITOR_SRC) -- $(ARGS)

harness:
	./scripts/harness.sh $(LSP_PATH)

spec:
	crystal spec

spec-smoke:
	crystal spec spec/ci_smoke_spec.cr

fmt:
	crystal tool format $(EDITOR_SRC) src/editor/app.cr src/editor/key_config.cr src/editor/lsp_client.cr src/editor/theme.cr src/editor/replace_utils.cr spec/replace_utils_spec.cr spec/navigation_history_spec.cr spec/settings_binding_conflict_spec.cr spec/command_palette_spec.cr

fmt-check:
	crystal tool format --check $(EDITOR_SRC) src/editor/app.cr src/editor/key_config.cr src/editor/lsp_client.cr src/editor/theme.cr src/editor/replace_utils.cr spec/replace_utils_spec.cr spec/navigation_history_spec.cr spec/settings_binding_conflict_spec.cr spec/command_palette_spec.cr

clean:
	rm -f $(EDITOR_BIN)

check: build spec harness
	@echo "check: build + spec + harness OK"

ci-fast: build spec-smoke
	@echo "ci-fast: build + smoke spec"

ci: check
	@echo "ci: build + spec + harness passed"

help:
	@echo "Available targets:"
	@echo "  build      Build the editor binary (bin/editor)"
	@echo "  run ARGS=  Run editor sources with arguments"
	@echo "  harness    Run LSP handshake harness against crystal_v2_lsp (or CRYSTAL_EDITOR_LSP)"
	@echo "  spec-smoke Run smoke specs only"
	@echo "  ci-fast    Build + run smoke spec"
	@echo "  spec       Run Crystal specs"
	@echo "  fmt        Format source files in place"
	@echo "  fmt-check  Check source formatting without writing changes"
	@echo "  check      Build editor, run spec, then LSP handshake harness"
	@echo "  ci         Run check pipeline (build + spec + harness)"
	@echo "  clean      Remove built binary"
