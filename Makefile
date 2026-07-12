APP      := Ears
BUILD    := build
BUNDLE   := $(BUILD)/$(APP).app
CONFIG   := release
BINARY   := .build/$(CONFIG)/$(APP)
ICONSET  := $(BUILD)/AppIcon.iconset
ICNS     := Support/AppIcon.icns
DMG      := $(BUILD)/$(APP).dmg
STAGING  := $(BUILD)/dmg-staging

.PHONY: app run build clean icon dmg install

build:
	swift build -c $(CONFIG)

$(ICNS): Support/make-icon.swift
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	swift Support/make-icon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

icon: $(ICNS)

app: build $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns
# Identifier-only designated requirement: keeps the TCC microphone grant
# valid across rebuilds (ad-hoc signatures otherwise pin it to one build).
# With a Developer ID certificate, replace with (entitlements are REQUIRED —
# hardened runtime without them silently denies mic + calendar access):
#   codesign --force --deep --options runtime \
#     --entitlements Support/Ears.entitlements \
#     --sign "Developer ID Application: YOUR NAME (TEAMID)" $(BUNDLE)
	codesign --force --sign - \
		--entitlements Support/Ears.entitlements \
		--requirements '=designated => identifier "com.pavansai.ears"' \
		$(BUNDLE)

run: app
	$(BUNDLE)/Contents/MacOS/$(APP)

# Real install: /Applications copy + a Desktop icon. Double-clicking either
# launches Ears, or shows the HUD if it's already running.
install: app
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	ln -sfn /Applications/$(APP).app $(HOME)/Desktop/$(APP).app
	@echo "Installed /Applications/$(APP).app (+ Desktop icon)"

# Drag-to-Applications installer image.
# Once notarization credentials exist (Developer ID + app-specific password):
#   xcrun notarytool store-credentials ears-notary \
#     --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#   xcrun notarytool submit $(DMG) --keychain-profile ears-notary --wait
#   xcrun stapler staple $(DMG)
dmg: app
	rm -rf $(STAGING) $(DMG)
	mkdir -p $(STAGING)
	cp -R $(BUNDLE) $(STAGING)/
	ln -s /Applications $(STAGING)/Applications
	hdiutil create -volname "$(APP)" -srcfolder $(STAGING) -ov -format UDZO $(DMG)
	rm -rf $(STAGING)
	@echo "Installer image: $(DMG)"

clean:
	rm -rf $(BUILD) .build
