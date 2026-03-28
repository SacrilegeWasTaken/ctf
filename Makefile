# Apple removed arm64 from Xcode 26+ SDK TBD stubs.
# Use Command Line Tools SDK (15.5) which still has arm64.
CLT_SDK     := /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
DEVELOPER_DIR := /Library/Developer/CommandLineTools

export DEVELOPER_DIR
export SDKROOT := $(CLT_SDK)

.PHONY: run build test clean

run:
	zig build run

build:
	zig build

test:
	zig build test

clean:
	rm -rf .zig-cache zig-out
