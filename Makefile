SHELL := /bin/bash

EDITOR_SRC := src/editor.cr
EDITOR_BIN := bin/editor
LSP_PATH ?= $(CRYSTAL_EDITOR_LSP)

.PHONY: build run harness spec spec-smoke check check-lsp ci ci-fast fmt fmt-check help

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
	crystal tool format src spec

fmt-check:
	crystal tool format --check src spec

clean:
	rm -f $(EDITOR_BIN)

check: fmt-check build spec
	@echo "check: format + build + spec OK"

check-lsp: check harness
	@echo "check-lsp: format + build + spec + LSP harness OK"

ci-fast: build spec-smoke
	@echo "ci-fast: build + smoke spec"

ci: check
	@echo "ci: format + build + spec passed"

help:
	@echo "Available targets:"
	@echo "  build      Build the editor binary (bin/editor)"
	@echo "  run ARGS=  Run editor sources with arguments"
	@echo "  harness    Run an LSP handshake against LSP_PATH or CRYSTAL_EDITOR_LSP"
	@echo "  spec-smoke Run smoke specs only"
	@echo "  ci-fast    Build + run smoke spec"
	@echo "  spec       Run Crystal specs"
	@echo "  fmt        Format source files in place"
	@echo "  fmt-check  Check source formatting without writing changes"
	@echo "  check      Check formatting, build editor, and run all specs"
	@echo "  check-lsp  Run check, then the optional LSP handshake harness"
	@echo "  ci         Run the reproducible CI pipeline"
	@echo "  clean      Remove built binary"
