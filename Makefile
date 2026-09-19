# Makefile for zigswiss. Every target is a thin wrapper around `zig build`, so
# that the usual make verbs work and the underlying zig commands are easy to
# look up. Run `make help` for the list of targets.

BINARY_NAME = zigswiss
VERSION := $(shell grep '\.version' build.zig.zon | head -1 | cut -d'"' -f2)
BIN = zig-out/bin/$(BINARY_NAME)
INSTALL_DIR = /usr/local/bin
DIST_DIR = dist
CROSS_TARGETS = x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows

.PHONY: all build release small test fmt fmt-check run clean install uninstall user-install cross dist help

all: build

build:
	zig build

release:
	zig build -Doptimize=ReleaseSafe

small:
	zig build -Doptimize=ReleaseSmall

test:
	zig build test --summary all

fmt:
	zig fmt build.zig src

fmt-check:
	zig fmt --check build.zig src

run: build
	$(BIN)

clean:
	trash -v -s .zig-cache zig-out $(DIST_DIR) 2>/dev/null || true

install: release
	install -d $(INSTALL_DIR)
	install -m 755 $(BIN) $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Installed $(BINARY_NAME) to $(INSTALL_DIR)"

uninstall:
	trash -v -s $(INSTALL_DIR)/$(BINARY_NAME)

user-install: release
	cp -f $(BIN) $(HOME)/bin/$(BINARY_NAME)
	@echo "Installed $(BINARY_NAME) to $(HOME)/bin/"

# Zig cross-compiles out of the box: no extra toolchains are needed.
cross:
	@for target in $(CROSS_TARGETS); do \
		echo "building $$target"; \
		zig build -Dtarget=$$target -Doptimize=ReleaseSmall -p $(DIST_DIR)/$(BINARY_NAME)-v$(VERSION)-$$target || exit 1; \
	done

dist: cross
	@cd $(DIST_DIR) && for dir in $(BINARY_NAME)-v$(VERSION)-*/; do \
		name=$${dir%/}; \
		tar -cJf $$name.tar.xz $$name && echo "created $(DIST_DIR)/$$name.tar.xz"; \
	done

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build         Build a Debug binary into zig-out/bin (default)"
	@echo "  release       Build with -Doptimize=ReleaseSafe"
	@echo "  small         Build with -Doptimize=ReleaseSmall"
	@echo "  test          Run all unit tests"
	@echo "  fmt           Format the source with zig fmt"
	@echo "  fmt-check     Fail if any file is not formatted"
	@echo "  run           Build and run (shows usage)"
	@echo "  clean         Remove .zig-cache, zig-out and dist"
	@echo "  install       Build release and install to $(INSTALL_DIR)"
	@echo "  uninstall     Remove from $(INSTALL_DIR)"
	@echo "  user-install  Build release and install to $(HOME)/bin/"
	@echo "  cross         Cross-compile for: $(CROSS_TARGETS)"
	@echo "  dist          Cross-compile and create .tar.xz archives in dist/"
	@echo "  help          Show this help"
