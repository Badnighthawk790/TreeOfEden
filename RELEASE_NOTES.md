## SteamXBridge 2.0: a CrossOver-style bottle manager

SteamXBridge is rebuilt around **bottles**: self-contained Windows environments that each have an engine, a Windows version and graphics settings. It works the way CrossOver 26 does, on top of the Wine engines you already have.

### New
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
- **HELLDIVERS 2.** It runs with CrossOver 26 or later; the app offers one-click recommended settings and warns when a bottle's engine cannot run it.

### Fixed
- Arguments and environment variables are now passed straight to the engine, with no generated shell script, so a value can no longer inject commands.
- Games start in their own folder, from the bottle where Steam is installed (previously from an empty prefix).
- Windows paths in Steam's library list (`D:\SteamLibrary`) now map to the right folder.
- Legacy `LibraryFolders` files are read.
- M5 and newer chips are recognized.
- Settings that did nothing on macOS were removed, among them FSR fullscreen upscaling, MoltenVK tweaks that were already defaults or slower, and fsync.
- MSync is paired with ESync where D3DMetal expects it.

### Requirements
- macOS 14 or later on Apple Silicon, plus a Wine engine, and Rosetta 2 for x86_64 engines.

### First launch
This build is ad-hoc signed, not notarized. Open it once, then go to **System Settings > Privacy & Security** and click **Open Anyway**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/SteamXBridge.app`.
