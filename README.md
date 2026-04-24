# SteamXBridge

SteamXBridge is a lightweight macOS app for Apple Silicon Macs that helps launch x86 Steam games via a Wine runtime (Whisky or CrossOver), with practical performance toggles in one place.

> Reality check: no tool can make **every** x86 game run smoothly on every M2 MacBook Air. This app streamlines launch configuration and helps you tune common compatibility/performance variables.

## What it does

- Saves per-game launch profiles as JSON.
- Generates a launch script with environment variables commonly used for DXVK/MoltenVK setups.
- Starts games through `arch -x86_64` and your selected Wine binary.
- Exposes toggles for DXVK, async shaders, esync/fsync, and frame cap.

## Build and run (development)

```bash
swift build
swift run
```

## Build an installable macOS app bundle

From macOS (required), run:

```bash
./scripts/package_macos_app.sh
```

This creates:

- `dist/SteamXBridge.app` (double-clickable app bundle)
- `dist/SteamXBridge-macOS.zip` (shareable installer archive)

Then install by dragging `SteamXBridge.app` into `/Applications`.

## Typical setup on an M2 MacBook Air

1. Install Steam for macOS.
2. Install a Wine runtime (Whisky or CrossOver).
3. In SteamXBridge, set:
   - **Runtime binary**: path to `wine64` from your runtime.
   - **Game executable path**: Windows `.exe` inside your Steam library/prefix.
4. Enable DXVK and async shaders, keep frame cap around 60 for sustained thermals.
5. Launch and iteratively tune custom env vars.

## Suggested tuning notes

- Prefer medium graphics settings and a 60 FPS cap on fanless Air models.
- Use FSR upscaling in-game when available.
- Disable heavy RT effects; translation overhead is already substantial.
- Keep macOS in Low Power Mode **off** while gaming.

## Profile JSON schema (example)

```json
{
  "id": "A8F9E2C8-6D07-467C-863F-98D64A37CB33",
  "name": "My Game",
  "steamAppID": "123456",
  "gameExecutablePath": "/Users/me/Games/MyGame/Game.exe",
  "protonPrefixPath": "",
  "useDXVK": true,
  "useAsyncShaders": true,
  "esync": true,
  "fsync": true,
  "frameLimit": 60,
  "customEnv": "DXVK_LOG_LEVEL=none"
}
```
