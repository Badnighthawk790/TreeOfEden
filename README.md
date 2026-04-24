# SteamXBridge

SteamXBridge is a lightweight macOS app for Apple Silicon Macs that helps launch x86 Steam games via a Wine runtime (Whisky or CrossOver), with practical performance toggles in one place.

> Reality check: no tool can make **every** x86 game run smoothly on every M2 MacBook Air. This app focuses on reducing setup friction and keeping overhead low.

## What it does

- Saves per-game launch profiles as JSON.
- Supports two launch modes:
  - **Steam App ID mode** (no exe path needed): opens Steam game directly by App ID.
  - **Direct exe mode**: launches a configured Windows exe through your Wine runtime.
- Offers **Low resource mode** (reduced logging + lower process priority + conservative frame cap behavior).
- Includes an optional **background helper** (LaunchAgent) to process queued launches with minimal CPU impact.

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

## GitHub download build (macOS equivalent of an .exe page)

A GitHub Actions workflow builds and publishes `SteamXBridge-macOS.zip` to GitHub Releases for tags like `v1.0.0`.

```bash
git tag v1.0.0
git push origin v1.0.0
```

Then download from the repository **Releases** page.

## Use it in background with low resource usage

1. Create/load a profile.
2. Enable **Low resource mode**.
3. Click **Enable Background Helper**.
4. (Optional) Click **Queue Background Launch** if you want helper-triggered launch.
5. Open Steam normally, download your game, and run via Steam App ID mode or Launch Now.

The helper runs on a polling interval (default 45s, minimum 20s) and executes queued requests using low priority (`nice -n 20`).

## Suggested tuning notes for M2 MacBook Air

- Target 60 FPS or lower for sustained thermals.
- Prefer medium graphics presets.
- Disable heavy RT effects where possible.
- Keep macOS Low Power Mode off while gaming.
