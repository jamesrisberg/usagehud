# UsageHUD's MacHUD contract

UsageHUD implements the MacHUD contract through HUDKit. MacHUD reads
`UsageHUD.app/Contents/Resources/machud.json` without launching the app and talks to the running
app over a Unix socket. The shared parts (socket framing, the required verbs' requests, replies
and errors, `subscribe`, the settings schema format, widgets, what MacHUD sends and expects) are
specified in HUDKit's [docs/CONTRACT.md](../../hudkit/docs/CONTRACT.md); this page lists what
UsageHUD adds.

- Manifest: `Sources/UsageHUD/Resources/machud.json`: app `xyz.machud.usagehud`, socket
  `usagehud`, icon `gauge.with.dots.needle.50percent`, two panels:
  - `main`: `kind: hover`, `order: 6`, title `Usage`, default 340x392, settings schema
    `settings.json`;
  - `usage`: `kind: widget`, sizes `small` and `medium` (default `small`), `multiple: true`,
    `refresh: 60`, no per-instance settings.
- Hover: `panel show from=<edge> anchor=x,y,w,h` slides the panel out of the dock next to the
  button (`HUDPanelTransition.panelFrame`, `HUDAnimation.slide(in:)`); `panel hide to=<edge>` slides
  it back while fading out. Without options it fades in or out where it is. It never takes focus.
  A show reads every provider whose last attempt is over a minute old.
- Widget: the panel's meters, compact (small: Claude's two fullest windows and Codex's fullest;
  medium: both providers with credits). A tap opens the panel. MacHUD places and syncs the
  instances (`widget sync|create|update|remove|edit|reveal`, HUDKit's `HUDWidgetHost`).
- Socket: `~/Library/Application Support/MacHUD/sockets/usagehud.sock` (0600); framing and error
  replies as in HUDKit's CONTRACT.md.
- CLI: `usagehud <command> [key=value ...]` (in `UsageHUD.app/Contents/Helpers/usagehud`, linked
  onto PATH by `install.sh`; grammar and exit codes in HUDKit's docs/CLI.md). `usage` is
  shorthand for `action name=usage`; `refresh [claude|codex]` for `action name=refresh
  [provider=...]`.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's |
| `state` | | `{panels: [{id: "main", visible, mode, badge, status}]}`: `badge` is the fullest shown meter (`"42%"`, absent without a reading); `status` one line per provider (`Claude 42% session, 23% weekly · Codex 0% weekly`, `(stale)` after a stale reading, or `signed out`, `loading`, `unavailable`) |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", ...}` when visibility, the badge or the status line changes |
| `panel show` / `hide` / `toggle` | `id=main`, plus MacHUD's `from=`/`to=`/`anchor=`/`reason=` | see Hover |
| `panel frame` | `id=main x= y= w= h=` | AppKit screen coordinates; at least 100x60 |
| `settings get` | `key=` (optional) | `{settings: {pollMinutes, claudeEnabled, codexEnabled, menuBar.consumed}}` |
| `settings set` | `key=value ...` | validates every value before applying any; turning a provider on reads it |
| `settings schema` | | `{schema}` from `settings.json` |
| `action usage` | | `{online, providers: {claude, codex}}`, below |
| `action refresh` | `provider=claude\|codex\|all` (default `all`) | starts a read past any backoff and replies `{started: [...], online}` at once; `state` is published as each lands. `ok: false` for an unknown provider or one that is off. Offline (`USAGEHUD_OFFLINE`) nothing starts |
| `action show` / `hide` / `toggle` | | same as the panel verbs |
| `widget ...` | | HUDKit's widget verb, type `usage` |
| `menu` / `menu-invoke` | `id=` (and optional `title=`) for `menu-invoke` | the status menu (Show Usage, Refresh Now, Quit), so MacHUD can host it |
| `quit` | | replies, then quits (the socket file is removed) |
| `help` | | lists the registered commands |

`action usage`, per provider:

| Key | |
|---|---|
| `enabled` | the provider's setting |
| `status` | `live`, `stale`, `loading`, `signedOut`, `error` or `off` |
| `inFlight` | a read is running |
| `lastReading` | the last good reading, when there is one: `source` (`live` or `sessionLog`), `observedAt` (ISO 8601), `ageSeconds`, `plan`, `windows` (`id`, `label`, `kind`: `session`/`weekly`/`model`/`monthly`/`other`, `percentUsed` 0-100, `resetsAt`, `resetsInSeconds`), `credits` (`hasCredits`, `unlimited`, `balance`) |
| `problem`, `hint` | why the last attempt gave no reading (`signedOut`, `expired`, `unauthorized`, `keychainDenied`, `keychainNeedsApproval`, `rateLimited`, `server`, `network`, `badPayload`, `credentials`) and the panel's line for it |
| `lastAttemptAt`, `retryAt` | the last attempt, and when a backed-off provider is tried again |

A reading is `live` when the last attempt succeeded from the provider's endpoint and it is
younger than two poll intervals plus a minute; otherwise it is `stale`.

## Reading, never refreshing

UsageHUD sends exactly two requests, both `GET` without a body:

| Provider | Request | Token |
|---|---|---|
| Claude | `https://api.anthropic.com/api/oauth/usage`, `Authorization: Bearer`, `Content-Type: application/json`, `anthropic-beta: oauth-2025-04-20` | `claudeAiOauth.accessToken` from `<CLAUDE_CONFIG_DIR or ~/.claude>/.credentials.json`, else the login Keychain's generic password `Claude Code-credentials` (account: the login name; a custom config directory appends `-` and 8 hex digits of its SHA-256, as Claude Code does) |
| Codex | `https://chatgpt.com/backend-api/wham/usage`, `Authorization: Bearer`, `Content-Type: application/json`, `User-Agent: codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal`, `Chatgpt-Account-Id` | `tokens.access_token` and `tokens.account_id` from `<CODEX_HOME or ~/.codex>/auth.json` |

- A token is never refreshed, rotated or written: an expired one (`expiresAt`, or the JWT's `exp`,
  within a minute) is not sent, and the panel says "Open Claude Code to refresh your sign-in" /
  "Run codex to sign in". Refresh tokens are never read into memory. Claude's access token is
  held in memory until it expires or is refused (a 401 or 403 rereads the store once and retries
  once with a different token); Codex's is reread on every attempt.
- The Keychain: the first read ever may show its prompt; once a read succeeded, scheduled reads
  ask the Keychain not to prompt (an item that would prompt reads as `keychainNeedsApproval`);
  after a denial no scheduled read asks again, and only `refresh` (the button, the menu, the
  CLI) does. The denial survives a relaunch.
- Codex offline fallback: after any failed Codex read, the newest record with a non-null
  `rate_limits` (`primary`/`secondary` `{used_percent, window_minutes, resets_at}`, `credits`,
  `plan_type`) in the six newest `<codex home>/sessions/YYYY/MM/DD/*.jsonl` files replaces the
  reading when it is newer, with `source: sessionLog`.
- Pacing: a read every `pollMinutes`, at launch and on a panel show (each skipped when the last
  attempt is under a minute old). A failed request backs the provider off 2 minutes, doubling to
  30 (`Retry-After`, seconds or a date, wins, capped at 30); `refresh` bypasses the wait, and a
  failure under it still advances the backoff. Signed out or expired sends nothing and does not
  back off.
- `<home>/usage-cache.json` (mode 0600) keeps each provider's last good reading, the backoff and
  the Keychain decision: numbers, dates and plan names, never a token.

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `pollMinutes` | int, 1-60 | `5` | minutes between reads |
| `claudeEnabled` | bool | `true` | read and show Claude; off, the Keychain is never read |
| `codexEnabled` | bool | `true` | read and show Codex |
| `menuBar.consumed` | bool | `true` | hide the menu bar icon while MacHUD hosts the menu (served by HUDKit) |

Stored in `<home>/preferences.json` (`menuBar.consumed` in `<home>/menubar.json`), where home is
`~/Library/Application Support/UsageHUD` or `$USAGEHUD_HOME`. Saved values are merged over
the defaults key by key: a setting added later, or a saved value that does not decode, takes
its default and leaves the others alone.

## Menu bar consolidation

While MacHUD runs it shows UsageHUD's status menu inside its own (`menu`, `menu-invoke`) and the
menu bar icon hides (`HUDStatusItemPolicy`); the icon comes back when MacHUD quits or the user
turns `menuBar.consumed` off. `HUDEditMenu` is installed at launch.

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `USAGEHUD_HOME` | app | base directory for everything the app writes |
| `USAGEHUD_SOCKET` | app, CLI | socket name instead of `usagehud` |
| `USAGEHUD_NO_HOTKEYS` | app | skip the global hotkey (Control-Option-U) |
| `USAGEHUD_OFFLINE` | app | read no credential and send no request; show the cached readings as they are |
| `CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR` | app | which Claude Code credentials file and Keychain item to read |
| `CODEX_HOME` | app | where Codex's `auth.json` and `sessions/` are |

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel over sample readings, write a PNG of it after 1 s, print the path and quit |
| `--snapshot-state <state>` | with `--snapshot`: `live` (default), `stale`, `loading`, `signedout`, `error`, `denied` or `off` |
| `--snapshot-widgets <dir>` | write `usage-<size>[-<state>].png` for both sizes in the `live`, `stale`, `signedout` and `loading` states, print the paths and quit |

Snapshots serve no socket, announce nothing, register no hotkey, add no menu bar item, read no
credential and send no request.
