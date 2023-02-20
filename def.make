ifeq ($(filter oneshell,$(.FEATURES)),)
$(error Unsupported make version. Please use a make version which supports ONESHELL)
endif

ifeq ($(filter second-expansion,$(.FEATURES)),)
$(error Unsupported make version. Please use a make version which supports SECONDEXPANSION)
endif

ifdef VERBOSE
$(info MAKE_VERSION=$(MAKE_VERSION))
$(info .FEATURES=$(.FEATURES))
else
.SILENT:
endif

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eufo pipefail -c
export BASH_ENV := make_bash_env

.SECONDEXPANSION:

.DELETE_ON_ERROR:

MAKEFLAGS += --no-builtin-rules
