<div align="center">

<img src="docs/logo.png" width="128" height="128" alt="ResPilot logo">

# ResPilot

**A free, open-source companion for CrossOver® and Wine on macOS — automatic HiDPI/display switching, per-game Wine profiles, and one-click installs for Steam, Epic Games, and more.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange?logo=swift)](Package.swift)
[![Build with Swift Package Manager](https://img.shields.io/badge/built%20with-Swift%20Package%20Manager-red)](Package.swift)

[Download](#installation) · [Features](#features) · [Usage](#quick-start) · [CLI Reference](#cli-reference) · [FAQ](#faq)

</div>

---

## Why ResPilot exists

Searching for a **"CrossOver alternative"** or **"CrossOver for free"**? Here's the honest answer, upfront: CrossOver (by CodeWeavers) and free tools like **Wineskin**, **Kegworks**, and **Sikarugir** are what actually run Windows software on macOS — ResPilot doesn't replace that Wine engine, and it never will pretend to.

What ResPilot **does** replace is the tedious, manual part CrossOver's own UI leaves to you: remembering to switch your Mac's display resolution before launching a game, hand-editing Wine's registry for HiDPI and DPI scaling, hunting down a Steam/Epic/Rockstar installer and clicking through Winetricks dependencies by hand, and doing all of that again for every single game. ResPilot automates it — for free, open-source, with zero telemetry — and it works with **both** CrossOver bottles and 100% free Wineskin-style wrappers.

If you came here looking for a truly free way to run Windows games and apps on your Mac, the honest, complete picture is: **install a free Wine engine (Wineskin/Kegworks, or CrossOver's trial) — then let ResPilot make it actually pleasant to use.**

## Screenshots

<p align="center">
  <img src="docs/screenshot-main.png" width="49%" alt="ResPilot Profiles view">
  <img src="docs/screenshot-install.png" width="49%" alt="ResPilot Install App view">
</p>

## Features

- 🖥️ **Automatic display/HiDPI switching** — pick the exact resolution and DPI scale a game wants; ResPilot switches your Mac's display mode right before launch and restores it the instant the game quits (even if you force-quit — a background watcher and a persisted breadcrumb guarantee the restore, and a menu bar "Restore Display Now" button is always one click away).
- 🎮 **Per-game Wine profiles** — save bottle, launch target, display mode, RetinaMode, LogPixels (DPI), and Wine renderer/ESync/MSync settings once per game; launch with one click or `respilot launch` forever after.
- 📦 **Bottle discovery across both lineages** — finds CrossOver bottles (`~/Library/Application Support/CrossOver/Bottles`) *and* Wineskin/Kegworks/Sikarugir-style wrapped `.app`s automatically, no manual path entry.
- ⬇️ **Genuinely one-click installs** — for Steam, Epic Games Launcher, and Rockstar Games Launcher: ResPilot creates a fresh bottle, downloads the vendor's *own* installer directly from the vendor's *own* domain (never a mirror, never repackaged), provisions the Winetricks dependencies each one needs, and runs it. No browser, no manual download-and-drag.
- 🧰 **CLI + native SwiftUI GUI** — script it in CI/automation with `respilot`, or drive it from a proper macOS menu bar app and window.
- 🔓 **No lock-in, no telemetry, MIT-licensed** — reads and writes standard Wine registry files and CrossOver's own `cxbottle`/`wine` tooling; nothing proprietary, nothing phoning home.

## How ResPilot compares

| | **CrossOver** | **Whisky** | **Wineskin/Kegworks** | **ResPilot** |
|---|---|---|---|---|
| Wine engine | ✅ (paid, patched) | ✅ (free) | ✅ (free) | ❌ — needs one of the others |
| Price | Paid (~$74, 14-day trial) | Free | Free | **Free, MIT** |
| Bottle creation UI | ✅ | ✅ | ✅ | Delegates to CrossOver's own `cxbottle` |
| Automatic display/HiDPI switching per game | ❌ | ❌ | ❌ | ✅ |
| One-click Steam/Epic/Rockstar install | ❌ (manual) | ❌ (manual) | ❌ (manual) | ✅ |
| CLI | ❌ | ❌ | ❌ | ✅ |
| Open source | ❌ | ✅ | ✅ | ✅ |

**In short:** if all you have is CrossOver's 14-day trial or a Wineskin wrapper and nothing else, ResPilot is the free layer on top that makes either one feel like a finished product.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- **One** of:
  - [CrossOver](https://www.codeweavers.com/crossover) (paid, 14-day free trial — required for the one-click install feature specifically, since it's the only lineage with a scriptable bottle-creation tool)
  - A [Wineskin Winery](https://github.com/Gcenx/WineskinServer) / Kegworks / Sikarugir-wrapped app (100% free — display switching and profile launching work fully with these, no CrossOver needed)

## Installation

### Download (recommended)

Grab the latest build from **[Releases](../../releases/latest)** — download `ResPilot.app.zip`, unzip, drag `ResPilot.app` to `/Applications`.

> macOS Gatekeeper will flag it as unsigned on first launch (no paid Apple Developer certificate yet) — right-click the app → **Open** once to bypass, or run `xattr -cr /Applications/ResPilot.app` in Terminal.

### Build from source

```bash
git clone https://github.com/akayyt786/respilot.git
cd respilot
swift build -c release
sh Scripts/build-app-bundle.sh release
open .build/release/ResPilot.app
```

Or grab just the CLI:

```bash
swift build -c release --product respilot
.build/release/respilot help
```

## Quick start

1. Launch **ResPilot.app**. It auto-discovers any CrossOver bottles or Wineskin-style wrapped apps already on your Mac.
2. No games installed yet? Open **Install App** → pick Steam/Epic/Rockstar → **Install**. ResPilot downloads the real installer, creates a bottle, provisions dependencies, and runs it — you finish the vendor's own install wizard.
3. Open **Profiles** → **New Profile** → point it at a bottle and a launch target (an installed `.app`, or a raw `.exe` inside the bottle), pick the display resolution and DPI scale the game wants.
4. Launch from the **Profiles** tab or the menu bar. Your display switches, the game runs, and the second it quits your Mac's display reverts automatically.

## CLI reference

```
respilot list-displays                                  Show current + available display modes
respilot list-bottles                                    Discover CrossOver + Wineskin-style bottles
respilot list-apps                                        One-click install catalog (Steam, Epic, Rockstar)
respilot list-profiles                                    List saved profiles
respilot show-profile --name <name>                       Full profile detail
respilot add-profile --name <name> --kind crossover|wineskin --bottle-name <name> \
  (--launch-app <path> | --launch-exe <path>) [--retina-mode on|off] [--dpi <LogPixels>] \
  [--display-width <n> --display-height <n> [--hidpi]] [--auto-revert on|off]
respilot remove-profile --name <name>
respilot apply --name <name>                              Apply a profile's display/Wine settings and launch
respilot restore                                          Restore display now (safe to call anytime)
respilot install-app --app steam|epic|rockstar --bottle-name <name> [--installer <path>] [--dry-run]
```

Environment: `RESPILOT_HOME` overrides where `profiles.json` / `pending-restore.json` live (default: `~/Library/Application Support/ResPilot`).

## Architecture

- **`ResPilotCore`** — all Wine/display/process logic, zero UI dependencies. Fully unit-tested (91 tests) against protocol-based fakes for process execution, display mode, downloads, and app launching, so the actual invocation shape of every `wine`/`cxbottle`/Winetricks call is asserted, not assumed.
- **`ResPilotApp`** — the SwiftUI menu bar + window app, a thin adapter over `ResPilotCore`.
- **`respilot-cli`** — a Swift Argument Parser-free, dependency-free CLI over the same core.

Every external tool ResPilot shells out to (`wine`, `cxbottle`, [Winetricks](https://github.com/Winetricks/winetricks)) is invoked exactly the way CodeWeavers/Winetricks document, verified against a real CrossOver install rather than assumed — see the doc comments in `Sources/ResPilotCore` for the specific quirks (CrossOver's shared `wine` binary needing `--bottle <name>` addressing, its Perl-wrapper `wine` needing `WINE_BIN`/`WINESERVER_BIN` pointed at the real Mach-O binaries for Winetricks' own arch auto-detection, `--template win10_64` being required for a WOW64-layout bottle, etc.).

## FAQ

**Is ResPilot a free CrossOver alternative?**
No — and if a project's answer to that is "yes," be skeptical of it. CrossOver's actual Wine engine is CodeWeavers' commercial product. ResPilot is a free, open-source *companion* that manages CrossOver bottles (or free Wineskin-style ones) for you. It's genuinely free either way; whether the underlying Wine engine is free too is your choice of Wineskin/Kegworks (free) vs. CrossOver (paid, with a 14-day trial).

**Can I use ResPilot without buying CrossOver?**
Yes, for bottle discovery, display/HiDPI switching, and profile-based launching — all of it works with free Wineskin/Kegworks/Sikarugir wrapped apps. The one-click **Install App** catalog specifically needs CrossOver, since Wineskin-style bottles are each their own hand-built wrapper `.app` with no equivalent single command to script bottle creation with.

**Does ResPilot download or bundle any game or app binaries?**
No. `Install App` downloads each vendor's own installer directly from that vendor's own domain, at install time, verified live — nothing is bundled, mirrored, or redistributed in this repo.

**Will this get me banned from Steam/Epic/Rockstar?**
ResPilot doesn't modify or interact with anti-cheat or account systems; it's just a bottle/display manager. That said, running any game under Wine carries the same anti-cheat compatibility risk running it any other way under Wine does — check the game's own Wine/CrossOver compatibility status first.

## Contributing

Issues and PRs welcome. The test suite (`swift test`) is the contract — a change that doesn't come with (or update) tests covering it won't be considered complete.

## Acknowledgments

- [CodeWeavers CrossOver](https://www.codeweavers.com/crossover) and the [Wine Project](https://www.winehq.org/) — the actual compatibility layer this all sits on top of.
- [Winetricks](https://github.com/Winetricks/winetricks) (GNU LGPL v2.1) — the dependency installer ResPilot shells out to, exactly the way Bottles, Lutris, and Sikarugir do.
- [Wineskin Winery](https://github.com/Gcenx/WineskinServer) / Kegworks / Sikarugir — the free wrapper-app lineage ResPilot also discovers and manages.

## License

[MIT](LICENSE) — see `LICENSE`.
