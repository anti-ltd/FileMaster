APP_NAME       := FileMaster
BUNDLE_ID      := ltd.anti.filemaster
CONFIG         := release
BUILD_DIR      := build
APP_BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
DMG            := $(BUILD_DIR)/$(APP_NAME).dmg
EXEC_NAME      := $(APP_NAME)
INFO_PLIST     := Resources/Info.plist
ENTITLEMENTS   := Resources/FileMaster.entitlements
MAS_ENTITLEMENTS := Resources/FileMaster.mas.entitlements
MAS_PKG        := $(BUILD_DIR)/$(APP_NAME).pkg
MAS_PROFILE    ?= Resources/FileMaster_MAS.provisionprofile
PRIVACY        := Resources/PrivacyInfo.xcprivacy
ICONSET        := $(BUILD_DIR)/AppIcon.iconset
ICNS           := Resources/AppIcon.icns

SWIFT          := swift
CODESIGN       := codesign
STRIP          := strip

# Stable signing identity so macOS keeps the Accessibility/TCC grant (hotkey +
# shake) across rebuilds. Falls back to ad-hoc ("-") on machines without the
# self-signed "FileMaster Dev" cert. Create one once via Keychain Access →
# Certificate Assistant → Create a Certificate → type "Code Signing".
SIGN_ID        := $(shell security find-certificate -c "FileMaster Dev" >/dev/null 2>&1 && echo "FileMaster Dev" || echo -)

# MAS signing identities — find via: security find-identity -v -p codesigning
MAS_SIGN_APP   ?= 3rd Party Mac Developer Application: William Whitehouse (8248296AJX)
MAS_SIGN_PKG   ?= 3rd Party Mac Developer Installer: William Whitehouse (8248296AJX)

# Developer ID identity for direct-distribution (website / DMG) builds. This
# is different from the MAS identity above — Gatekeeper requires Developer ID
# Application signing + notarization for download-and-run binaries.
DEVID_SIGN_APP ?= Developer ID Application: William Whitehouse (8248296AJX)

# App Store Connect API key for notarytool. The .p8 lives outside the repo;
# memory: KZ765P9ZHP / issuer 66eec4bc-6987-480b-9af2-c26ea01d2ed2.
NOTARY_KEY_ID  ?= KZ765P9ZHP
NOTARY_ISSUER  ?= 66eec4bc-6987-480b-9af2-c26ea01d2ed2
NOTARY_KEY     ?= $(HOME)/.appstoreconnect/private_keys/AuthKey_$(NOTARY_KEY_ID).p8

# Size-optimised release flags:
#   -Osize         optimise for binary size over speed
#   -wmo           whole-module optimisation (better dead-code elimination)
#   -dead_strip    remove unreferenced symbols at link time
RELEASE_FLAGS  := -Xswiftc -Osize -Xswiftc -wmo -Xlinker -dead_strip

# Reel showcase — pass SHOWCASE=1 to compile in the temporary self-recording
# "FileMaster Reel" (Sources/FileMasterUI/Showcase/, gated by the
# FILEMASTER_SHOWCASE flag). Off by default so production builds stay clean.
#   make showcase           # build + record one reel to ~/Desktop (fully auto)
#   make run SHOWCASE=1      # manual: app gains a "Reel Showcase…" menu item
ifdef SHOWCASE
SWIFT_FLAGS += -Xswiftc -DFILEMASTER_SHOWCASE
endif

# Add the Screen Recording usage string to the bundle Info.plist — but only for
# SHOWCASE builds, so the shipped plist stays clean. Expands to nothing when
# SHOWCASE is unset. $(1) = path to Info.plist.
define add_showcase_plist_keys
$(if $(SHOWCASE),/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string FileMaster uses screen recording to export the showcase reel video." "$(1)")
endef

BIN_PATH       = $(shell $(SWIFT) build -c $(CONFIG) --show-bin-path)

# app-arently lives as a sibling checkout; used by `make screenshot`.
APPBIN ?= ../app-arently/.build/release/app-arently

.PHONY: all build bundle run debug stop clean format help icon release \
        bundle-app version bump test dmg build-mas dist dist-manifest screenshot reset showcase

all: build

help:
	@echo "Targets:"
	@echo "  make build      — swift build -c release"
	@echo "  make bundle     — assemble FileMaster.app under build/"
	@echo "  make run        — bundle + relaunch app"
	@echo "  make release    — size-optimised bundle, stripped + signed (FileMaster Dev cert if present, else ad-hoc)"
	@echo "  make debug      — debug build + run in foreground"
	@echo "  make showcase   — build + record one 9:16 reel to ~/Desktop (fully automated)"
	@echo "  make stop       — kill running FileMaster"
	@echo "  make clean      — swift package clean + remove build/"
	@echo "  make icon       — render AppIcon.icns from AppIconRenderer"
	@echo ""
	@echo "  make test       — swift test"
	@echo "  make version    — print FileMaster <short> (<build>)"
	@echo "  make bump       — increment CFBundleVersion"
	@echo "  make dmg        — drag-to-install disk image of the local bundle"
	@echo ""
	@echo "  make build-mas  — Mac App Store .pkg (bumps build #; pass NO_BUMP=1 to skip)"
	@echo "  make dist       — Developer ID + hardened-runtime + notarize + staple + DMG + manifest"

build:
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME) $(RELEASE_FLAGS) $(SWIFT_FLAGS)

icon: build
	@# The renderer is opt-in: when the binary supports --icon we regenerate
	@# the iconset and recompile $(ICNS). When it doesn't (current FileMaster
	@# v1 — the .icns is authored offline and committed under Resources/), we
	@# keep the existing $(ICNS) and just verify it's there.
	@rm -rf "$(ICONSET)"
	@if "$(BIN_PATH)/$(APP_NAME)" --icon "$(ICONSET)" >/dev/null 2>&1 && [ -d "$(ICONSET)" ]; then \
		if command -v pngquant >/dev/null 2>&1; then \
			echo "Quantizing icon PNGs..."; \
			for f in $(ICONSET)/*.png; do \
				pngquant --quality=90-100 --speed 1 --force --output "$$f" "$$f" || true; \
			done; \
		else \
			echo "pngquant not found, skipping (brew install pngquant)"; \
		fi; \
		if command -v optipng >/dev/null 2>&1; then \
			echo "Optimizing icon PNGs..."; \
			optipng -quiet -o7 $(ICONSET)/*.png; \
		else \
			echo "optipng not found, skipping (brew install optipng)"; \
		fi; \
		iconutil -c icns "$(ICONSET)" -o "$(ICNS)"; \
		echo "→ $(ICNS) (regenerated)"; \
	elif [ -f "$(ICNS)" ]; then \
		echo "→ $(ICNS) (existing — no --icon renderer in binary)"; \
	else \
		echo "✗ $(ICNS) missing and binary has no --icon renderer" >&2; \
		exit 1; \
	fi

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_PATH)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)"
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@$(call add_showcase_plist_keys,$(APP_BUNDLE)/Contents/Info.plist)
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@# Strip local symbols before codesigning. -x = drop non-globals.
	@$(STRIP) -x "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)" 2>/dev/null || true
	@$(CODESIGN) --force --deep --sign "$(SIGN_ID)" \
		--entitlements "$(ENTITLEMENTS)" \
		"$(APP_BUNDLE)"
	@echo "→ $(APP_BUNDLE) ($$(du -sh "$(APP_BUNDLE)" | cut -f1), signed: $(SIGN_ID))"

release: clean bundle
	@echo "→ release bundle ready"

run: stop bundle
	@open "$(APP_BUNDLE)"
	@echo "→ launched $(APP_NAME)"

debug:
	$(SWIFT) build -c debug --product $(APP_NAME) $(SWIFT_FLAGS)
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(shell $(SWIFT) build -c debug --show-bin-path)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)"
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@$(call add_showcase_plist_keys,$(APP_BUNDLE)/Contents/Info.plist)
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@$(CODESIGN) --force --deep --sign "$(SIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"
	@$(MAKE) stop
	@"$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)"

# ──────────────────────────────────────────────────────────────────────────
# Reel showcase — the whole workflow in one command.
#
# Builds with the reel compiled in (FILEMASTER_SHOWCASE), then launches the
# bundled app with `--showcase`: it records one 9:16 cycle to ~/Desktop,
# reveals the MP4 in Finder, and quits. Runs in the foreground so you see
# progress; returns when the recording is done.
#
# First run triggers the Screen Recording permission prompt — enable FileMaster
# under System Settings ▸ Privacy & Security ▸ Screen Recording, then re-run.
showcase:
	@$(MAKE) --no-print-directory SHOWCASE=1 bundle
	@echo "→ recording reel (foreground; the MP4 opens on your Desktop when done)"
	@"$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)" --showcase

stop:
	@pkill -x $(EXEC_NAME) 2>/dev/null || true

reset:
	@rm -rf "$$HOME/Library/Application Support/counter-ltd/filemaster"
	@echo "→ wiped ~/Library/Application Support/counter-ltd/filemaster"

# ──────────────────────────────────────────────────────────────────────────
# Versioning & DMG

# Print the current marketing + build version.
version:
	@SHORT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(INFO_PLIST)); \
	BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(INFO_PLIST)); \
	echo "$(APP_NAME) $$SHORT ($$BUILD)"

# Increment CFBundleVersion by 1. App Store Connect rejects duplicate build
# numbers under the same marketing version, so build-mas calls this first to
# guarantee each submission is fresh.
bump:
	@CURRENT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(INFO_PLIST)); \
	NEXT=$$(( CURRENT + 1 )); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$NEXT" $(INFO_PLIST); \
	echo "CFBundleVersion: $$CURRENT -> $$NEXT"

test:
	$(SWIFT) test

# Drag-to-install disk image of the *local* bundle (FileMaster Dev or ad-hoc
# signed). Useful for testing the install layout — not for distribution.
dmg: bundle
	@rm -rf build/dmg "$(DMG)"
	@mkdir -p build/dmg
	@cp -R "$(APP_BUNDLE)" build/dmg/
	@ln -s /Applications build/dmg/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder build/dmg -ov -format UDZO "$(DMG)" >/dev/null
	@rm -rf build/dmg
	@echo "→ $(DMG)"

# ──────────────────────────────────────────────────────────────────────────
# Mac App Store distribution package.
#
# Requires "3rd Party Mac Developer Application" and "3rd Party Mac Developer
# Installer" certificates from your Apple Developer account. Override the
# signing identities via MAS_SIGN_APP and MAS_SIGN_PKG.
# Bumps CFBundleVersion automatically; pass NO_BUMP=1 to skip.
build-mas: icon
	@if [ -z "$(NO_BUMP)" ]; then $(MAKE) --no-print-directory bump; fi
	@rm -rf "$(APP_BUNDLE)" "$(MAS_PKG)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_PATH)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)"
	@$(STRIP) -x "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)" 2>/dev/null || true
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@cp "$(PRIVACY)" "$(APP_BUNDLE)/Contents/Resources/PrivacyInfo.xcprivacy"
	@if [ -f "$(MAS_PROFILE)" ]; then cp "$(MAS_PROFILE)" "$(APP_BUNDLE)/Contents/embedded.provisionprofile"; \
		else echo "⚠ $(MAS_PROFILE) missing — App Store submission will be rejected without it"; fi
	@xattr -cr "$(APP_BUNDLE)"
	$(CODESIGN) --force --deep \
		--sign "$(MAS_SIGN_APP)" \
		--identifier $(BUNDLE_ID) \
		--entitlements "$(MAS_ENTITLEMENTS)" \
		--options runtime \
		"$(APP_BUNDLE)"
	productbuild \
		--component "$(APP_BUNDLE)" /Applications \
		--sign "$(MAS_SIGN_PKG)" \
		"$(MAS_PKG)"
	@echo "→ $(MAS_PKG)"
	@echo "Upload: xcrun altool --upload-package $(MAS_PKG) --type osx \\"
	@echo "          --apiKey $(NOTARY_KEY_ID) --apiIssuer $(NOTARY_ISSUER)"

# ──────────────────────────────────────────────────────────────────────────
# Direct-distribution (website / DMG) build.
#
# Builds a Developer ID-signed, hardened-runtime, notarized, stapled DMG
# ready to upload to R2 for paid customers. This is the *non-MAS* path:
# Gatekeeper requires Developer ID + notarization for download-and-run apps,
# distinct from the MAS pipeline above which uses 3rd Party Mac Developer.
#
# Outputs:
#   build/FileMaster-<version>.dmg   — notarized + stapled, customer-facing
#   build/FileMaster-<version>.json  — manifest for binaries/filemaster.json
#
# The FileMaster Dev local-signing convenience does NOT apply here —
# Developer ID is the only identity macOS will trust outside the App Store.
DIST_VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(INFO_PLIST))
DIST_DMG     = $(BUILD_DIR)/$(APP_NAME)-$(DIST_VERSION).dmg
DIST_JSON    = $(BUILD_DIR)/$(APP_NAME)-$(DIST_VERSION).json

dist: icon
	@echo "── Direct-distribution build: $(APP_NAME) $(DIST_VERSION) ──"
	rm -rf "$(APP_BUNDLE)" "$(DIST_DMG)" "$(DIST_JSON)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BIN_PATH)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)"
	$(STRIP) -x "$(APP_BUNDLE)/Contents/MacOS/$(EXEC_NAME)" 2>/dev/null || true
	cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp "$(PRIVACY)" "$(APP_BUNDLE)/Contents/Resources/PrivacyInfo.xcprivacy"
	xattr -cr "$(APP_BUNDLE)"
	@echo "── Signing with Developer ID + hardened runtime ──"
	codesign --force --deep --timestamp \
		--sign "$(DEVID_SIGN_APP)" \
		--options runtime \
		--entitlements "$(ENTITLEMENTS)" \
		"$(APP_BUNDLE)"
	codesign --verify --strict --deep --verbose=2 "$(APP_BUNDLE)"
	@echo "── Building DMG ──"
	rm -rf build/dmg
	mkdir -p build/dmg
	cp -R "$(APP_BUNDLE)" build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder build/dmg -ov -format UDZO "$(DIST_DMG)"
	rm -rf build/dmg
	@echo "── Submitting to Apple notary service (may take a few minutes) ──"
	xcrun notarytool submit "$(DIST_DMG)" \
		--key "$(NOTARY_KEY)" \
		--key-id "$(NOTARY_KEY_ID)" \
		--issuer "$(NOTARY_ISSUER)" \
		--wait
	@echo "── Stapling notarization ticket ──"
	xcrun stapler staple "$(DIST_DMG)"
	xcrun stapler validate "$(DIST_DMG)"
	@echo "── Writing version manifest ──"
	$(MAKE) --no-print-directory dist-manifest
	@echo ""
	@echo "✓ Built $(DIST_DMG)"
	@echo "✓ Manifest $(DIST_JSON)"
	@echo ""
	@echo "Upload to anti-ltd-binaries:"
	@echo "  wrangler r2 object put anti-ltd-binaries/binaries/filemaster.dmg  --file $(DIST_DMG) --remote"
	@echo "  wrangler r2 object put anti-ltd-binaries/binaries/filemaster.json --file $(DIST_JSON) --content-type application/json --remote"

# Emits binaries/filemaster.json. Shape per anti-ltd/src/worker/versions.js:
# version + optional metadata; the Worker adds `app` and `downloadUrl` at
# response time.
dist-manifest:
	@SIZE=$$(stat -f %z "$(DIST_DMG)"); \
	SHA=$$(shasum -a 256 "$(DIST_DMG)" | awk '{print $$1}'); \
	RELEASED=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	MIN_OS=$$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" $(INFO_PLIST)); \
	NOTES=$${FILEMASTER_RELEASE_NOTES:-"Initial release."}; \
	printf '{\n  "version": "%s",\n  "releasedAt": "%s",\n  "notes": "%s",\n  "minOS": "macOS %s",\n  "sha256": "%s",\n  "size": %d\n}\n' \
		"$(DIST_VERSION)" "$$RELEASED" "$$NOTES" "$$MIN_OS" "$$SHA" "$$SIZE" \
		> "$(DIST_JSON)"
	@echo "  version  $(DIST_VERSION)"
	@echo "  sha256   $$(shasum -a 256 "$(DIST_DMG)" | awk '{print $$1}')"
	@echo "  size     $$(stat -f %z "$(DIST_DMG)") bytes"

# Resource-profile benchmark via app-arently (matches Clonk).
screenshot: bundle
	$(APPBIN) profile --app "$(APP_BUNDLE)" --out Resources/benchmark.png
	@echo "Screenshot: Resources/benchmark.png"

clean:
	$(SWIFT) package clean
	@rm -rf "$(BUILD_DIR)"

format:
	@which swift-format >/dev/null 2>&1 && swift-format -i -r Sources || echo "swift-format not installed (brew install swift-format)"
