PREFIX ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin
EXECUTABLE := build/sito

.PHONY: build install uninstall test publish-check publish clean

build:
	dart pub get
	mkdir -p build
	dart compile exe bin/sito.dart -o $(EXECUTABLE)

# Removes before copying because macOS kills a binary rewritten in place.
install: build
	mkdir -p "$(BIN_DIR)"
	rm -f "$(BIN_DIR)/sito"
	cp $(EXECUTABLE) "$(BIN_DIR)/sito"
	@echo "Installed $(BIN_DIR)/sito"

uninstall:
	rm -f "$(BIN_DIR)/sito"

test:
	dart analyze
	dart test

publish-check: test
	dart pub publish --dry-run

# pub.dev versions are permanent, so dart pub publish asks for confirmation.
publish: publish-check
	dart pub publish

clean:
	rm -rf build
