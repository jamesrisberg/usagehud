# Changelog

All notable changes to UsageHUD are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

### Added
- See how much of your Claude and Codex subscriptions you have used: a meter per window
  (Claude's session, weekly and top-model weekly; Codex's windows and credits), each with when
  it resets.
- A desktop widget with the same meters, small or medium.
- Clear states for each subscription: live, stale (with its age), reading, signed out, no
  access and unavailable, with a plain hint about what to do.
- Uses the sign-ins Claude Code and Codex already have, read-only: UsageHUD never refreshes
  them, so it never signs you out of either.
- Works offline: the last readings are kept and shown as stale, and Codex falls back to its own
  session logs.
- Settings: how often to check, and Claude and Codex each on or off.
- `usagehud usage` and `usagehud refresh` on the command line.
- Control-Option-U shows or hides the panel; inside MacHUD it is a hover button in the tool
  dock, and MacHUD hosts its menu.
