# SteamXBridge

SteamXBridge is a lightweight macOS app for Apple Silicon Macs that configures and launches x86 Steam games through a translation layer (Apple's Game Porting Toolkit, CrossOver, or Whisky), with the performance and compatibility toggles that matter on an M2 MacBook Air collected in one place.

> **Reality check.** SteamXBridge does **not** itself translate Windows games — that job belongs to mature stacks like Apple's Game Porting Toolkit (Wine + D3DMetal + Rosetta 2). This app is the orchestrator on top of them: it picks the right backend, sets correct environment variables, warns you about games that can't run, and tunes settings for a fanless chip. No tool can make **every** game run, and some popular games **cannot run at all** (see below).

## Can it run Helldivers 2?

**No — and you should not try.** Helldivers 2 uses **nProtect GameGuard**, a kernel-level anti-cheat that does not execute under Wine or the Game Porting Toolkit. It will fail to launch, and attempting to bypass anti-cheat risks a **permanent account ban**. The same applies to other kernel anti-cheat titles such as Destiny 2 (BattlEye) and Apex Legends (EAC). SteamXBridge detects these by Steam App ID or name and shows a clear warning **before** you launch.

What *does* work well are single-player and anti-cheat-free titles. Expect a steady 60 FPS on lighter games, and roughly 30–45 FPS at low settings with upscaling on GPU-heavy AAA games.

## What it does

- **Scans your installed Steam library** (`libraryfolders.vdf` + `appmanifest_*.acf`, including external drives) and creates a tuned profile in one click, guessing the game's `.exe`.
- Saves per-game launch profiles as JSON.
- Lets you choose the **translation backend**: Apple Game Porting Toolkit (D3DMetal) or Wine + DXVK (MoltenVK).
- Emits only the environment variables that apply to the chosen backend (msync, DXVK, MoltenVK, Rosetta AVX, Metal HUD, Wine FSR, …).
- **Pre-flight compatibility check** that flags anti-cheat games that cannot run.
- **M2 Air performance presets** (Battery Saver / Balanced 60 / Max Quality) plus upscaling and render-scale controls.
- Generates a launch script and starts the game through `arch -x86_64` and your selected Wine binary.

## Translation backends

| Backend | How it works | Best for |
| --- | --- | --- |
| **Game Porting Toolkit (D3DMetal)** *(default)* | Wine + Direct3D 11/12 → Metal, x86 via Rosetta 2 | Most modern D3D11/12 games on Apple Silicon |
| **Wine + DXVK (MoltenVK)** | Direct3D → Vulkan → Metal | Older or Vulkan-native titles, fallback cases |

## Chip-aware GPU optimizations (M1 → M4)

SteamXBridge detects the host chip (M1/M2/M3/M4) and shows how each M4-era GPU feature maps onto your machine.

> **Honesty first:** M3/M4 gains like **Dynamic Caching**, **hardware ray tracing**, and **hardware mesh shading** are physical silicon. Software cannot emulate them into existence on an M1/M2 — emulating hardware in software is slower, not faster. What software *can* do is enable the levers that narrow the gap, and disable features that would fall onto a catastrophic non-hardware path.

With **chip-aware draw-call optimizations** on (default), the app enables the closest software stand-ins:

| M4 hardware feature | On M1/M2, SteamXBridge does |
| --- | --- |
| Dynamic Caching | Metal **argument buffers** + **heap-backed allocations** (`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS`, `MVK_CONFIG_USE_MTLHEAP`) to cut per-draw-call binding and memory overhead |
| Faster command processing | **Immediate command-buffer encoding** (`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS`) to overlap CPU and GPU work |
| Bigger shader throughput | **Parallel pipeline compilation** across all CPU cores (`MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION`); Metal debug/validation layers forced off |
| Ray-tracing cores | **DXR translation forced off** (`D3DM_SUPPORT_DXR=0`) — on M1/M2 the software fallback collapses the frame rate. On M3/M4 a toggle enables it. |
| Higher effective resolution | **MetalFX temporal upscaling / FSR** — render at ~60–77% and upscale; the main software lever for M4-class output from a smaller GPU |

The MoltenVK (`MVK_*`) levers apply to the Wine + DXVK backend; the Metal and DXR levers apply to the Game Porting Toolkit backend.

## Upscaling

- **MetalFX** — enabled via the D3DMetal backend; set it in your runtime's settings and pick a render scale below 100%.
- **AMD FSR** — uses Wine's fullscreen FSR (`WINE_FULLSCREEN_FSR`); works on either backend. Strength is derived from your render-scale slider.
- In-game upscalers (FSR/DLSS menus) always take priority when a game ships them.

## Build and run (development)

Requires **macOS 14+** with the Swift toolchain (Xcode or Command Line Tools). The app uses SwiftUI/AppKit and cannot be built on Linux.

```bash
swift build
swift run
```

## Build an installable macOS app bundle

From macOS, run:

```bash
./scripts/package_macos_app.sh
```

This creates:

- `dist/SteamXBridge.app` (double-clickable app bundle)
- `dist/SteamXBridge-macOS.zip` (shareable installer archive)

Then install by dragging `SteamXBridge.app` into `/Applications`.

## Run and build for release

All commands require **macOS 14+** with the Swift toolchain (Xcode or Command Line Tools); the SwiftUI/AppKit app cannot be built on Linux.

**Run locally (development):**

```bash
swift run                 # launch the app
swift test                # run the unit tests
```

**Compile a release binary:**

```bash
swift build -c release    # optimized build in .build/release/
```

**Package a release `.app` you can ship:**

```bash
# Optional: stamp a version into the bundle (defaults to 1.0.0 / build 1)
APP_VERSION=1.2.3 BUILD_NUMBER=42 ./scripts/package_macos_app.sh
```

This produces `dist/SteamXBridge.app` (ad-hoc signed) and `dist/SteamXBridge-macOS.zip`.

**Cut a release through the release channel (recommended):**

Push a version tag and CI builds, packages, and publishes a downloadable GitHub Release automatically:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The [`Release macOS app`](.github/workflows/release.yml) workflow runs on Apple Silicon runners, stamps the tag version into the bundle, and attaches `SteamXBridge-macOS.zip` to the release. You can also trigger it manually from the **Actions** tab (*Run workflow* → enter a version). Every push to the branch is also built by [`Build macOS app`](.github/workflows/build-macos.yml), which uploads the packaged app as a run artifact.

> First launch: the app is ad-hoc signed (not notarized), so Gatekeeper blocks a downloaded copy. Right-click → **Open**, or run `xattr -dr com.apple.quarantine SteamXBridge.app`.

## Typical setup on an M2 MacBook Air

1. Install Steam for macOS.
2. Install a runtime: Apple's Game Porting Toolkit, **CrossOver**, or **Whisky**.
3. In SteamXBridge, click **Scan** under *Steam library*, pick a game, and **Create profile** — it fills in the name, App ID, and a best-guess `.exe`.
4. Set the **Runtime binary** (path to `wine64` from your runtime) and confirm the **Backend** (Game Porting Toolkit for most modern games).
5. Click the **Balanced 60** preset, then tune the render scale and upscaler.
6. Keep macOS Low Power Mode **off** while gaming, and prefer a 60 FPS cap to keep the fanless Air from throttling.

## Profile JSON schema (example)

```json
{
  "id": "A8F9E2C8-6D07-467C-863F-98D64A37CB33",
  "name": "My Game",
  "steamAppID": "123456",
  "gameExecutablePath": "/Users/me/Games/MyGame/Game.exe",
  "winePrefixPath": "",
  "backend": "gptkD3DMetal",
  "upscaler": "metalFX",
  "resolutionScalePercent": 77,
  "syncPrimitive": "msync",
  "useAsyncShaders": true,
  "frameLimit": 60,
  "showFPSOverlay": false,
  "useChipOptimizations": true,
  "allowRayTracing": false,
  "customEnv": "MTL_HUD_ENABLED=1"
}
```
