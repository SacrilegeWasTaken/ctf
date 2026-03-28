# Apple removed arm64 from Xcode 26+ SDK TBD stubs.
# Use Command Line Tools SDK (15.5) which still has arm64.
CLT_SDK     := /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
DEVELOPER_DIR := /Library/Developer/CommandLineTools

export DEVELOPER_DIR
export SDKROOT := $(CLT_SDK)

PREFIX ?= /usr/local

.PHONY: run build test clean install uninstall

ARGS ?=

run:
	zig build run $(if $(ARGS),-- $(ARGS),)

# Absorb extra targets so make doesn't complain
%:
	@:

build:
	zig build

test:
	zig build test

install:
	zig build -Doptimize=ReleaseSafe --prefix $(PREFIX)

uninstall:
	rm -f $(PREFIX)/bin/ctf

clean:
	rm -rf .zig-cache zig-out
