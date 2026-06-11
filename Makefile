SHELL := /bin/bash
SCRIPTS := scripts

.PHONY: all release love dist-mac dist-win dist-linux dist-android dist-ios \
        clean distclean check-deps help

# Default target
all: release

## Build all platform distributions (sequential to avoid download races)
release: check-deps
	@bash $(SCRIPTS)/build-love.sh
	@bash $(SCRIPTS)/build-macos.sh
	@bash $(SCRIPTS)/build-windows.sh
	@bash $(SCRIPTS)/build-linux.sh

## Build piper.love only (base artifact for all platforms)
love: check-deps
	@bash $(SCRIPTS)/build-love.sh

## Build macOS universal distribution (piper.app in a zip)
dist-mac: love
	@bash $(SCRIPTS)/build-macos.sh

## Build Windows x64 distribution (piper.exe + DLLs in a zip)
dist-win: love
	@bash $(SCRIPTS)/build-windows.sh

## Build Linux distributions (AppImage + .love zip)
dist-linux: love
	@bash $(SCRIPTS)/build-linux.sh

## Check that all required tools are available
check-deps:
	@bash $(SCRIPTS)/check-deps.sh

## Remove build outputs (keeps cached love2d downloads)
clean:
	rm -rf dist/

## Remove build outputs AND cached love2d downloads
distclean:
	rm -rf dist/ $(SCRIPTS)/cache/

## Android build instructions (requires Android Studio, NDK, signing key)
dist-android:
	@echo ""
	@echo "Android builds cannot be automated here — they require a full Android"
	@echo "development environment. Steps:"
	@echo ""
	@echo "  1. Install Android Studio and NDK"
	@echo "  2. Clone: https://github.com/love2d/love-android"
	@echo "  3. Build piper.love:  make love"
	@echo "  4. Copy: cp dist/piper-*.love love-android/app/src/embed/assets/game.love"
	@echo "  5. cd love-android"
	@echo "     ./gradlew assembleEmbedNoRecordRelease"
	@echo "  6. Sign the APK with your keystore"
	@echo "  Output: app/build/outputs/apk/embedNoRecord/release/*.apk"
	@echo ""
	@echo "  Reference: https://github.com/love2d/love-android/wiki/Game-Packaging"
	@echo ""

## iOS build instructions (requires macOS, Xcode, Apple Developer account)
dist-ios:
	@echo ""
	@echo "iOS builds cannot be automated here — they require Xcode and an"
	@echo "Apple Developer account. Steps:"
	@echo ""
	@echo "  1. Download love2d iOS source:"
	@echo "     https://github.com/love2d/love/releases/download/11.5/love-11.5-ios-source.zip"
	@echo "  2. Download love-apple-dependencies (matching version) from:"
	@echo "     https://github.com/love2d/love-apple-dependencies/releases"
	@echo "  3. Extract and place libraries as described in the love2d wiki"
	@echo "  4. Open platform/xcode/love.xcodeproj in Xcode"
	@echo "  5. Select the love-ios target"
	@echo "  6. Add piper.love to the 'Copy Bundle Resources' build phase"
	@echo "  7. Set your signing team and build"
	@echo ""
	@echo "  Reference: https://love2d.org/wiki/Getting_Started#iOS"
	@echo ""

help:
	@echo ""
	@echo "Piper build system"
	@echo ""
	@echo "Targets:"
	@echo "  make release      Build all platform distributions"
	@echo "  make love         Build piper.love only"
	@echo "  make dist-mac     macOS universal app (piper.app zip)"
	@echo "  make dist-win     Windows x64 (piper.exe + DLLs zip)"
	@echo "  make dist-linux   Linux AppImage + .love zip"
	@echo "  make dist-android Print Android build instructions"
	@echo "  make dist-ios     Print iOS build instructions"
	@echo "  make clean        Remove dist/"
	@echo "  make distclean    Remove dist/ and cached love2d downloads"
	@echo ""
	@echo "Outputs land in dist/ and are named piper-VERSION-PLATFORM.*"
	@echo "VERSION comes from the current git tag (or describes dev state)."
	@echo ""
	@echo "Quick release workflow:"
	@echo "  git tag -a v1.0.0 -m 'Release 1.0.0'"
	@echo "  make release"
	@echo ""
