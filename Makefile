.PHONY: help build build-release test run install uninstall clean release notarize

SWIFT ?= swift
PRODUCT ?= utisuna
BUILD_DIR ?= .build
CONFIG ?= debug
RELEASE_CONFIG ?= release
PREFIX ?= /usr/local

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make build          Build the package in debug mode' \
		'  make build-release  Build the package in release mode' \
		'  make test           Run the test suite' \
		'  make run ARGS="..." Run the CLI with arguments' \
		'  make install        Install the release binary into $(PREFIX)/bin' \
		'  make uninstall      Remove the installed binary from $(PREFIX)/bin' \
		'  make clean          Remove build artifacts' \
		'  make release        Build a release zip archive via scripts/release.sh' \
		'  make notarize       Notarize a built release zip via scripts/notarize.sh'

build:
	$(SWIFT) build -c $(CONFIG)

build-release:
	$(SWIFT) build -c $(RELEASE_CONFIG)

test:
	$(SWIFT) test

run:
	$(SWIFT) run $(PRODUCT) $(ARGS)

install: build-release
	install -d "$(PREFIX)/bin"
	install "$(BUILD_DIR)/$(RELEASE_CONFIG)/$(PRODUCT)" "$(PREFIX)/bin/$(PRODUCT)"

uninstall:
	rm -f "$(PREFIX)/bin/$(PRODUCT)"

clean:
	$(SWIFT) package clean

release:
	./scripts/release.sh

notarize: release
	./scripts/notarize.sh
