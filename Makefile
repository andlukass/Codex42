.DEFAULT_GOAL := setup

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
export CODEX_IMAGE ?= my-codex

.PHONY: setup codex

setup:
	@bash "$(ROOT)scripts/codex.sh" setup

codex: setup
	@bash "$(ROOT)scripts/codex.sh" run
