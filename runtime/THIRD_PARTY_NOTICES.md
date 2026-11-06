# Third-party software in SteamXBridge

SteamXBridge's own code is published in this repository. The app also ships a
Windows runtime that other projects made. SteamXBridge bundles that runtime
unmodified: the archive below, checked against its SHA-256. It is unpacked
into `~/Library/Application Support/SteamXBridge/Runtime` the first time the
app starts. The full license texts are in the app at
`Contents/Resources/Licenses`, and in this repository at `runtime/licenses`.

SteamXBridge does not include CrossOver, any CodeWeavers software, or Apple's
D3DMetal / Game Porting Toolkit. When CrossOver is installed, SteamXBridge only
starts the user's own copy.

## The bundled runtime

| | |
| --- | --- |
| Archive | WhiskyWine "Libraries" 3.1.1, from the community Whisky fork |
| Download | https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz |
| SHA-256 | `01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3` (332,438,526 bytes) |
| Release page | https://github.com/frankea/Whisky/releases/tag/v3.1.1 |

The archive contains the following components.

| Component | License | Source code |
| --- | --- | --- |
| Wine 11.0, macOS build by Gcenx, with its Mac driver patched to export the functions DXMT needs | LGPL-2.1-or-later. Copyright © 1993–2026 the Wine project authors | https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz · https://gitlab.winehq.org/wine/wine/-/tree/wine-11.0 · build recipes: https://github.com/Gcenx/macports-wine and https://github.com/Gcenx/macOS_Wine_builds · runtime packaging: https://github.com/frankea/Whisky |
| DXMT 0.80 (Direct3D 10/11 to Metal) | MIT. Copyright © 2023 Feifan He. See `DXMT-MIT.txt` | https://github.com/3Shain/dxmt/tree/v0.80 |
| DXVK-macOS 1.10.3 (Direct3D 10/11 to Vulkan) | Zlib. Copyright © 2017 Philip Rebohle, © 2019 Joshua Ashton | https://github.com/Gcenx/DXVK-macOS/tree/1.10.x |
| MoltenVK (Vulkan to Metal) | Apache-2.0. Copyright © The Brenwill Workshop Ltd. and The Khronos Group Inc. | https://github.com/KhronosGroup/MoltenVK |
| Wine Mono 10.4.1 | MIT and others (the Mono and .NET runtime licenses) | https://gitlab.winehq.org/mono/wine-mono |
| Wine Gecko 2.47.4 | MPL-2.0 | https://dl.winehq.org/wine/wine-gecko/2.47.4/ |
| GnuTLS | LGPL-2.1-or-later | https://www.gnutls.org |
| Nettle and Hogweed | LGPL-3.0-or-later (used under LGPL-3.0) | https://www.lysator.liu.se/~nisse/nettle/ |
| GMP | LGPL-3.0-or-later (used under LGPL-3.0) | https://gmplib.org |
| libtasn1 | LGPL-2.1-or-later | https://www.gnu.org/software/libtasn1/ |
| libidn2 | LGPL-3.0-or-later (used under LGPL-3.0) | https://www.gnu.org/software/libidn/ |
| libunistring | LGPL-3.0-or-later (used under LGPL-3.0) | https://www.gnu.org/software/libunistring/ |
| GNU libiconv and libcharset | LGPL-2.1-or-later | https://www.gnu.org/software/libiconv/ |
| GNU gettext (libintl) | LGPL-2.1-or-later | https://www.gnu.org/software/gettext/ |
| p11-kit | BSD-3-Clause | https://github.com/p11-glue/p11-kit |
| FreeType | FTL (FreeType License) | https://freetype.org |
| SDL2 | Zlib | https://github.com/libsdl-org/SDL |
| ICU 76 | Unicode-3.0 | https://github.com/unicode-org/icu |
| libxml2, libxslt and libexslt | MIT | https://gitlab.gnome.org/GNOME/libxml2 · https://gitlab.gnome.org/GNOME/libxslt |
| libffi | MIT | https://github.com/libffi/libffi |
| libinotify-kqueue | MIT | https://github.com/libinotify-kqueue/libinotify-kqueue |
| Brotli 1.1.0 | MIT | https://github.com/google/brotli |
| zlib 1.3.1 | Zlib | https://zlib.net |
| bzip2 1.0.8 | bzip2-1.0.6 | https://sourceware.org/bzip2/ |
| LZ4 1.10.0 | BSD-2-Clause | https://github.com/lz4/lz4 |
| XZ Utils (liblzma) | 0BSD | https://tukaani.org/xz/ |
| Zstandard 1.5.6 | BSD-3-Clause | https://github.com/facebook/zstd |
| libpcap 1.10.5 | BSD-3-Clause | https://www.tcpdump.org |
| libpng 1.6 | libpng-2.0 | http://www.libpng.org/pub/png/libpng.html |
| MacPorts legacy-support | MIT and APSL-2.0 | https://github.com/macports/macports-legacy-support |

## Your rights under the LGPL

Wine and the LGPL libraries above are free software. You may replace them with
versions you build yourself. SteamXBridge runs whatever Wine is in its runtime
folder, and it can also use any other engine you add in Settings. For the
complete corresponding source of the binaries in this runtime, use the links
above, or open an issue on this repository to get a copy.

## Software SteamXBridge downloads but does not ship

- The Windows Steam client: SteamXBridge downloads Valve's official installer
  (`SteamSetup.exe`) from Valve's servers when you click **Install Steam**.
  Steam is subject to the Steam Subscriber Agreement.
- Apple's Game Porting Toolkit / D3DMetal is never bundled or downloaded.
