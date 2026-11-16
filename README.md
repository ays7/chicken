<p align="center">
  <img src="cotvnc/ChickenFork.png" alt="Chicken Fork Logo" width="200" />
</p>

# Chicken Fork

[![Platform](https://img.shields.io/badge/macOS-11.0%2B-lightgray)](#)
[![Architecture](https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2F%20Intel)-blue.svg)](#)
[![License](https://img.shields.io/badge/license-GPL--2.0%2B-green.svg)](LICENSE.md)

**Chicken Fork** is a modernized, high-performance, native VNC and RDP remote desktop client for macOS. Based on the classic *Chicken of the VNC* codebase, this fork updates the application to run natively and smoothly on modern macOS architectures (including Apple Silicon and Intel) and modern display configurations.

---

## 🚀 Major Updates & Modernizations (Since last Chicken release in 2011)

Chicken Fork has undergone significant modernization to enhance stability, display performance, OS integration, and compatibility:

* **Native Microsoft Remote Desktop (RDP) Support (2026.11 / 2026.12)**: Full RDP client powered by FreeRDP 3.x and OpenSSL 4.x, with NLA/CredSSP, TLS, Apple VideoToolbox H.264 decoding, audio output, multi-monitor fullscreen, and `.rdp` / `rdp://` support.
* **Dynamic Desktop Resizing**: Automatically resizes the remote desktop to match your macOS window or fullscreen layout on compatible VNC and RDP hosts.
* **Retina & High-DPI Support**: Opt-in native Retina resolution and Windows DPI scaling (`Auto`, `100%`, `150%`, `200%`) for RDP sessions, with dynamic `2x` ↔ `1x` display migration and per-monitor DPI.
* **Seamless Clipboard Sync**: Automatic bidirectional clipboard synchronization with UTF-8 / Unicode support across both VNC and RDP.


### ⚙️ Architecture & Build Modernization
* **Universal Binary Support**: Build target configurations updated to compile a Universal App (native `arm64` for Apple Silicon and `x86_64` for Intel).

### 🎨 Groundbreaking Branding
* **The "Liquid Glass" Visual Revolution**: We retired the charmingly retro, pixelated chicken icon and replaced it with a brand-new, ultra-glossy **"Liquid Glass" logo**. Sporting translucent, eye-straining 3D glassmorphism, it depicts our beloved chicken mascot paired with a dinner fork. Does it improve connection latency, fix memory leaks, or reduce CPU usage? Absolutely not. But it does make the app look like a premium, VC-funded SaaS utility, which we all know is the real measure of software engineering excellence.
---

## 🌟 Key Features

* **Lightweight & Native Cocoa UI**: Built specifically for macOS, using native Cocoa controls for quick start times and minimal memory footprint.
* **Secure SSH Tunneling**: Easily establish secure connections to remote hosts through built-in SSH tunneling.
* **Fullscreen Mode**: Supports native macOS fullscreen mode for immersive remote management.
* **Multi-Connection Profile Manager**: Store and manage profiles for multiple servers, including keyboard profiles, color depth settings, and connection behaviors.

---

## 📝 Release Notes

* [Version 2026.12.1](release-notes/2026.12.1.md) — Metal GPU rendering, Retina/HiDPI RDP scaling, Windows LAN RDP discovery, Fit-to-Window / 1:1 scaling, instant ARD authentication, macOS trust store RDP verification, and ARC migration.
* [Version 2026.12](release-notes/2026.12.md) — FreeRDP 3.33.1 and OpenSSL 4.1.0 upgrade with Apple VideoToolbox hardware H.264 decoding, multi-monitor full-screen RDP, fluid cursor handling, and styled Retina DMG installer.
* [Version 2026.11](release-notes/2026.11.md) — Product renamed to **Chicken Fork**, version bump to 2026.11, and initial FreeRDP 3.32.2 integration.
* [Version 2026.9](release-notes/2026.9.md) — Touch Bar support, Apple Remote Desktop (ARD) authentication, SSH passphrase guidance, and fullscreen space management fixes.
* [Version 2026.6](release-notes/2026.6.md) — Universal binary (Apple Silicon + Intel), dynamic desktop resizing, UTF-8 extended-clipboard, Retina display fixes, and application modernizations.

---

## 🛠️ Building Chicken Fork

### Prerequisites
* macOS 11.0 or later
* Xcode 12.0 or later

### Build Instructions
1. Clone the repository:
   ```bash
   git clone https://github.com/ays7/chicken.git
   cd chicken
   ```
2. Open the Xcode project:
   ```bash
   open cotvnc/ChickenFork.xcodeproj
   ```
3. Select the scheme (e.g., **Chicken Fork**) and build/run (`Cmd + R`) or archive it to build the Universal release application.

### Updating Vendored Dependencies
`CryptoSwift` is vendored via `git subtree` at `cotvnc/Source/CryptoSwift`. To pull a newer upstream release:
```bash
git subtree pull --prefix=cotvnc/Source/CryptoSwift https://github.com/krzyzanowskim/CryptoSwift.git <tag> --squash
```

### Distribution & Code Signing
For packaging signed and notarized `.dmg` releases for direct macOS distribution via GitHub Releases, refer to the [Apple Developer ID Code Signing & Notarization Guide](docs/developer-id-signing.md).

---

## 📄 License

Chicken Fork is distributed under the **GNU General Public License v2.0 or later** (GPL-2.0+). See [LICENSE.md](LICENSE.md) for details.

Precompiled release binaries bundling FreeRDP and OpenSSL (Apache 2.0) are distributed under **GNU General Public License v3.0** in accordance with Section 9 of the GPL-2.0 ("or later") clause.
