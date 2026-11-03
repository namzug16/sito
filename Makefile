PREFIX ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin
EXECUTABLE := build/sito

.PHONY: build install uninstall test clean

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

clean:
	rm -rf build
