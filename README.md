# UsageHUD

A MacHUD app: how much of your Claude and Codex subscriptions you have used, at a glance. One
hover panel with a meter per usage window and a desktop widget with the same meters. macOS 14+.

## What it is

UsageHUD is a menu bar app (no Dock icon) with one panel on HUD glass. For Claude it shows the
five-hour session window, the weekly window and the top model's weekly cap (other per-model
windows appear once they are used); for Codex its windows and the credit balance. Each meter
says how much is used and when the window resets.

It reads the sign-ins you already have: Claude Code's (in the login Keychain) and Codex's
(`~/.codex/auth.json`). It only reads. It never refreshes, rotates or writes either token: both
CLIs rotate their refresh tokens, so a refresh here would sign you out of Claude Code or Codex.
When a token has expired the panel keeps the last reading, marked stale, with a hint to open
Claude Code or run `codex`, which refresh their own sign-ins.

On its own the panel opens from the menu bar icon or a hotkey; inside MacHUD it is a hover
button in the tool dock whose panel slides out while the pointer is over it, and its widget can
be placed on the desktop.

## Install

Check out HUDKit (the shared kit and build scripts) next to this repo, then install:

```sh
ls ~/dev            # hudkit  usagehud
~/dev/usagehud/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/UsageHUD.app`, links
the `usagehud` command onto your PATH and launches it.

The first read of Claude Code's sign-in shows the Keychain's prompt ("UsageHUD wants to use your
confidential information stored in Claude Code-credentials"). Choose **Always Allow**. If you
choose Deny, UsageHUD shows "No access" and does not ask again until you press Refresh.

## Use

| Key | Does |
|---|---|
| Control-Option-U | show or hide the panel |

The menu bar icon has Show Usage, Refresh Now and Quit; while MacHUD runs the icon hides and
MacHUD shows this menu in its own (turn `menuBar.consumed` off to keep the icon). In the MacHUD
dock, hover the button to see the panel; its badge is the fullest meter. UsageHUD takes no drops.

The refresh button in the panel's corner reads both subscriptions now, past any backoff.

## Readings and their states

Each provider's header says how fresh its numbers are:

| State | Means |
|---|---|
| Live | read from the provider within the last two polls |
| *2h 5m old* | the last good reading, kept because the latest read failed or is overdue; the meters turn grey |
| From log, *25m old* | Codex could not be reached (or is signed out): the numbers are from Codex's own session logs |
| Reading… | the first read is on its way |
| Sign-in expired / Signed out | no reading yet; the hint says what to run |
| No access | the Keychain prompt was denied; Refresh asks again |
| Unavailable | the provider refused or failed; the hint says why and when the next try is |

Where the numbers come from:

- **Claude**: `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's OAuth access
  token (the plaintext `~/.claude/.credentials.json` when it exists, else the Keychain item
  `Claude Code-credentials`; run with `CLAUDE_CONFIG_DIR` set, UsageHUD reads that directory's
  file and item, as Claude Code names them).
- **Codex**: `GET https://chatgpt.com/backend-api/wham/usage` with the access token and account id
  from `~/.codex/auth.json` (`CODEX_HOME` if set). Offline, signed out or expired: the newest
  `rate_limits` record in `~/.codex/sessions/**/*.jsonl`, shown with its age.

Reads happen every `pollMinutes` (default 5), at launch, and when the panel opens if the last read
is over a minute old. A failed read backs that provider off: 2 minutes, doubling to 30 (a
`Retry-After` from the provider wins). The last good readings are kept in
`<home>/usage-cache.json` (numbers only, mode 0600), so the panel has numbers the moment it
launches. Tokens are only ever held in memory.

## MacHUD contract

Panel `main`, kind `hover`, socket `usagehud`; widget type `usage` (`small`, `medium`). Verbs: the
HUDKit set (`hello`, `state`, `subscribe`, `panel show|hide|toggle|frame`, `settings
get|set|schema`, `action`, `widget`, `menu`, `quit`) plus `action usage` and `action refresh`.
Full reference: [docs/CONTRACT.md](docs/CONTRACT.md).

```sh
usagehud usage                     # each provider's status, last reading, its age and windows
usagehud refresh                   # read both now
usagehud refresh codex             # one of them
usagehud state                     # MacHUD's view: badge "42%", one status line
usagehud settings set pollMinutes=10
usagehud panel toggle id=main
usagehud quit
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `pollMinutes` | int (1-60) | `5` | minutes between reads |
| `claudeEnabled` | bool | `true` | show Claude (off: its Keychain item is never read) |
| `codexEnabled` | bool | `true` | show Codex |
| `menuBar.consumed` | bool | `true` | hide the menu bar icon while MacHUD hosts the menu |

Set them in MacHUD's settings window or with `usagehud settings set key=value`. Stored in
`~/Library/Application Support/UsageHUD/preferences.json`.

## Build from source

Needs Swift 5.9+ and HUDKit checked out next to this repo (`../hudkit`).

```sh
swift test                 # UsageHUDKitTests + UsageHUDTests
./build.sh                 # build/UsageHUD.app (release; ./build.sh debug for a debug build)
./install.sh               # build, install to /Applications, link the CLI, launch
build/UsageHUD.app/Contents/MacOS/UsageHUD --snapshot /tmp/usagehud.png --snapshot-state stale
build/UsageHUD.app/Contents/MacOS/UsageHUD --snapshot-widgets /tmp/usagehud-widgets
```

Snapshots draw sample readings: they read no credential and send no request.

Build it and it shows up in the dock: with MacHUD running, `./build.sh` announces the new bundle
and its button appears in the tool dock at once, before you launch it (`HUD_NO_ANNOUNCE=1` skips).

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and `scripts/hud-install.sh`
(set `HUDKIT_DIR` if HUDKit lives elsewhere). The version comes from [VERSION](VERSION); changes
are in [CHANGELOG.md](CHANGELOG.md).

The app and menu bar icons (`AppIcon.icns`, `MenuBarIcon.png`, `MenuBarIcon@2x.png` in
`Sources/UsageHUD/Resources`) are HUDKit's placeholder. Draw the app's glyph in
`../hudkit/Icons/usagehud.svg` (see its README) and run `../hudkit/scripts/hud-icon.sh usagehud .`

The Keychain grant belongs to the app's code signature: a build signed with your Apple
Development identity keeps it across rebuilds, an ad-hoc signed one asks again after each build.

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `USAGEHUD_HOME` | base directory for everything UsageHUD writes (default `~/Library/Application Support/UsageHUD`) |
| `USAGEHUD_SOCKET` | socket name (default `usagehud`); the CLI honours it too |
| `USAGEHUD_NO_HOTKEYS` | set to skip registering global hotkeys |
| `USAGEHUD_OFFLINE` | set to read no credential and send no request; the cached readings are shown as they are |

```sh
USAGEHUD_HOME=$(mktemp -d) USAGEHUD_SOCKET=usagehud-test USAGEHUD_NO_HOTKEYS=1 USAGEHUD_OFFLINE=1 HUD_NO_ANNOUNCE=1 \
  build/UsageHUD.app/Contents/MacOS/UsageHUD &
USAGEHUD_SOCKET=usagehud-test build/UsageHUD.app/Contents/Helpers/usagehud hello
```

## License

MIT, see [LICENSE](LICENSE).
