# Oolio Migration Toolkit — Overview

A locally-hosted, web-based wizard that walks a technician through migrating a Windows POS terminal from Bepoz to the Oolio Platform.

The technician copies one folder to the terminal, runs one PowerShell file, and a polished web UI opens in the browser. From there they either click **Migrate** for an end-to-end guided run, or jump into individual modules to do it manually. Steps are run as live PowerShell with their output streamed back into the page in real time. Progress is persisted across sessions so the work can be paused and resumed.

---

## Why this exists

Migrating a Bepoz terminal to Oolio is a multi-step process that mixes:

- Reading and cleaning up Bepoz registry keys
- Stopping and disabling local SQL services (only on machines that have them)
- Backing up the Bepoz `Data` folder
- Killing residual Bepoz processes
- Cleaning out Windows shell:startup, run-keys, and the Bepoz install folder
- Configuring the firewall, network profile, default browser, touch input, and port power settings
- Installing Oolio dependencies (Chrome, WebView2, printer utilities)
- Building the Oolio fullscreen shortcut and wiring it into shell:startup
- Renaming the device and applying the Oolio wallpaper
- Scheduling the final restart

Done by hand, that's a 30-step checklist with site-specific decisions, easy-to-miss safety guards, and several genuinely destructive actions (registry deletes, folder removals, restart-on-timer). Different terminal types (server vs server-till vs till) need different subsets of steps, which makes the checklist even harder to follow. Errors in the wrong order can break a venue.

The toolkit replaces the human checklist with a guided, opinionated run that:

- Picks the right step set automatically based on the terminal type
- Auto-runs everything safe; pauses to ask only when input or confirmation is needed
- Streams live PowerShell output to the browser so the technician sees what's happening
- Treats every danger step as an explicit, ticked confirmation
- Persists progress so a 45-minute migration can survive a coffee break, a venue closure, or a remote-session disconnect
- Ships as a single zip (~35 MB, dominated by the bundled Oolio POS installer; the toolkit itself is ~120 KB) with no install footprint, deployable via ScreenConnect or USB

---

## What it does — the migration journey

The toolkit asks one question at the start — **what kind of terminal is this?** — and adapts the rest of the flow to the answer.

| Code | Type | Description |
|------|------|-------------|
| **S** | Server | On-premises venue server. Runs SQL Server and holds Bepoz data. No POS interface. |
| **ST** | Server Till | Acts as both venue server and POS terminal. Runs SQL, holds data, and runs the till. |
| **T** | Till | POS terminal only. No SQL Server. No Bepoz data stored locally. |
| **KDS** | KDS | Kitchen Display screen. Bepoz cleanup and full hardening, then kds.oolio.io as a fullscreen Chrome app. No SQL, data backup, or CDS. |
| **ALL** | All modules (manual) | Skip the type filter. Show every step in the original 1 / 2 / 3 / 4 order for cherry-picking. |

The migration is organised into four modules. Modules 3 and 4 only apply to Server-Till and KDS machines, so a pure Server or pure Till tech sees a shorter flow.

### Module 1 — Bepoz Software

Cleanly removes the legacy Bepoz install. Order matters: terminate processes before stopping SQL, back up data before deleting the registry, never delete the install folder until a verified backup zip exists.

1. **Read Bepoz registry** — Confirms `SQL_Server`, `DataPath`, `BackupPath` from `HKCU\Software\Backoffice`. No changes.
2. **Terminate processes from C:\Bepoz** — Walks every running process and force-stops any whose executable lives under `C:\Bepoz\` (path-based, not name-based, so it catches arbitrarily-named binaries). _S, ST, T._
3. **Stop and disable SQL Server** — Stops `MSSQL$<instance>` and sets it to Disabled. Skips silently if the service isn't on this machine. _S, ST only._
4. **Zip Bepoz data** — Compresses the `DataPath` folder via the .NET `ZipFile.CreateFromDirectory` API (no 2 GB limit). _S, ST only._
5. **Clear shell:startup** — Empties `%APPDATA%\…\Programs\Startup`. _ST, T only._
6. **Export & clean HKCU Run key** — Exports the full Run key to `C:\OolioBackup\HKCU_Run_<timestamp>.reg` first, then removes known Bepoz entries. _ST, T only._
7. **Delete Bepoz registry** — `Remove-Item HKCU:\Software\Backoffice -Recurse`. **Danger** — confirmation tick required. _ST, T only._
8. **Consolidate backups & remove Bepoz folder** — Moves every `.zip` from `C:\Bepoz\Backup\` (recursive) into `C:\OolioBackup\`, verifies a `Bepoz_Data_*.zip` is present, then removes `C:\Bepoz\` entirely. **Danger.** _ST, T only._

End state: no `C:\Bepoz\` folder. All backup artefacts (data zip + run-key `.reg`) live under `C:\OolioBackup\`.

### Module 2 — Windows Settings

Brings Windows itself in line with Oolio's POS conventions.

1. **Firewall, Private network & sharing** — Firewall on for all three profiles. Every active network set to Private (domain-authenticated networks are left alone — Windows owns that classification). File and Printer Sharing plus Network Discovery enabled **on the Private profile only**, and the Function Discovery services started so shared printers are reachable.
2. **Set Microsoft Edge as default browser** — Enforces Edge for `http`, `https`, `.htm`, `.html`, `.pdf` via the `DefaultAssociationsConfiguration` policy, applied to every user at sign-in. Redirects Internet Explorer launches into Edge and disables the IE11 optional feature. The per-user `UserChoice` key is hash-protected by Windows, so policy is the only supported route — it lands at the next sign-in.
3. **Disable USB / serial port power saving** — Disables USB selective suspend and clears "allow the computer to turn off this device" on every present USB and COM device. The usual cause of printers, cash drawers, and scanners dropping off mid-shift. _ST, T, KDS._
4. **Configure Windows Update active hours** — Locks a 6-hour update window (default 3am) via Group Policy and clears `NoAutoRebootWithLoggedOnUsers`.
5. **Disable Windows nags** — OneDrive prompts, Spotlight, Cortana, news/widgets, Edge first-run, Microsoft Account nag. _ST, T, KDS._
6. **Harden touch input** — Touch keyboard auto-popup in desktop mode; edge swipes, charms and hot corners off; sticky/filter key prompts off; USB autoplay off. _ST, T, KDS._
7. **Disable multi-touch gestures** — Pinch-zoom, multi-finger swipes, and press-and-hold right-click off, written for all users. Single-finger tap keeps working. _ST, T, KDS._
8. **Power plan (never sleep)** — Standby, monitor, disk, and hibernate timeouts to zero; lid action ignored. _ST, T, KDS._
9. **Disable notifications** — Toasts and banners that would cover the POS. _ST, T, KDS._
10. **Check IP configuration** — Reports IP and DHCP status. A static IP surfaces an inline "Switch to DHCP / Skip" pause card.
11. **Remove Bepoz apps from desktop, taskbar & Start** — Targeted removal of Bepoz shortcuts across both desktops, the Start menu (recursive), and taskbar pins. Matches on shortcut name *and* on where the shortcut points, so renamed shortcuts are still caught. Non-Bepoz shortcuts are left untouched. _ST, T, KDS._
12. **Apply Oolio wallpaper** — Copies `assets/wallpaper.jpg` to `C:\Oolio\Assets\` and applies it. _ST, KDS._

Autologon is **not** configured by the toolkit — it is expected on the device image. The `set-startup` step reports its state read-only so a terminal that would stop at the login screen is caught before go-live.

### Module 3 — Oolio Dependencies _(ST, KDS)_

Google Chrome is assumed present on the device image; the toolkit no longer installs it.

1. **Check / install Edge WebView2** — If missing, downloads the Microsoft Evergreen Bootstrapper and installs silently. Internet required. _ST._
2. **Check / install EpsonNet Config** — Downloads ENCU from `ftp.epson.com`, verifies the Epson signature, then launches the wizard for manual click-through while polling for completion. The installer is a WinZip SFX wrapping InstallShield and cannot be silenced. _ST._
3. **Check / install TeamViewer** — If missing, downloads `TeamViewer_Setup_x64.exe` and installs with `/S`, then polls up to 3 minutes for the binary (the installer hands off to a background service installer and exits early). _ST, KDS._

### Module 4 — Oolio Setup _(ST, KDS)_

1. **Deployment options** — Form: deployment mode (**Windows app** native installer — default — or Chrome fullscreen) and whether a Customer Display (CDS) is present. Drives which subsequent steps appear.
2. **Create Oolio folders** — `C:\Oolio\` plus `Assets`, `Certs`, `Logs` subfolders.
3. **Install Oolio POS (native Windows app)** — _Windows-app mode._ Runs `installers\POS-*-installer.exe` silently (electron-builder NSIS, `/S`, per-machine), detects the installed exe, and drops an `Oolio POS.lnk` on the Public desktop. Replaces the Chrome shortcut. The installer is **not** bundled with the toolkit (~35 MB, and only Windows-app deployments need it) and is not committed to git - the technician copies it into `installers\` on the terminal. Build a self-contained zip with `./build-release.ps1 -IncludeInstallers` for USB use.
3b. **Create Oolio POS shortcut** — _Chrome mode._ Public-desktop `.lnk` launching `pos.oolio.io` in Chrome app mode (`--app` + `--start-fullscreen` + `--disable-pinch`), with the site favicon as its icon.
4. **Create Oolio CDS shortcut** — _Only if CDS=Yes._ Public-desktop shortcut launching `cds.oolio.io` on the second display (auto-detected display offset). Always a Chrome app-mode page, regardless of POS deployment mode.
5. **Configure startup** — Copies the desktop shortcut(s) into `shell:startup` so Oolio launches when the autologon user signs in. Reports whether autologon is actually enabled. Tidies up legacy HKCU `Run` entries from older toolkit builds.
6. **Schedule final restart** — `shutdown /r /t 30`. **Danger** — confirmation tick required. Run `shutdown /a` to cancel after it has scheduled.

---

## How it works — architecture

The toolkit is three loosely-coupled layers, all running on the technician's terminal:

```
┌──────────────────────────────────────────────────────────┐
│  Browser at http://localhost:8080                        │
│  ui/index.html + app.js + style.css                      │
│  - Single-page app, no framework, no build step          │
│  - State machine for the guided "Migrate" flow           │
│  - EventSource subscriptions for live SSE output         │
└──────────────────────────────────────────────────────────┘
                          ▲ HTTP / SSE
                          ▼
┌──────────────────────────────────────────────────────────┐
│  PowerShell HTTP listener on :8080                       │
│  server/server.ps1 + server/router.ps1                   │
│  - System.Net.HttpListener, no external deps             │
│  - Routes: /ping, /, /app.js, /style.css, /progress,     │
│    /run?module=X&step=Y                                  │
│  - For /run: spawns powershell.exe with the right        │
│    function, reads its stdout line-by-line, streams      │
│    each line back as a Server-Sent Event                 │
└──────────────────────────────────────────────────────────┘
                          ▲ stdout pipe
                          ▼
┌──────────────────────────────────────────────────────────┐
│  PowerShell module functions                             │
│  scripts/{shared,bepoz,windows,dependencies,oolio}.ps1   │
│  - One function per step (Invoke-BepozReadRegistry etc.) │
│  - All output goes via Write-Output to be streamed       │
│  - Common helpers in shared.ps1: Write-Log, Write-Section│
└──────────────────────────────────────────────────────────┘
```

The entry point is `Launch.ps1`. It elevates if needed, sets the execution policy to `Bypass` for this process only, starts `server/server.ps1` as a background job, polls `/ping` until it answers, and opens the browser. Closing the launcher window cleans up the background job.

State persists in `progress.json` at the toolkit root. The UI POSTs the whole object after every step status change.

### How a single step runs end-to-end

1. Technician clicks **Migrate** (or **Run** on an individual step).
2. Browser opens an `EventSource('/run?module=bepoz&step=zip-data')`.
3. PowerShell server spawns `powershell.exe -Command ". scripts\shared.ps1; . scripts\bepoz.ps1; Invoke-BepozZipData"`.
4. Each line of `Write-Output` from the function is read by the server and immediately written to the SSE response as `data: <line>\n\n`.
5. Browser receives each line, appends it to the live output panel, auto-scrolls, and applies colour by `[OK]` / `[WARN]` / `[ERROR]` markers.
6. When the function returns, the server sends `data: __DONE__\n\n` and closes the response.
7. The UI marks the step `complete` (or `error` if the log contains `[ERROR]`), writes `progress.json`, and the migrate loop advances to the next step.

### The guided "Migrate" loop

The migrate flow is a state machine that classifies each pending step into one of:

- **auto-run** — safe / warn step with no inputs and no danger; runs unattended
- **pause-form** — step with `requiresInputs` (active-hours); shows fields, waits for technician to fill and click Run
- **pause-config** — the deployment-options form
- **pause-manual** — links-only step (printer utilities); waits for "Mark done & continue"
- **pause-confirm** — danger step; requires confirmation tick before Run is enabled
- **pause-optional** — opportunistic prompt (e.g. "Switch to DHCP" if `check-ip` reported a static IP)

The loop runs auto steps in sequence, awaits a Promise on every pause, surfaces a Retry / Skip / Stop card on errors, and resumes from the next pending step on every restart of the toolkit.

---

## Terminal-type filter

A single dropdown choice at session start drives the entire UX:

| Module | S | ST | T |
|--------|---|----|---|
| Bepoz Software | ✓ (read-registry, terminate-processes, stop-sql, zip-data) | ✓ (all 8 steps) | ✓ (read-registry, terminate-processes, plus cleanup steps) |
| Windows Settings | ✓ (firewall, browser, IP) | ✓ (all steps) | ✓ (firewall, browser, IP, touch, power) |
| Oolio Dependencies | — | ✓ | — |
| Oolio POS Setup | — | ✓ | — |

Steps and modules that don't apply are hidden, not greyed out. The technician can flip the type later via the **Change** button on the home pill — the toolkit warns that completed-but-no-longer-relevant steps will disappear from the list (their status is preserved in `progress.json`).

For unusual configurations there's a fourth option, **All modules (manual)**, which bypasses the filter and shows every module in the original 1 / 2 / 3 / 4 order so the technician can cherry-pick.

---

## Screenshots

See `screenshots/` for the captured states:

| | |
|--|--|
| `01-select-type.png` | Terminal-type selector on first run |
| `02-home.png` | Home for an ST terminal — Migrate CTA + module shortcuts |
| `03-module-bepoz.png` | Bepoz module — all 8 steps with risk dots |
| `04-danger-step-expanded.png` | Danger step expanded — confirmation tick gates Run |
| `05-migrate-pause-danger.png` | Migrate flow paused at a danger step |
| `06-migrate-pause-form.png` | Migrate flow paused at a step with an input form |
| `07-migrate-pause-optional-dhcp.png` | Inline "Switch to DHCP" pause when static IP detected |
| `08-migrate-pause-config.png` | Deployment-options form embedded in migrate flow |
| `09-migrate-pause-manual.png` | Printer utilities pause — links + Mark done |
| `10-deployment-config.png` | Same form, alternate state |
| `11-change-type.png` | Change-terminal-type screen with warning |

---

## Tech stack

- **PowerShell 5.1+** (default on Windows 10 / 11) — no PowerShell Core required
- **System.Net.HttpListener** for the local HTTP server — built into .NET, no third-party packages
- **System.IO.Compression.ZipFile** for the data backup — bypasses `Compress-Archive`'s 2 GB ceiling
- **HTML / CSS / vanilla JS** — no framework, no build step, ~25 KB of UI code
- **EventSource (SSE)** — one-way browser ← server streaming for live PowerShell output
- **GitHub Releases** — versioned distribution; `bootstrap.ps1` pulls `OolioMigration.zip` from the latest release

The toolkit code is ~120 KB compressed; the release zip is ~35 MB because it bundles the Oolio POS native installer. No internet required at runtime except for the Chrome / WebView2 / TeamViewer auto-installs in Module 3.

---

## Distribution

Two install paths:

**Remote (recommended) — paste a one-liner into ScreenConnect or any elevated PowerShell on the target:**

```powershell
iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex
```

The bootstrapper downloads `OolioMigration.zip` from the latest GitHub release, extracts to `C:\OolioMigration\`, and launches `Launch.ps1` elevated.

To pull the current `main` branch instead of the last release — useful when `main` is ahead of the last published release:

```powershell
$env:OOLIO_SOURCE='main'; iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex
```

Both sources produce an identical layout on the terminal: the `main` path strips everything `build-release.ps1` excludes (docs, screenshots, `tools/`, and `bootstrap.ps1` itself) so a stale bootstrapper never sits on disk.

**Manual — USB stick:** Download the ZIP from the [Releases page](https://github.com/StephenShawBepoz/oolio-migration-toolkit/releases/latest), copy the `OolioMigration\` folder to the terminal, right-click `Launch.ps1` → Run as Administrator.

---

## Repo layout

```
oolio-migration-toolkit/
  Launch.ps1                  Entry point. Elevates, starts server, opens browser.
  bootstrap.ps1               Remote installer pulled by ScreenConnect one-liner.
  README.md                   Install / quickstart.
  OVERVIEW.md                 This file.
  claude.md                   Original technical spec (frozen for traceability).

  server/
    server.ps1                HttpListener, SSE streaming, /progress GET+POST.
    router.ps1                Step ID → PowerShell function-name map.

  scripts/
    shared.ps1                Get-BepozRegValue, Write-Log, Write-Section.
    bepoz.ps1                 Module 1 step functions (8 steps).
    windows.ps1               Module 2 step functions (6 steps + switch-dhcp helper).
    dependencies.ps1          Module 3 step functions (Chrome, WebView2).
    oolio.ps1                 Module 4 step functions (folders, shortcuts, restart).

  ui/
    index.html                Empty SPA shell.
    app.js                    All client-side logic. State machine, render, SSE handler.
    style.css                 Oolio-purple palette + every layout rule.

  assets/
    wallpaper.jpg             Default Oolio wallpaper, applied by Module 2.
    README.txt

  screenshots/                Captured UI states.
```

---

## Status & roadmap

**Where we are (v1):**
- All four modules functional end-to-end on Windows 10 / 11
- Guided migrate flow with terminal-type filtering
- ScreenConnect bootstrap deployable via one-liner
- Beta-testing on non-production terminals

**Out of scope for v1, planned next:**
- Hosting for the Oolio POS native installer, so it can be downloaded at run time instead of copied onto the terminal by hand
- Element / Gravity printer utility download links (pending Oolio confirmation)
- Multi-terminal batch mode (one terminal at a time for v1)
- Automatic printer IP detection (technician assigns IPs via printer utility manually for v1)

**Known limitations:**
- Autologon password is stored in plaintext at `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon` — this is the standard Windows AutoAdminLogon mechanism, not a toolkit-specific decision. SysInternals `AutoLogon.exe` is the only common alternative and uses an LSA secret instead.
- The migrate flow blasts through auto steps without a "pause between modules" beat. Easy to add if it feels too fast in real testing.

---

## Glossary

| Term | What it means here |
|------|---------------------|
| Bepoz | The legacy POS / back-office software being migrated away from |
| Oolio | The destination POS platform |
| HKCU / HKLM | Registry hives — Current User / Local Machine |
| shell:startup | Per-user folder whose contents auto-launch at login |
| Autologon | Windows feature that logs a specified user in automatically on boot |
| App mode | Chrome flag (`--app=<url>`) that runs a single URL with no browser UI; paired with `--start-fullscreen` |
| CDS | Customer Display — a second screen showing the order to the customer |
| KDS | Kitchen Display System — a screen in the kitchen showing tickets |
| SSE | Server-Sent Events — one-way HTTP streaming used for live output |

---

*Maintained by Stephen Shaw, Head of Onboarding NSW. Built in collaboration with Claude Code.*
