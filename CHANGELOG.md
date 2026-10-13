# Changelog

All notable changes to UsageHUD are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

## [0.1.0] - 2026-10-13

### Added
- Hover panel `main` on HUD glass, shown from the menu bar, Control-Option-H or the MacHUD dock.
- MacHUD contract through HUDKit: manifest, settings schema (`greeting`, `showCount`), `action say`.
- Menu bar consolidation (`menu`, `menu-invoke`, `HUDStatusItemPolicy` with the
  `menuBar.consumed` opt-out in `<home>/menubar.json`) and HUDKit's Edit menu.
- `usagehud` CLI, `--snapshot <png>`, `USAGEHUD_HOME` / `_SOCKET` / `_NO_HOTKEYS` isolation.
