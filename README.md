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

There is nothing to allow: UsageHUD reads Claude Code's Keychain item through
`/usr/bin/security`, the tool Claude Code wrote it with, so the item already trusts it and no
prompt appears (and rebuilding or re-signing UsageHUD changes nothing). If the Keychain ever
refuses, Claude shows "Needs you" and is not tried again until Claude Code updates its sign-in or
you press Refresh; that refresh is the one time the Keychain may ask, and for this item it can
ask for your login password.

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
| *2h 5m old* | the last good reading, kept because the latest read failed or is overdue; the meters turn grey, and a window that has reset since shows "reset, waiting for a new reading" |
| From log, *25m old* | Codex could not be reached (or is signed out): the numbers are from Codex's own session logs |
| Reading… | the first read is on its way |
| Sign-in expired / Signed out | no reading yet; the hint says what to run |
| Needs you | the Keychain refused Claude Code's sign-in to `security`; Refresh tries again |
| Unavailable | the provider refused or failed; the hint says why and when the next try is |

Where the numbers come from:

- **Claude**: `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's OAuth access
  token: from the plaintext `~/.claude/.credentials.json` when it exists, else from the Keychain
  item `Claude Code-credentials` with `/usr/bin/security find-generic-password -s
  "Claude Code-credentials" -a <login name> -w` (run with `CLAUDE_CONFIG_DIR` set, UsageHUD
  reads that directory's file and item, as Claude Code names them). Before reading the secret,
  UsageHUD reads only the item's modification date; the secret is read again only when that
  changes, so an expired, unchanged sign-in costs nothing. The token is held in memory, sent
  only to api.anthropic.com, and never written anywhere.
- **Codex**: `GET https://chatgpt.com/backend-api/wham/usage` with the access token and account id
  from `~/.codex/auth.json` (`CODEX_HOME` if set). Offline, signed out or expired: the newest
  `rate_limits` record in `~/.codex/sessions/**/*.jsonl`, shown with its age.

Reads happen every `pollMinutes` (default 5), at launch, and when the panel opens if the last read
is over a minute old. A failed read backs that provider off: 2 minutes, doubling to 30 (a
`Retry-After` from the provider wins). Redirects are refused, so a token never follows one. The
last good readings are kept in `<home>/usage-cache.json` (numbers only, created 0600), so the
panel has numbers the moment it launches. Tokens are only ever held in memory.

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

## Isolation env vars for testing

**Run a test instance with `USAGEHUD_OFFLINE=1` and `HUD_NO_ANNOUNCE=1`**, plus its own home,
socket and no hotkeys. Offline it reads no credential and sends no request, and without the
announcement it stays out of your MacHUD dock:

```sh
USAGEHUD_OFFLINE=1 HUD_NO_ANNOUNCE=1 USAGEHUD_HOME=$(mktemp -d) USAGEHUD_SOCKET=usagehud-test USAGEHUD_NO_HOTKEYS=1 \
  build/UsageHUD.app/Contents/MacOS/UsageHUD &
USAGEHUD_SOCKET=usagehud-test build/UsageHUD.app/Contents/Helpers/usagehud hello
```

| Variable | Effect |
|---|---|
| `USAGEHUD_OFFLINE` | set to read no credential and send no request; the cached readings are shown as they are |
| `HUD_NO_ANNOUNCE` | `1`: the build and the launch are not announced to MacHUD |
| `USAGEHUD_HOME` | base directory for everything UsageHUD writes (default `~/Library/Application Support/UsageHUD`); it does not imply offline |
| `USAGEHUD_SOCKET` | socket name (default `usagehud`); the CLI honours it too |
| `USAGEHUD_NO_HOTKEYS` | set to skip registering global hotkeys |

## License

MIT, see [LICENSE](LICENSE).
