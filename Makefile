.PHONY: help build build-release test test-release run install uninstall clean release notarize publish resume

SWIFT ?= swift
PRODUCT ?= utisuna
BUILD_DIR ?= .build
CONFIG ?= debug
RELEASE_CONFIG ?= release
PREFIX ?= /usr/local
TAG ?=
export SWIFT BUILD_DIR

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make build          Build the package in debug mode' \
		'  make build-release  Build the package in release mode' \
		'  make test           Run the test suite' \
		'  make test-release   Run release workflow regression tests' \
		'  make run ARGS="..." Run the CLI with arguments' \
		'  make install        Install the release binary into $(PREFIX)/bin' \
		'  make uninstall      Remove the installed binary from $(PREFIX)/bin' \
		'  make clean          Remove build artifacts' \
		'  make release TAG=x  Build an unsigned local archive; never publish' \
		'  make notarize TAG=x Build, sign and notarize once; never publish' \
		'  make publish TAG=x  Build, notarize and publish a new release' \
		'  make resume TAG=x   Publish existing notarized artifacts without rebuilding'

build:
	"$(SWIFT)" build --scratch-path "$(BUILD_DIR)" -c "$(CONFIG)"

build-release:
	"$(SWIFT)" build --scratch-path "$(BUILD_DIR)" -c "$(RELEASE_CONFIG)"

test:
	"$(SWIFT)" test --scratch-path "$(BUILD_DIR)"
	$(MAKE) test-release

test-release:
	python3 -m unittest discover -s Tests/release -v

run:
	"$(SWIFT)" run --scratch-path "$(BUILD_DIR)" "$(PRODUCT)" $(ARGS)

install: build-release
	install -d "$(PREFIX)/bin"
	install -m 0755 "$$("$(SWIFT)" build --scratch-path "$(BUILD_DIR)" -c "$(RELEASE_CONFIG)" --show-bin-path)/$(PRODUCT)" "$(PREFIX)/bin/$(PRODUCT)"

uninstall:
	rm -f "$(PREFIX)/bin/$(PRODUCT)"

clean:
	"$(SWIFT)" package --scratch-path "$(BUILD_DIR)" clean

release:
	PUBLISH=0 NOTARIZE=0 CONFIGURATION="$(RELEASE_CONFIG)" ./scripts/release.sh "$(TAG)"

notarize:
	CONFIGURATION="$(RELEASE_CONFIG)" ./scripts/notarize.sh "$(TAG)"

publish:
	CONFIGURATION="$(RELEASE_CONFIG)" ./scripts/release.sh --publish "$(TAG)"

resume:
	CONFIGURATION="$(RELEASE_CONFIG)" ./scripts/release.sh --resume "$(TAG)"
