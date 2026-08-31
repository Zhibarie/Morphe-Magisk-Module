# Morphe Magisk Module

[![Build Modules](https://github.com/Zhibarie/Morphe-Magisk-Module/actions/workflows/build.yml/badge.svg)](https://github.com/Zhibarie/Morphe-Magisk-Module/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Zhibarie/Morphe-Magisk-Module?label=Latest%20Release)](https://github.com/Zhibarie/Morphe-Magisk-Module/releases/latest)
[![Patch Version](https://img.shields.io/badge/Patches-Morphe%20Dev-blue)](https://github.com/MorpheApp/morphe-patches/releases)

> Auto-build **YouTube** and **YouTube Music** with the latest **Morphe dev patches**, refreshed daily.

---

## 📥 Download

Grab the latest build from the [Releases page](https://github.com/Zhibarie/Morphe-Magisk-Module/releases/latest).

| File | Type | Use case |
|---|---|---|
| `youtube-morphe-module-v*-all.zip` | Magisk module | Rooted devices (Magisk/KernelSU) |
| `youtube-morphe-v*-all.apk` | Standalone APK | Non-root devices (needs MicroG) |
| `music-morphe-module-v*-arm64-v8a.zip` | Magisk module | 64-bit devices |
| `music-morphe-module-v*-arm-v7a.zip` | Magisk module | 32-bit (legacy) devices |
| `music-morphe-v*-arm64-v8a.apk` | Standalone APK | 64-bit non-root |
| `music-morphe-v*-arm-v7a.apk` | Standalone APK | 32-bit non-root |

---

## ✨ Features

- ✅ Always uses the **latest dev release** of `MorpheApp/morphe-patches`
- ✅ Builds both **Magisk module** and **standalone APK** for each app
- ✅ Three APK sources for redundancy (archive.org, APKMirror, Uptodown)
- ✅ Automatic daily build via GitHub Actions (23:00 WIB / 16:00 UTC) 
- ✅ Module auto-update via Magisk app (no manual reflash needed)
- ✅ Supports Magisk and KernelSU

---

## 🤖 Auto-Build Schedule

| Schedule | Frequency | Time |
|---|---|---|
| Daily CI check | Once a day | 23:00 WIB (16:00 UTC) |

The CI workflow:
1. Checks if a new Morphe dev patch has been released
2. If yes → triggers `Build Modules` workflow
3. Build downloads stock APKs, patches them, and uploads to Releases
4. Sends a Telegram notification with download links
5. If no update → skips build (saves Actions minutes)

Manual triggers are also available in the **Actions** tab:
- [Build Modules](https://github.com/Zhibarie/Morphe-Magisk-Module/actions/workflows/build.yml) — force build now
- [CI](https://github.com/Zhibarie/Morphe-Magisk-Module/actions/workflows/ci.yml) — check for updates and build if available

---

## 📱 Built Apps

| App | Build Mode | Architecture | Package |
|---|---|---|---|
| YouTube | APK + Module | universal | `com.google.android.youtube` |
| YouTube Music | APK + Module | arm64-v8a + arm-v7a | `com.google.android.apps.youtube.music` |

---

## 📦 Installation

### Option A — Magisk Module (Rooted devices)

1. Download the `.zip` file from the [latest release](https://github.com/Zhibarie/Morphe-Magisk-Module/releases/latest)
2. Open the **Magisk** app
3. Go to **Modules** → **Install from storage**
4. Select the downloaded `.zip` file
5. Tap **Reboot**
6. After reboot, open YouTube — you should see **Morphe** branding in Settings

> 💡 For OTA updates, the module auto-checks for new releases via the `updateJson` field in `module.prop`.

### Option B — Standalone APK (Non-root devices)

1. **Uninstall** the official YouTube app first (otherwise signature conflict)
2. Install [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases) (for Google account login)
3. Download the `.apk` file from the [latest release](https://github.com/Zhibarie/Morphe-Magisk-Module/releases/latest)
4. Install the APK
5. Sign in to your Google account via MicroG

> ⚠️ Without MicroG, non-root YouTube/YouTube Music cannot sign in to Google services.

---

## 🔧 Configuration

Edit [`config.toml`](./config.toml) to customize which apps to build, patch options, and APK sources.

Key settings used in this repo:

```toml
patches-source = "MorpheApp/morphe-patches"
cli-source     = "MorpheApp/morphe-cli"
patches-version = "dev"        # Always latest dev release
rv-brand        = "Morphe"
```

See [`CONFIG.md`](./CONFIG.md) for the full list of options.

To add a new app, just append a new section to `config.toml`:

```toml
[Reddit-Morphe]
app-name = "Reddit"
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-cli"
patches-version = "dev"
rv-brand = "Morphe"
build-mode = "both"
apkmirror-dlurl = "https://www.apkmirror.com/apk/redditinc/reddit/"
uptodown-dlurl = "https://reddit-official-app.en.uptodown.com/android"
archive-dlurl = "https://archive.org/download/jhc-apks/apks/com.reddit.frontpage"
```

---

## 🛠️ Build Locally

### On Termux (Android)
```bash
bash <(curl -sSf https://raw.githubusercontent.com/Zhibarie/Morphe-Magisk-Module/main/build-termux.sh)
```

### On Linux
```bash
git clone https://github.com/Zhibarie/Morphe-Magisk-Module --depth 1
cd Morphe-Magisk-Module
./build.sh
```

Requirements: `java 21+`, `jq`, `zip`, `curl`

---

## 🔒 Disclaimers

- This project is **not affiliated** with YouTube, Google, Morphe, or j-hc.
- Patch bundle is sourced from [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) (dev branch).
- Use at your own risk. For educational and personal use only.

---

## 🙏 Credits

- **[j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module)** — The builder engine this repo forks from
- **[MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches)** — Patch bundle source
- **[MorpheApp/morphe-cli](https://github.com/MorpheApp/morphe-cli)** — Patcher CLI
- **[MorpheApp/MicroG-RE](https://github.com/MorpheApp/MicroG-RE)** — MicroG fork for non-root users
- **[j-hc/zygisk-detach](https://github.com/j-hc/zygisk-detach)** — Detach YouTube/YouTube Music from Play Store updates

---

## 📊 Repo Status

- **Upstream**: [j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module)
- **Patch source**: `MorpheApp/morphe-patches` (dev branch)
- **Build frequency**: Daily at 23:00 WIB

---

## 📜 License

Inherited from upstream — see [LICENSE](./LICENSE).
 <li> Updated daily with the latest versions of apps and patches</li>
 <li> Optimizes APKs and modules for size</li>
 <li> Modules</li>
    <ul>
     <li> recompile invalidated odex for faster usage</li>
     <li> receive updates from Magisk app</li>
     <li> do not break safetynet or trigger root detections</li>
     <li> handle installation of the correct version of the stock app and all that</li>
     <li> support Magisk and KernelSU</li>
    </ul>
</ul>
</details>

## To include/exclude patches or patch other apps

 * Star the repo :eyes:
 * Use the repo as a [template](https://github.com/new?template_name=revanced-magisk-module&template_owner=j-hc)
 * Customize [`config.toml`](./config.toml) using [rvmm-config-gen](https://j-hc.github.io/rvmm-config-gen/)
 * Run the build [workflow](../../actions/workflows/build.yml)
 * Grab your modules and APKs from [releases](../../releases)

also see here [`CONFIG.md`](./CONFIG.md)

## If you are having trouble with the classic mount method of the modules
such as,
- **"Reflash needed"** error after reboots
- **"Suspicious mount detected"** warnings from root detector apps

You can consider using [rvmm-zygisk-mount](https://github.com/j-hc/rvmm-zygisk-mount)

## Building Locally
### On Termux
```console
bash <(curl -sSf https://raw.githubusercontent.com/j-hc/revanced-magisk-module/main/build-termux.sh)
```

### On Linux
```console
$ git clone https://github.com/j-hc/revanced-magisk-module --depth 1
$ cd revanced-magisk-module
$ ./build.sh
```
