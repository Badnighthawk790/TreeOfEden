## SteamXBridge 2.0: a standalone, CrossOver-style bottle manager

SteamXBridge is rebuilt around **bottles**: self-contained Windows environments that each have an engine, a Windows version and graphics settings. It works the way CrossOver 26 does and **brings its own Windows engine**, so nothing else needs to be installed. CrossOver and other engines are still used when they are on the Mac.

### New
- **Built-in engine.** Wine 11.0 with DXMT 0.80 (Direct3D 10/11 on Metal) and DXVK 1.10.3, unpacked on first launch. New bottles use it by default.
- **MetalFX upscaling and a frame-rate cap** for DXMT games.
- **Bottles.** Create, add, duplicate and remove bottles, and keep them between launches. With CrossOver installed, new bottles are created by CrossOver's own tool.
- **Existing bottles.** CrossOver bottles, Whisky bottles (original and fork), Sikarugir wrappers and Wine/GPTK prefixes are found and can be added without being moved.
- **One-click Steam.** Downloads the official Windows Steam installer and installs it into the bottle. Games are found in every Steam library, including other drives, and launch through Steam, so DRM works.
- **Programs view, Run Command, Install Software, pinned programs.**
- **Advanced Settings like CrossOver 26:**
  - Graphics renderer: Automatic / D3DMetal / DXMT / DXVK / WineD3D.
  - DLSS powered by MetalFX, DirectX ray tracing (M3 and newer), and Metal HUD.
  - High Resolution Mode, MSync/ESync and AVX.
  - Windows version and environment variables.
- **Tools.** Wine Configuration, Control Panel, Game Controllers, Internet Settings, Task Manager, Registry Editor, Command Prompt, Simulate Reboot, Force Quit and Open C: Drive.
- **Run logs** with exit status for every launch.
- **Engine detection.** CrossOver 26 (and the ARM64 Preview), the Game Porting Toolkit, WhiskyWine, WineHQ builds, Sikarugir and custom engines.
- **HELLDIVERS 2.** It runs only with CrossOver 26 or later (26.2 or later recommended), not on the built-in engine, because its anti-cheat needs CodeWeavers' patches. The app offers one-click recommended settings and warns when a bottle's engine cannot run it.

### Fixed
- Arguments and environment variables are now passed straight to the engine, with no generated shell script, so a value can no longer inject commands.
- Games start in their own folder, from the bottle where Steam is installed (previously from an empty prefix).
- Windows paths in Steam's library list (`D:\SteamLibrary`) now map to the right folder.
- Legacy `LibraryFolders` files are read.
- M5 and newer chips are recognized.
- Settings that did nothing on macOS were removed, among them FSR fullscreen upscaling, MoltenVK tweaks that were already defaults or slower, and fsync.
- MSync is paired with ESync where D3DMetal expects it.

### Requirements
- macOS 14 or later on Apple Silicon, Rosetta 2 (`softwareupdate --install-rosetta --agree-to-license`), and about 1.3 GB of free space.
- Not on the built-in engine: DirectX 12-only games (they need D3DMetal) and games whose anti-cheat needs CrossOver. In-game videos need the free GStreamer runtime.

### Third-party software
The built-in engine is the community Whisky fork's runtime (WhiskyWine Libraries 3.1.1), bundled unmodified. Licenses and source links: THIRD_PARTY_NOTICES.md in the app's Resources.

### First launch
This build is ad-hoc signed, not notarized. Open it once, then go to **System Settings > Privacy & Security** and click **Open Anyway**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/SteamXBridge.app`.
