# SteamXBridge

SteamXBridge is a CrossOver-style bottle manager for Apple Silicon Macs. It runs Windows games and apps, Steam above all, in **bottles**: self-contained Windows environments (Wine prefixes). It drives Wine engines you install yourself (CrossOver, Apple's Game Porting Toolkit, WhiskyWine, WineHQ builds) and never bundles or modifies them.

## What it does

- **Bottles.** Create, add, duplicate and remove bottles. New bottles are created with the engine of your choice. With CrossOver, they are made by CrossOver's own `cxbottle` tool, so CrossOver can open them too.
- **Bring what you already have.** Existing CrossOver bottles, Whisky bottles (original and community fork), Sikarugir wrappers and plain Wine/GPTK prefixes are found automatically. Adding one never moves or changes its files.
- **Steam in a bottle.** One click downloads the official Windows Steam installer and installs it into the bottle. Installed games are read from every Steam library, including libraries on other drives (`D:\SteamLibrary` is mapped through the bottle's drive letters). They launch through the Windows Steam client (`steam.exe -applaunch`), so Steam DRM and Steamworks work.
- **Programs.** Start Menu shortcuts are listed the way CrossOver lists launchers. **Pin Program…** adds any `.exe` to the list, and **Run Command** runs any `.exe`, `.msi`, `.bat` or `.lnk`.
- **Bottle settings**, matching CrossOver 26's Advanced Settings:
  - **Graphics renderer:** Automatic, D3DMetal, DXMT, DXVK or WineD3D. The choices depend on what the engine supports.
  - **Graphics options:** DLSS powered by MetalFX, DirectX ray tracing (only on chips with hardware ray tracing, M3 and newer), Metal Performance HUD, and High Resolution Mode.
  - **Performance:** MSync/ESync, and advertising AVX to programs.
  - **Other:** Windows version, custom environment variables, and detailed Wine logging.
  - In CrossOver bottles, the graphics, sync, HUD, ray-tracing, DLSS and AVX settings live in `cxbottle.conf`, as CrossOver itself does. When you add an existing CrossOver bottle, they are read from there, and later edits change only the keys you touch. The Windows version and High Resolution Mode are stored in the bottle's registry. Custom variables and logging are applied at launch, and a `cxbottle.conf` value overrides a custom variable of the same name.
  - Other engines receive all settings as launch-time variables.
- **Tools.** Wine Configuration, Control Panel, Game Controllers, Internet Settings, Task Manager, Registry Editor, Command Prompt and File Explorer, plus Open C: Drive, Simulate Reboot and Force Quit.
- **Logs.** Every run is logged with its command, environment and exit status, so a game that "does nothing" leaves a trace.
- **Compatibility notes.** Known titles carry a verdict and one-click recommended settings, for example HELLDIVERS 2 (below). A known App ID is authoritative, so similarly named games never inherit another game's verdict.

## Engines

| Engine | How to get it | Notes |
| --- | --- | --- |
| **CrossOver 26** (CodeWeavers) | [codeweavers.com](https://www.codeweavers.com/crossover), paid, with a free trial | Most compatible. Bottles are run through CrossOver's own launcher, so its fixes apply. The only engine that runs HELLDIVERS 2. |
| **Game Porting Toolkit** (Apple D3DMetal) | `brew install --cask gcenx/wine/game-porting-toolkit` | Direct3D 11/12 through D3DMetal. Steam's window can render black here (its web view, steamwebhelper). |
| **WhiskyWine** | Installed by Whisky or the community fork (frankea/Whisky) | D3DMetal and DXVK; Whisky itself is archived. Steam's window can render black here too. |
| **Wine Stable / Devel / Staging** | [Gcenx macOS builds](https://github.com/Gcenx/macOS_Wine_builds) (the Homebrew casks were disabled in September 2026) | Upstream Wine; no D3DMetal or MSync. Steam's window can render black here (an open Wine bug). |
| **Sikarugir** wrappers | Sikarugir-App/Sikarugir | Each wrapper's built-in engine is usable for its own prefix. |
| **Custom** | Settings > Add Engine… | Any `wine` / `wine64` binary. |

Every shipping engine except CrossOver's ARM64 Preview is x86_64 and needs **Rosetta 2** (`softwareupdate --install-rosetta --agree-to-license`). SteamXBridge never forces `arch -x86_64`: macOS runs x86_64 engines under Rosetta automatically, and native ARM64 engines natively.

## Can it run HELLDIVERS 2?

**Yes, with CrossOver 26 or later; 26.2 or later is recommended.** CodeWeavers added it in CrossOver 26 (February 2026) and rates it *Runs Well* on 26.3. After a game update it stopped launching on 26.0 and 26.1 until 26.2 fixed it. Online play has worked, but it is not guaranteed. HELLDIVERS 2's anti-cheat (nProtect GameGuard) works only with CodeWeavers' own patches. It does not get past GameGuard in Whisky, the Game Porting Toolkit or plain Wine. CodeWeavers calls the anti-cheat working "a happy accident", and game patches have broken it before, so it can break again.

Setup:
1. Create a bottle with the CrossOver engine and let SteamXBridge install Steam.
2. Install HELLDIVERS 2 from Steam.
3. Open its compatibility notes (the ⓘ button) and click **Apply Recommended Settings**: D3DMetal, AVX advertised, MSync off.
4. Click **Play**.

**Expectations on an M2 MacBook Air:** about 20–35 fps at low settings around 720p–1080p, with stutter in heavy fights. That figure is an estimate from base M3/M4 MacBook Air reports (30–40 fps); there are no direct M2 measurements. 16 GB of memory is recommended.

## Apple Silicon GPU features

SteamXBridge reads your chip (M1 through M5 and later) and shows which GPU features it really has. Dynamic Caching, hardware ray tracing and hardware mesh shading arrived with M3. They are silicon, and software cannot add them to an M1/M2, so ray tracing stays off there instead of falling back to slow emulation. The practical lever on any Apple Silicon Mac is upscaling: enable **DLSS powered by MetalFX** (CrossOver 26, macOS 26) and pick DLSS in the game, or use the game's own FSR/XeSS.

## Install

1. Download `SteamXBridge-macOS.zip` from a release (or from a CI run's artifacts), unzip it, and move **SteamXBridge.app** to /Applications.
2. The app is ad-hoc signed, not notarized, so macOS blocks the first launch. Since macOS 15, Control-click > Open no longer bypasses this. Instead:
   - Open the app once and dismiss the warning.
   - Go to **System Settings > Privacy & Security**, scroll to Security and click **Open Anyway**, then confirm.
   - Alternatively, run `xattr -dr com.apple.quarantine /Applications/SteamXBridge.app` in Terminal.

## Build from source

Requires macOS 14 or later on Apple Silicon, with Xcode or the Command Line Tools.

```bash
swift run                 # launch the app
swift test                # run the test suite
swift build -c release    # optimized build in .build/release/
APP_VERSION=2.0.0 BUILD_NUMBER=1 ./scripts/package_macos_app.sh   # dist/SteamXBridge.app + .zip
```

The core logic (bottles, engines, Steam libraries, launch planning, the process runner) is platform-neutral, and its test suite also runs on Linux (`swift test`). The SwiftUI app itself builds only on macOS.

## Releases

- **Build macOS app** runs on every push. It tests and packages the app on an Apple Silicon runner and uploads `SteamXBridge-macOS` as a run artifact.
- **Release macOS app**:
  - Run it manually from the Actions tab with a version, and it builds a **draft** release to review. Nothing is public until you click Publish.
  - Push a tag like `v2.0.0`, and it publishes directly.
  - Either way, the release is built from and tagged at the exact commit tested.

## Where things live

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/SteamXBridge/Bottles/<id>.json` | Bottle metadata |
| `~/Library/Application Support/SteamXBridge/Prefixes/` | Prefixes of bottles SteamXBridge created |
| `~/Library/Application Support/SteamXBridge/Logs/<bottle id>/` | Run logs |
| `~/Library/Application Support/CrossOver/Bottles/` | CrossOver's bottles (left where they are) |

## Using CrossOver with SteamXBridge

SteamXBridge launches *your* installed and licensed copy of CrossOver through its documented command-line wrapper, the same way the Heroic launcher does. It does not copy, bundle or patch CrossOver or Apple's D3DMetal. CrossOver remains a separate CodeWeavers product with its own license.
