<p align="center"><img src="assets/reporaccoon-256.png" width="128" height="128" alt="RepoRaccoon icon: a raccoon rummaging through a git folder"></p>

# RepoRaccoon

Sniffs out your git repositories anywhere.

RepoRaccoon locates git repositories (folders containing `.git`) across every environment you work in. The command is `reporaccoon`.

- **Windows terminal** — PowerShell, CMD, Git Bash
- **Windows apps** — File Explorer, desktop app windows
- **macOS terminal** — zsh / bash
- **Linux terminal** — Ubuntu (including WSL)
- **Web / remote** — GitHub connection (list your remote repos) and other git hosts

## Goal

One tool to answer: *"Where are all my git repos, local and remote?"*

## Status

- [x] Windows terminal (PowerShell 5.1 / 7, CMD, Windows Terminal)
- [x] Local web UI (`reporaccoon -w`) — raccoon mascot, activity heatmap, most active repos, filters, pagination
- [x] Automatic scanning (daily scheduled task + auto-scan when the web UI opens with old results)
- [ ] Windows app windows
- [ ] macOS terminal
- [ ] Linux / Ubuntu terminal
- [ ] GitHub / web

## Roadmap

1. [ ] Ubuntu / macOS version (one bash script)
2. [ ] GitHub tab — list your GitHub repos, mark which are cloned on this PC
3. [ ] Windows app feel — Start menu / desktop shortcut with the raccoon icon, hidden server
   - [x] Daily auto scan (`reporaccoon -install`)
4. [ ] Extras — git status column (uncommitted / unpushed), last commit date, export button in web UI
   - [x] Duplicate clones (copies badge + filter)

## Windows usage

### Install (global command)

Add this folder to your user `PATH` (already done on this PC), then open a **new** terminal.
`reporaccoon` then works from any folder in CMD, PowerShell and Windows Terminal.

### Examples

```bat
reporaccoon                :: find all git repos on all drives (C:, D:, USB...)
reporaccoon -d D           :: all repos on drive D:
reporaccoon -d C,D         :: drives C: and D:
reporaccoon pappime        :: repos whose folder name contains "pappime"
reporaccoon api -d D       :: name filter + drive
reporaccoon -p D:\vs -m 3  :: scan a folder, max 3 levels deep
reporaccoon -c             :: last full scan, instant (cache)
reporaccoon -c api         :: search the cache by name
reporaccoon -f json -o repos.json
reporaccoon -h             :: help
```

### Options

| Option | Meaning |
|---|---|
| `[name]`, `-n` | Repo folder name (contains). Wildcards `*` `?` allowed |
| `-d` | Drive(s) to scan: `D`, `D:`, `D:\`, `C,D` |
| `-p` | Folder path(s) to scan |
| `-m` | Max folder depth, `0` = unlimited (default) |
| `-f` | `table` (default), `list`, `json`, `csv`, `path` |
| `-o` | Save output to file |
| `-c` | Use cache from last full scan (no scanning) |
| `-l` | List available drives |
| `-a` | Also scan `AppData` (skipped by default — tool caches) |
| `-x` | Extra folder names to skip: `-x build,dist` |
| `-nested` | Keep scanning inside repos (submodules, nested repos) |
| `-v` | Version |
| `-h`, `--help`, `/?` | Help |

Cache: a full scan (plain `reporaccoon`) is saved to `%LOCALAPPDATA%\RepoRaccoon\cache.json`.

## Automatic scanning

```bat
reporaccoon -install            :: scan every day at 12:30 and 5 min after logon (hidden)
reporaccoon -install -at 09:00  :: other time
reporaccoon -uninstall          :: remove it
```

- Creates a Windows scheduled task **"RepoRaccoon daily scan"** for your user (no admin needed). It runs a full scan in the background and refreshes the cache, so `reporaccoon -c` and the web UI are always current. Missed runs (PC off) run as soon as possible.
- Log: `%LOCALAPPDATA%\RepoRaccoon\background.log` (last 100 lines).
- The web UI also scans all drives automatically when you open it and the saved results are missing or older than 1 day (press **Stop** to cancel).

## Web UI

```bat
reporaccoon -w             :: open the web UI (server starts hidden in the background)
reporaccoon -stop          :: stop the background server now
reporaccoon -w -fg         :: run the server in this window instead (visible log, Ctrl+C to stop)
reporaccoon -w -port 7718  :: other port
```

- Live raccoon mascot: blinks, follows your mouse, digs while scanning, holds up its find when done, hides when a scan fails. Respects Windows "reduce motion".
- Pick drives, folder, name, depth → **Scan**. **Stop** cancels a scan.
- **Most active** panel beside the heatmap: top 5 repos for 30d / 90d / 1y (or the selected day); click one to filter the table.
- Opens with the last full scan (cache). Live search + sortable columns. Warns when the cache is older than 1 day (**Rescan all**).
- **Activity graph** (GitHub-style): commits made on this PC per day over the last year, pushed or not, read from each repo's local reflog (`.git/logs/HEAD`). Pulled/cloned commits are not counted. Click a day to show only repos active that day. Note: git may prune reflog entries older than ~90 days.
- Per repo: **Code** (VS Code) plus a **⋯** menu — open folder (Explorer), open terminal here, copy path, copy remote URL. Remote links open on GitHub.
- The server runs hidden (no terminal window). Closing the browser tab keeps it running; it **stops by itself 10 minutes after the last page is closed** (open pages send a small heartbeat every minute; a running scan also keeps it alive). Running `reporaccoon -w` again reuses a running server or starts a new one.
- Stop it immediately with `reporaccoon -stop`. With `-fg`, stop with `Ctrl+C`.
- Switch between the raccoon page and the classic page with the **Raccoon | Classic** switch at the top right.
- Local only: listens on `localhost`, API accepts only requests from its own page, and open buttons only work on repo paths from scan results.

Files: `reporaccoon-web.ps1` (server, built-in PowerShell `HttpListener`, no installs), `web/index.html` (page). The previous design is kept at `http://localhost:7717/classic` (`web/classic.html`).

### Notes

- Output: name, branch, origin remote, path, last modified. Reads `.git` files directly — `git.exe` not required.
- Credentials in remote URLs are masked (`https://***@github.com/...`).
- Skips: `Windows`, `$Recycle.Bin`, `System Volume Information`, `node_modules`, `.venv`, `venv`, `__pycache__`, `.cache`, `AppData`, symlinks/junctions.
- Detects normal repos, worktrees and submodules (`.git` file).
- Uninstall: remove the `RepoRaccoon` folder from user `PATH` (Settings → Environment Variables).

## Icon

`assets/reporaccoon.svg` is the source. It is used as the web UI favicon and logo (served at `/icon.svg`).

Windows icon: `assets/reporaccoon.ico` (16–256 px) and `assets/reporaccoon-256.png`. Rebuild after editing the SVG:

```bat
powershell -ExecutionPolicy Bypass -File assets\build-icon.ps1
```

Uses headless Microsoft Edge to render each size — no extra installs.

## License

[MIT](LICENSE) © 2026 riigait
