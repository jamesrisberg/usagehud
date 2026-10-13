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
  A show reads every provider whose last attempt is over a minute old (see Pacing below).
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
| `problem`, `hint` | why the last attempt gave no reading (`signedOut`, `expired`, `unauthorized`, `keychainNeedsApproval`, `rateLimited`, `server`, `network`, `badPayload`, `credentials`) and the panel's line for it |
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
  "Run codex to sign in". Each access token is sent only to its own provider's host above, and
  kept only in memory. Refresh tokens pass through the JSON parser and are never kept or sent.
- How Claude's token is read. `stamp` first, which reads no secret: the plaintext file's
  modification date when the file holds a token, else the Keychain item's attributes only
  (`SecItemCopyMatching` with `kSecReturnAttributes`, never `kSecReturnData`), for
  `kSecAttrModificationDate`. The secret is read only when no token is held or that stamp
  changed: from the file, or by running `/usr/bin/security find-generic-password -s
  "Claude Code-credentials" -a <login name> -w` (fixed path, an argument array, no shell, stdin
  closed, stderr discarded, stdout kept in memory and zeroed after parsing; 10 s timeout, 60 s
  for the owner's refresh). Claude Code writes its item with `security`, so the item's access
  list already trusts that tool: the read shows no prompt and does not depend on UsageHUD's own
  signature. An expired token in an unchanged store costs a metadata read and nothing else.
- A 401 rereads the store only if its stamp changed since the token was read, then retries once
  with the new token; a 403 is the provider's error (`server`), and never touches the store.
- If `security` is refused (exit 36 interaction not allowed, 51 authorization failed, 128
  canceled) or does not answer in time, Claude reads as `keychainNeedsApproval` ("needs you")
  and the item is not read again until it changes or the owner refreshes (the button, the menu,
  `usagehud refresh`). That refusal survives a relaunch. If the item's access list no longer
  trusts `security`, the owner's refresh is what may bring up the Keychain's own prompt, which
  for a `security`-created item can ask for the login password.
- Codex offline fallback: after any failed Codex read, the newest record with a non-null
  `rate_limits` (`primary`/`secondary` `{used_percent, window_minutes, resets_at}`, or the older
  `resets_in_seconds` from the record's timestamp, `credits`, `plan_type`) in the six most
  recently written `<codex home>/sessions/**/*.jsonl` files (by modification date, so a long
  session in an older date folder counts) replaces the reading when it is newer, with
  `source: sessionLog`. Files are read backwards in 256 KB chunks, off the service's actor, and
  each file's answer is remembered until its device, inode, size or modification date changes.
- Pacing: a read every `pollMinutes` and at launch (skipped within 30 s of the last attempt, and
  while backing off), and on a panel show (skipped within a minute of the last attempt, and
  while a remote problem backs off; a local one, signed out, expired or the Keychain, is checked
  again at once, which sends nothing). Every Claude failure backs off 2 minutes, doubling to 30;
  Codex's network failures do the same, its local ones do not (they send nothing, and the
  session log fills in). `Retry-After`, seconds or a date, wins, capped at 30. `refresh`
  bypasses the wait, and a failure under it still advances the backoff.
- Redirects are refused: a 3xx is the provider's error, so the bearer, the account id and the
  user agent never go anywhere but the two hosts.
- A window whose reset time has passed since its reading no longer holds its number: the panel
  shows "reset, waiting for a new reading", `usage` marks it `hasReset`, and it leaves the
  badge and the status line.
- `<home>/usage-cache.json` keeps each provider's last good reading, the backoff and the
  Keychain refusal's stamp: numbers, dates and plan names, never a token. It is written to a
  temporary file created 0600 and renamed into place.

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
| `--snapshot-state <state>` | with `--snapshot`: `live` (default), `stale`, `loading`, `signedout`, `error`, `needsyou` or `off` |
| `--snapshot-widgets <dir>` | write `usage-<size>[-<state>].png` for both sizes in the `live`, `stale`, `signedout` and `loading` states, print the paths and quit |

Snapshots serve no socket, announce nothing, register no hotkey, add no menu bar item, read no
credential and send no request.
