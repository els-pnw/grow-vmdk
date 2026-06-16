SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

POETRY ?= poetry
BATS   ?= bats
VENV   := .venv
PYTEST := $(VENV)/bin/pytest

# Use uv when available, fall back to stdlib venv + pip.
HAS_UV := $(shell command -v uv 2>/dev/null)
ifdef HAS_UV
  VENV_CREATE  = uv venv $(VENV)
  PIP_INSTALL  = uv pip install --quiet
else
  VENV_CREATE  = python3 -m venv $(VENV)
  PIP_INSTALL  = $(VENV)/bin/pip install --quiet
endif

# ── Colours ────────────────────────────────────────────────────────────────
BOLD  := $(shell tput bold 2>/dev/null || true)
RESET := $(shell tput sgr0 2>/dev/null || true)
GREEN := $(shell tput setaf 2 2>/dev/null || true)
CYAN  := $(shell tput setaf 6 2>/dev/null || true)

.PHONY: help venv deps lock lint lint-yaml lint-ansible lint-sh \
        test test-py test-bats test-playbook \
        check coverage clean

# ── Help ───────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "$(BOLD)grow-vmdk — available targets$(RESET)"
	@echo ""
	@echo "  $(CYAN)Setup$(RESET)"
	@echo "    make venv      — create .venv and install deps (uses uv if available)"
	@echo "    make deps      — alias for venv"
	@echo "    make lock      — regenerate poetry.lock (after editing pyproject.toml)"
	@echo ""
	@echo "  $(CYAN)Linting$(RESET)"
	@echo "    make lint         — run all linters (shellcheck + yamllint)"
	@echo "    make lint-yaml    — yamllint on extend-lv.yml and .gitlab-ci.yml"
	@echo "    make lint-ansible — ansible-lint on extend-lv.yml"
	@echo "    make lint-sh      — shellcheck on extend-lv.sh"
	@echo ""
	@echo "  $(CYAN)Testing$(RESET)"
	@echo "    make test          — run all tests (Python + Bats + playbook)"
	@echo "    make test-py       — pytest: grow-vmdk.py unit tests"
	@echo "    make test-bats     — bats: extend-lv.sh shell tests"
	@echo "    make test-playbook — pytest: extend-lv.yml structure tests"
	@echo "    make check         — lint + test (full CI equivalent)"
	@echo "    make coverage      — pytest with HTML coverage report"
	@echo ""
	@echo "  $(CYAN)Cleanup$(RESET)"
	@echo "    make clean     — remove .venv, __pycache__, coverage artefacts"
	@echo ""
ifdef HAS_UV
	@echo "  Using: $(BOLD)uv$(RESET) (fast installer)"
else
	@echo "  Using: pip (install uv for faster installs: curl -LsSf https://astral.sh/uv/install.sh | sh)"
endif
	@echo ""

# ── Virtual environment ────────────────────────────────────────────────────
# Always recreate if pyproject.toml is newer than the venv sentinel.
$(VENV)/bin/activate: pyproject.toml
	$(VENV_CREATE)
	touch $(VENV)/bin/activate

venv: $(VENV)/bin/activate
	@echo "$(BOLD)Installing dependencies$(RESET)"
	$(PIP_INSTALL) pyvmomi pytest pytest-cov pyyaml yamllint ansible-lint
	@echo "$(GREEN)✓ virtualenv ready at $(VENV)/$(RESET)"

deps: venv

# Regenerate poetry.lock after editing pyproject.toml.
lock:
	@command -v $(POETRY) >/dev/null 2>&1 \
	    || { echo "Poetry not found — install: curl -sSL https://install.python-poetry.org | python3 -"; exit 1; }
	$(POETRY) lock
	@echo "$(GREEN)✓ poetry.lock updated$(RESET)"

# ── Linting ────────────────────────────────────────────────────────────────
lint-yaml: venv
	@echo "$(BOLD)yamllint$(RESET)"
	$(VENV)/bin/yamllint extend-lv.yml .gitlab-ci.yml

lint-ansible: venv
	@echo "$(BOLD)ansible-lint$(RESET)"
	$(VENV)/bin/ansible-lint extend-lv.yml

lint-sh:
	@echo "$(BOLD)shellcheck$(RESET)"
	@command -v shellcheck >/dev/null 2>&1 \
	    || { echo "shellcheck not found — install: brew install shellcheck (macOS) or apt install shellcheck"; exit 1; }
	shellcheck extend-lv.sh

lint: lint-sh lint-yaml
	@echo "$(GREEN)✓ all linters passed$(RESET)"

# ── Tests ──────────────────────────────────────────────────────────────────
test-py: venv
	@echo "$(BOLD)pytest — grow-vmdk.py unit tests$(RESET)"
	$(PYTEST) tests/test_grow_vmdk.py -v

test-playbook: venv
	@echo "$(BOLD)pytest — extend-lv.yml playbook tests$(RESET)"
	$(PYTEST) tests/test_extend_lv_playbook.py -v

test-bats:
	@echo "$(BOLD)bats — extend-lv.sh shell tests$(RESET)"
	@command -v $(BATS) >/dev/null 2>&1 \
	    || { echo "bats not found — install: brew install bats-core (macOS) or https://bats-core.readthedocs.io"; exit 1; }
	$(BATS) tests/test_extend_lv.bats

test: test-py test-playbook test-bats
	@echo "$(GREEN)✓ all tests passed$(RESET)"

# ── CI-equivalent ─────────────────────────────────────────────────────────
check: lint test
	@echo "$(GREEN)✓ full check passed$(RESET)"

# ── Coverage ──────────────────────────────────────────────────────────────
coverage: venv
	@echo "$(BOLD)pytest with coverage$(RESET)"
	$(PYTEST) tests/test_grow_vmdk.py tests/test_extend_lv_playbook.py \
	    --cov=grow_vmdk \
	    --cov-report=term-missing \
	    --cov-report=html:htmlcov \
	    -v
	@echo "$(GREEN)✓ coverage report written to htmlcov/index.html$(RESET)"

# ── Cleanup ────────────────────────────────────────────────────────────────
clean:
	rm -rf $(VENV) htmlcov .coverage .pytest_cache
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@echo "$(GREEN)✓ cleaned$(RESET)"
