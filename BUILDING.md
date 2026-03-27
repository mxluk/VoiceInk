# Building VoiceInk

This guide provides detailed instructions for building VoiceInk from source.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.4 or later
- **Xcode** (full app from the Mac App Store — Command Line Tools alone are not sufficient)
- Swift (bundled with Xcode)
- Git

> **Note for Xcode 26+:** The `FluidAudio` dependency has Swift 6 strict-concurrency
> errors when compiled with Xcode 26 or later. The Makefile handles this automatically
> via source patches applied before compilation. See
> [Xcode 26 Compatibility](#xcode-26-compatibility) for details.

---

## Quick Start with Makefile (Recommended)

The easiest way to build VoiceInk is using the included Makefile, which automates
the entire build process including building and linking the whisper framework.

### Simple Build Commands

```bash
# Clone the repository
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk

# Build everything (recommended for first-time setup)
make all

# Or for development (build and run)
make dev
```

### Available Makefile Commands

| Command | Description |
|---|---|
| `make check` / `make healthcheck` | Verify all required tools are installed |
| `make whisper` | Clone and build the whisper.cpp XCFramework |
| `make setup` | Prepare the whisper framework for linking |
| `make build` | Build the VoiceInk Xcode project |
| `make local` | Build for local use (no Apple Developer certificate needed) |
| `make patch-fluid-audio` | Apply Swift 6 / Xcode 26 compatibility patches to FluidAudio |
| `make run` | Launch the built VoiceInk app |
| `make dev` | Build and run (ideal for development workflow) |
| `make all` | Complete build process (default) |
| `make clean` | Remove build artifacts and dependencies |
| `make help` | Show all available commands |

### How the Makefile Helps

The Makefile automatically:
1. **Manages Dependencies** — Creates a dedicated `~/VoiceInk-Dependencies` directory for all external frameworks
2. **Builds Whisper Framework** — Clones whisper.cpp and builds the XCFramework with the correct configuration
3. **Handles Framework Linking** — Sets up the whisper.xcframework in the proper location for Xcode to find
4. **Applies Compatibility Patches** — Patches the FluidAudio SPM dependency for Xcode 26 / Swift 6 compatibility (see below)
5. **Verifies Prerequisites** — Checks that git, xcodebuild, and swift are installed before building
6. **Streamlines Development** — Provides convenient shortcuts for common development tasks

---

## Building for Local Use (No Apple Developer Certificate)

If you don't have an Apple Developer certificate, use `make local`:

```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

This builds VoiceInk with ad-hoc signing using a separate build configuration
(`LocalBuild.xcconfig`) that requires no Apple Developer account.

### How It Works

The `make local` command uses:
- `LocalBuild.xcconfig` to override signing and entitlements settings
- `VoiceInk.local.entitlements` (stripped-down; no CloudKit/keychain groups)
- `LOCAL_BUILD` Swift compilation flag for conditional code paths

#### Two-Stage Build Process

`make local` uses a two-stage build to apply compatibility patches before compilation:

1. **Resolve** — `xcodebuild -resolvePackageDependencies` checks out all SPM packages
   to the pinned revisions from `Package.resolved`.
2. **Patch** — Source-level patches are applied to the checked-out FluidAudio package
   (see [Xcode 26 Compatibility](#xcode-26-compatibility)).
3. **Compile** — `xcodebuild build -skipPackageUpdates` compiles the app, skipping
   re-resolution so the patched files are used.

Your normal `make all` / `make build` commands are completely unaffected.

**Limitations of local builds:**
- No iCloud dictionary sync
- No automatic updates (pull new code and run `make local` again to update)

---

## Xcode 26 Compatibility

### Problem

The `FluidAudio` SPM dependency declares `swift-tools-version: 6.0`, which enables
Swift 6 language mode for that package. Xcode 26 enforces strict Sendable and
region-based isolation checks, causing three build errors in
`StreamingAsrManager.swift`:

```
error: sending 'asrManager' risks causing data races
```

### Root Cause

Two files in FluidAudio require patching:

**`Sources/FluidAudio/ASR/AsrManager.swift`**

`AsrManager` is a `final class` that gets passed across actor/task boundaries, but
it does not conform to `Sendable`. The class already documents that "we manage
safety ourselves", so conforming to `@unchecked Sendable` is the correct fix:

```swift
// Before
public final class AsrManager {

// After
public final class AsrManager: @unchecked Sendable {
```

**`Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift`**

Three stored properties are annotated `nonisolated(unsafe)`. Under Swift 6, accessing
a `nonisolated(unsafe)` value from within an actor and passing it to an `async` method
is flagged as a potential data race. Since all three types are now `Sendable`
(`AsrManager` via the patch above; `CtcKeywordSpotter` and `VocabularyRescorer` are
already `Sendable` structs), the annotation is unnecessary and can be removed:

```swift
// Before
nonisolated(unsafe) private var asrManager: AsrManager?
nonisolated(unsafe) private var ctcSpotter: CtcKeywordSpotter?
nonisolated(unsafe) private var vocabularyRescorer: VocabularyRescorer?

// After
private var asrManager: AsrManager?
private var ctcSpotter: CtcKeywordSpotter?
private var vocabularyRescorer: VocabularyRescorer?
```

### Why the Two-Stage Build?

Xcode's SPM integration resets all checkouts to the exact revision recorded in
`Package.resolved` before each build. Patches applied to the checkout are therefore
silently overwritten on the next invocation. The solution is to:

1. Run `xcodebuild -resolvePackageDependencies` — lets Xcode perform its checkout.
2. Apply patches to the freshly-checked-out source.
3. Run `xcodebuild build -skipPackageUpdates` — compiles without re-resolving, so
   the patched files are used.

The `make patch-fluid-audio` target encapsulates step 2 and can be run standalone
if you need to re-apply patches after a manual package resolution.

---

## Manual Build Process (Alternative)

If you prefer to build manually or need more control over the build process, follow
these steps.

### Building whisper.cpp Framework

```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
./build-xcframework.sh
```

This creates the XCFramework at `build-apple/whisper.xcframework`.

### Building VoiceInk

1. Clone the VoiceInk repository:
   ```bash
   git clone https://github.com/Beingpax/VoiceInk.git
   cd VoiceInk
   ```

2. Add the whisper.xcframework to your project:
   - Drag and drop `../whisper.cpp/build-apple/whisper.xcframework` into the project
     navigator, or
   - Add it manually under **Frameworks, Libraries, and Embedded Content** in project
     settings.

3. Resolve packages, apply patches, and build:
   ```bash
   # Resolve packages
   xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -resolvePackageDependencies \
       -derivedDataPath .local-build

   # Apply Xcode 26 compatibility patches
   make patch-fluid-audio

   # Build
   xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
       -derivedDataPath .local-build \
       -skipPackageUpdates \
       CODE_SIGN_IDENTITY="" \
       build
   ```

   Or open `VoiceInk.xcodeproj` in Xcode, resolve packages, apply the patches above
   manually, then build with Cmd+B.

---

## Development Setup

1. **Xcode Configuration**
   - Install the full Xcode app (not just Command Line Tools)
   - After installation, activate it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

2. **Dependencies**
   - [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for on-device transcription
   - [FluidAudio](https://github.com/FluidInference/FluidAudio) for streaming ASR (patched at build time)
   - All other SPM dependencies are resolved automatically

3. **Building for Development**
   - Use the Debug configuration
   - Run `make dev` to build and immediately launch the app

4. **Testing**
   - Run the test suite before making changes
   - Ensure all tests pass after your modifications

---

## Troubleshooting

### Xcode not found / "requires Xcode, but active developer directory is a command line tools instance"

You have Command Line Tools installed but not the full Xcode app.

1. Install Xcode from the Mac App Store.
2. Activate it:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

### Swift 6 / Xcode 26 concurrency errors in FluidAudio

Run the patch target manually, then rebuild with `-skipPackageUpdates`:

```bash
make patch-fluid-audio
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
    -derivedDataPath .local-build \
    -xcconfig LocalBuild.xcconfig \
    -skipPackageUpdates \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS=$(pwd)/VoiceInk/VoiceInk.local.entitlements \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
    build
```

Or just run `make local` from scratch — it applies the patches automatically.

### Build errors after `make clean` / full rebuild

`make clean` removes the derived data directory, which also removes the patched
SPM checkouts. The next `make local` re-resolves and re-applies all patches
automatically, so a full rebuild always works.

### Other build errors

1. Clean derived data: `make clean`
2. Check Xcode and macOS versions
3. Verify whisper.xcframework is built: `ls ~/VoiceInk-Dependencies/whisper.cpp/build-apple/`
4. Check the [issues](https://github.com/Beingpax/VoiceInk/issues) page or open a new issue
