# OpenVibble

English | [中文](./README.zh-CN.md)

<p align="center"><strong>M5Stack dev board still on the way? Start with OpenVibble first.</strong></p>

<p align="center">
  <img src="./docs/readme/icon.png" alt="OpenVibble Icon" width="120" height="120" />
</p>

<p align="center">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-FA7343" />
  <img alt="Android" src="https://img.shields.io/badge/Android-8.0%2B-3DDC84" />
  <img alt="License" src="https://img.shields.io/badge/License-MPL--2.0-brightgreen" />
  <a href="https://github.com/kingcos/OpenVibble/actions/workflows/build.yml">
    <img alt="Build" src="https://github.com/kingcos/OpenVibble/actions/workflows/build.yml/badge.svg?branch=main" />
  </a>
</p>

OpenVibble implements the Claude Desktop Buddy Bluetooth protocol so an iPhone or Android phone can pair directly with Claude Desktop and stand in for the original M5Stack hardware. Paired with the companion macOS app **OpenVibble Desktop**, it can also bridge to other agents such as Claude Code.

It builds on [Claude Desktop Buddy](https://github.com/anthropics/claude-desktop-buddy) with native iOS, Android, and macOS companion UX.

## Screenshots

| Claude Desktop Connected | iOS App | Dynamic Island |
| --- | --- | --- |
| ![Claude Desktop connected](./docs/readme/connected.png) | ![OpenVibble app main screen](./docs/readme/iphone-main.png) | ![OpenVibble Live Activity in Dynamic Island](./docs/readme/dynamic-island.jpg) |

The buddy runtime stays on your phone with support for:
- BLE pairing with Claude Desktop's Hardware Buddy mode
- Approving or denying prompts directly from the phone
- Persona state transitions (idle / attention / busy / sleep / dizzy / celebrate / heart)
- Motion-based interactions (shake, face-down)
- Built-in and over-the-air GIF character packs
- Dynamic Island and Live Activity status surface with quick actions
- Android e-ink friendly terminal theme with English and Simplified Chinese localization

## Requirements

- iOS: macOS with Xcode 17+, iOS 18.0+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a physical iPhone.
- Android: Android Studio Ladybug or newer, JDK 17, Android 8.0+ (API 26), and a physical BLE 5.0-capable device.
- Desktop bridge: macOS 14+ for **OpenVibble Desktop**.
- Simulators/emulators are useful for UI checks, but BLE peripheral advertising requires real hardware.

## Quick Start

For iOS/macOS:

```sh
make bootstrap
open OpenVibble.xcodeproj
```

Or build the iOS app from command line:

```sh
make build
```

Run package tests + app tests:

```sh
make test
```

For Android:

```sh
cd android
./gradlew :app:assembleDebug
./gradlew test
```

The debug APK is written to `android/app/build/outputs/apk/debug/app-debug.apk`. Release signing is intentionally left to your local Android Studio / Gradle signing setup.

## Pair With Claude Desktop

1. In Claude Desktop, enable Developer mode from `Help -> Troubleshooting -> Enable Developer Mode`.
2. Open `Developer -> Open Hardware Buddy...`, click `Connect`, then pick your iOS or Android device.
3. Launch OpenVibble on your phone and grant Bluetooth permission when prompted.

Notes:
- iOS and Android both control BLE/GAP behavior, so some low-level options from MCU firmware are not available.
- Character packs transferred from desktop are saved under app sandbox storage and appear in species/persona pickers automatically.

## Pair With Claude Code (via OpenVibble Desktop)

OpenVibble Desktop is a macOS companion app that bridges OpenVibble to Claude Code — and any other agent that speaks the same hook protocol.

1. Build and run **OpenVibbleDesktop** from the same Xcode workspace.
2. Open the **Hooks** tab in OpenVibble Desktop and register the Claude Code hooks. This writes into `~/.claude/settings.json` and can be removed at any time.
3. Connect your iOS or Android device. Claude Code session events — session start/stop, permission prompts, response completion, user messages — are forwarded to the buddy in real time.

## Pair With Cursor (via cursor-hook)

OpenVibble Desktop exposes a localhost HTTP bridge (`~/.claude/openvibble.port`). `tools/cursor-hook/` forwards Cursor agent hooks to that bridge, which relays state to your phone over BLE.

1. Launch **OpenVibble Desktop** and connect your iPhone.
2. Install Cursor hooks: `tools/cursor-hook/install.sh`
3. Use Cursor Agent normally; shell/MCP permission gates can be approved or denied from the phone.

See [tools/cursor-hook/README.md](./tools/cursor-hook/README.md).

## Contributing

Issues and pull requests are welcome. Please include reproducible steps and environment details when reporting bugs.

## Localization

The iOS and Android apps currently include English (`en`) and Simplified Chinese (`zh-Hans` / `zh`) resources.

## License

Mozilla Public License 2.0. See [LICENSE](./LICENSE).
