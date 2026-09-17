# Copyright (c) 2026 The Zoom Control Authors
# SPDX-License-Identifier: MIT
APP      = ZoomControl
BUILD    = .build/release
BUNDLE   = dist/$(APP).app

.PHONY: build app run cli clean

build:
	swift build -c release

## Package the SwiftUI binary into a double-clickable .app (ad-hoc signed).
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: app
	open $(BUNDLE)

## Quick CLI check: connect, handshake, print status + meters for 10 s.
cli: build
	$(BUILD)/zoomctl session --idle 10

clean:
	rm -rf .build dist

## Put zoomctl on your PATH (for Stream Deck "run command" actions, scripts, etc.)
install: build
	install -m 755 $(BUILD)/zoomctl /usr/local/bin/zoomctl
	@echo "Installed /usr/local/bin/zoomctl"
