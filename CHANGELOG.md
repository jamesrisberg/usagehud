# Changelog

All notable changes to UsageHUD are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

## [0.1.2] - 2026-10-29

### Fixed
- Rebuilt with HUDKit 0.5.1 so animated hover shows retry desktop recovery when macOS
  still considers the panel open on another desktop or a hide is in progress. Hovering
  keeps focus in the app you are using.

## [0.1.1] - 2026-10-13

### Changed
- UsageHUD has its own icon, a lime gauge, in Finder, the menu bar and MacHUD's app list.

## [0.1.0] - 2026-10-13

### Added
- See how much of your Claude and Codex subscriptions you have used: a meter per window
  (Claude's session, weekly and top-model weekly; Codex's windows and credits), each with when
  it resets.
- A desktop widget with the same meters, small or medium.
- Clear states for each subscription: live, stale (with its age), reading, signed out, needs
  you and unavailable, with a plain hint about what to do. A window that has reset since its
  last reading says so instead of showing an old number.
- Uses the sign-ins Claude Code and Codex already have, read-only: UsageHUD never refreshes
  them, so it never signs you out of either. Claude Code's is read from the Keychain without a
  prompt, and only when it has changed.
- Works offline: the last readings are kept and shown as stale, and Codex falls back to its own
  session logs.
- Settings: how often to check, and Claude and Codex each on or off.
- `usagehud usage` and `usagehud refresh` on the command line.
- Control-Option-U shows or hides the panel; inside MacHUD it is a hover button in the tool
  dock, and MacHUD hosts its menu.
