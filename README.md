# findergit

Find your git directories anywhere.

`findergit` locates git repositories (folders containing `.git`) across every environment you work in:

- **Windows terminal** — PowerShell, CMD, Git Bash
- **Windows apps** — File Explorer, desktop app windows
- **macOS terminal** — zsh / bash
- **Linux terminal** — Ubuntu (including WSL)
- **Web / remote** — GitHub connection (list your remote repos) and other git hosts

## Goal

One tool to answer: *"Where are all my git repos, local and remote?"*

## Status

- [x] Windows terminal (PowerShell 5.1 / 7, CMD, Windows Terminal)
- [x] Local web UI (`findergit -w`)
- [ ] Windows app windows
- [ ] macOS terminal
- [ ] Linux / Ubuntu terminal
- [ ] GitHub / web

## Roadmap

1. [ ] Ubuntu / macOS version (one bash script)
2. [ ] GitHub tab — list your GitHub repos, mark which are cloned on this PC
3. [ ] Windows app feel — Start menu / desktop shortcut, hidden server, daily auto scan
4. [ ] Extras — git status column (uncommitted / unpushed), last commit date, duplicate clones, export button in web UI

## Windows usage

### Install (global command)

Add this folder to your user `PATH` (already done on this PC), then open a **new** terminal.
`findergit` then works from any folder in CMD, PowerShell and Windows Terminal.

### Examples

```bat
findergit                  :: find all git repos on all drives (C:, D:, USB...)
findergit -d D             :: all repos on drive D:
findergit -d C,D           :: drives C: and D:
findergit pappime          :: repos whose folder name contains "pappime"
findergit api -d D         :: name filter + drive
findergit -p D:\vs -m 3    :: scan a folder, max 3 levels deep
findergit -c               :: last full scan, instant (cache)
findergit -c api           :: search the cache by name
findergit -f json -o repos.json
findergit -h               :: help
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

Cache: a full scan (plain `findergit`) is saved to `%LOCALAPPDATA%\findergit\cache.json`.

## Web UI

```bat
findergit -w               :: start at http://localhost:7717 and open browser
findergit -w -port 7718    :: other port
```

- Pick drives, folder, name, depth → **Scan**. **Stop** cancels a scan.
- Opens with the last full scan (cache). Live search + sortable columns. Warns when the cache is older than 1 day (**Rescan all**).
- **Activity graph** (GitHub-style): commits made on this PC per day over the last year, pushed or not, read from each repo's local reflog (`.git/logs/HEAD`). Pulled/cloned commits are not counted. Click a day to show only repos active that day. Note: git may prune reflog entries older than ~90 days.
- Per repo: **Folder** (Explorer), **Code** (VS Code), **Term** (Windows Terminal), **Copy** path. Remote links open on GitHub.
- Stop: `Ctrl+C` in the terminal or **Stop server** on the page.
- Local only: listens on `localhost`, API accepts only requests from its own page, and open buttons only work on repo paths from scan results.

Files: `findergit-web.ps1` (server, built-in PowerShell `HttpListener`, no installs), `web/index.html` (page).

### Notes

- Output: name, branch, origin remote, path, last modified. Reads `.git` files directly — `git.exe` not required.
- Credentials in remote URLs are masked (`https://***@github.com/...`).
- Skips: `Windows`, `$Recycle.Bin`, `System Volume Information`, `node_modules`, `.venv`, `venv`, `__pycache__`, `.cache`, `AppData`, symlinks/junctions.
- Detects normal repos, worktrees and submodules (`.git` file).
- Uninstall: remove the `findergit` folder from user `PATH` (Settings → Environment Variables).
