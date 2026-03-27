# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build

# Path to the FluidAudio SPM checkout (resolved during the build)
FLUID_AUDIO_DIR := $(LOCAL_DERIVED_DATA)/SourcePackages/checkouts/FluidAudio

.PHONY: all clean whisper setup build local patch-fluid-audio check healthcheck help dev run

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# ──────────────────────────────────────────────────────────────────────────────
# patch-fluid-audio
#
# Applies source-level patches to the FluidAudio SPM checkout so that it
# compiles under Xcode 26+ (Swift 6 strict concurrency enforcement).
#
# Root cause
# ----------
# FluidAudio declares `swift-tools-version: 6.0`, which enables Swift 6
# language mode for that package. Xcode 26 then enforces strict Sendable /
# region-based isolation checks. Two files trigger errors:
#
#   Sources/FluidAudio/ASR/AsrManager.swift
#     • `AsrManager` is a `final class` passed across actor/task boundaries.
#       Fix: conform to `@unchecked Sendable` (the class itself is already
#       documented as "we manage safety ourselves").
#
#   Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift
#     • Three stored properties (`asrManager`, `ctcSpotter`, `vocabularyRescorer`)
#       are annotated `nonisolated(unsafe)`.  Under Swift 6, accessing a
#       `nonisolated(unsafe)` value from an actor context and passing it to an
#       `async` function is flagged as a data race.
#       Fix: remove `nonisolated(unsafe)` — all three types are now Sendable
#       (`AsrManager` via the patch above; the other two were already structs
#       that conform to `Sendable`).
#
# Why the two-stage build?
# ------------------------
# Xcode's SPM integration always resets checkouts to the pinned revision from
# `Package.resolved` before building.  We therefore:
#   1. Run `-resolvePackageDependencies` to perform the checkout.
#   2. Apply patches to the checked-out source.
#   3. Build with `-skipPackageUpdates` so Xcode skips re-resolution and picks
#      up the patched files.
# ──────────────────────────────────────────────────────────────────────────────
patch-fluid-audio:
	@echo "Patching FluidAudio for Swift 6 / Xcode 26 compatibility..."
	@ASR_MGR="$(FLUID_AUDIO_DIR)/Sources/FluidAudio/ASR/AsrManager.swift"; \
	STREAMING_MGR="$(FLUID_AUDIO_DIR)/Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift"; \
	chmod u+w "$$ASR_MGR" "$$STREAMING_MGR"; \
	sed -i '' \
		's/public final class AsrManager {/public final class AsrManager: @unchecked Sendable {/' \
		"$$ASR_MGR"; \
	sed -i '' \
		's/nonisolated(unsafe) private var asrManager: AsrManager?/private var asrManager: AsrManager?/' \
		"$$STREAMING_MGR"; \
	sed -i '' \
		's/nonisolated(unsafe) private var ctcSpotter:/private var ctcSpotter:/' \
		"$$STREAMING_MGR"; \
	sed -i '' \
		's/nonisolated(unsafe) private var vocabularyRescorer:/private var vocabularyRescorer:/' \
		"$$STREAMING_MGR"; \
	echo "FluidAudio patches applied."

# Build for local use without Apple Developer certificate
#
# Uses a two-stage approach to apply compatibility patches before compilation
# (see the patch-fluid-audio target above for full details).
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	@echo "Stage 1/3: Resolving Swift package dependencies..."
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-resolvePackageDependencies
	@echo "Stage 2/3: Applying source compatibility patches..."
	@$(MAKE) patch-fluid-audio
	@echo "Stage 3/3: Compiling VoiceInk..."
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		-skipPackageUpdates \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS=$(CURDIR)/VoiceInk/VoiceInk.local.entitlements \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying VoiceInk.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
		echo "Run with: open ~/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$$HOME/Downloads/VoiceInk.app" ]; then \
		echo "Opening ~/Downloads/VoiceInk.app..."; \
		open "$$HOME/Downloads/VoiceInk.app"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@rm -rf $(LOCAL_DERIVED_DATA)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Prepare the whisper framework for linking"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  patch-fluid-audio  Apply Swift 6 / Xcode 26 compatibility patches to FluidAudio"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts and local derived data"
	@echo "  help               Show this help message"
