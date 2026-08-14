# Changelog

All notable changes to the Oolio Migration Toolkit. Newest first.

## Unreleased

### Fixed
- **`consolidate-backups` no longer trusts a stale backup.** The deletion guard only checked that *some* `Bepoz_Data_*.zip` existed — a weeks-old zip from a previously aborted migration authorised recursive deletion of `C:\Bepoz` containing every trade since. The guard is now freshness-based: if the terminal holds data files, the newest backup zip must be **newer than the newest data file**, or the step aborts and tells the technician to re-run `zip-data`. Terminals with no local data (plain Till / KDS, which never run `zip-data`) no longer require a zip at all — previously the step could never succeed on those types.
- **`zip-data` no longer reports silent success with unprotected data on disk.** If `DataPath` is missing from the registry (e.g. `delete-registry` already ran on a previous attempt) but `C:\Bepoz\Data` still holds files, the step now errors instead of skipping.
- **`clean-desktop` only ever deletes shortcuts.** The name match ran before the extension check, so venue documents like "Bepoz EOD Procedures.pdf" or "Back Office Roster.xlsx" were deleted (no recycle bin). Only `.lnk`/`.url` files are candidates now, and generic names ("Back Office") no longer delete by name alone — Bepoz's own renamed shortcuts are caught by their `C:\Bepoz\` target instead, so "MYOB Back Office.lnk" survives. The test contract in `tests/patterns.tests.ps1` covers all of these cases.
- **Removing a Bepoz taskbar pin no longer resets every other pin.** The step deleted Explorer's whole Taskband layout cache; now only the Bepoz `.lnk` is removed and Explorer re-reads the pin folder on restart.
- **`clear-startup` moves items to `C:\OolioBackup\Startup_<timestamp>\` instead of deleting them**, and skips `Oolio*` entries so a re-run after `set-startup` cannot undo the Oolio autostart.
- **`stop-sql` now handles a default SQL instance.** A `SQL_Server` registry value without `HOST\INSTANCE` format (e.g. `localhost`, `.`, the machine name) previously skipped; it now maps to the `MSSQLSERVER` service when the host is local, and still skips genuinely remote hosts.
- **`switch-dhcp` clears the stale static default route** (which otherwise survives the flip and the reboot), renews the lease so the printed configuration shows the DHCP address, and isolates per-adapter failures so one bad NIC doesn't abort the rest.
- **`Set-RegistryForAllUsers` actually covers new profiles now.** It wrote to `HKLM\.DEFAULT` — a key that does not exist — while logging OK; the real template is `C:\Users\Default\NTUSER.DAT`, which is now loaded like any other offline profile hive. Hive unload also gained a retry loop with GC pressure and loud failure reporting: a silently failed unload leaves the user's NTUSER.DAT locked so they cannot sign in.
- **Step streaming can no longer deadlock on stderr.** Stdout was drained to EOF before stderr was read — the classic .NET pipe deadlock once a child writes more than the pipe buffer to stderr. Stderr now drains concurrently from process start.
- `usb-power` reports "N updates FAILED" as an error instead of claiming everything was already disabled when its per-device writes throw.
- `build-release.ps1`'s git context probes no longer abort under `$ErrorActionPreference='Stop'` on Windows PowerShell 5.1 (redirected native stderr becomes throwing ErrorRecords there).

### Security
- `POST /progress` enforces a 256 KB size cap and validates shape (known top-level keys, status values from the enum) before persisting - junk written there previously poisoned every later session.
- The `PendingSecrets` stash's single-use contract is implemented again (consume + remove into child env vars, generically for any step), instead of existing only in a stale comment.

### Fixed (earlier in this release)
- **`clean-desktop` could delete non-Bepoz shortcuts.** The name pattern matched `paz` as an unanchored substring, which also matched "Topaz Signature Pad", "Pazzo Pizza", "La Paz" — real venue shortcuts. All alternatives are now word-bounded and `paz` is anchored to the start of the name; the target pattern no longer matches paths like `C:\BepozArchive\`. `tests/patterns.tests.ps1` extracts the live patterns from `windows.ps1` and asserts an explicit must-delete / must-keep contract, and runs in CI before every release.

### Security
- **`/run` values are whitelist-validated, not merely quoted.** `Quote-PSLiteral` escapes single quotes, but the child command is wrapped in double quotes on the `powershell.exe` command line, so an embedded `"` in a step value could break out of the literal and execute as elevated PowerShell. Each step now declares the exact shape its value accepts (`active-hours`: `^\d{1,2}$`); anything else is rejected before the command string is built.
- **Host-header check on every request** blocks DNS rebinding — the one route by which a web page could bypass same-origin protections, read the CSRF token off `GET /`, and drive the elevated `/run` endpoint. Anything that is not literally `localhost` / `127.0.0.1` / `[::1]` gets a 403 before any route logic runs.

### Removed
- **`check-join`** (detect domain / Azure AD join state), **`locale-time`** (locale + NTP), **`verify-autologon`**, **`rename-device`**, **`check-chrome`** (Chrome install), and **`printer-utilities`** (links-only) steps, with their functions, router entries, progress defaults, and UI definitions.
- Autologon is no longer configured by the toolkit — it is expected on the device image. The `set-startup` step still reports its state read-only, so a terminal that would stop at the login screen is caught before go-live. The credential plumbing (`POST /input` stash, per-child env vars, CSRF) is deliberately left intact with an empty `SECRET_STEPS` map so any future secret-bearing step cannot regress to query parameters.
- Google Chrome is assumed present on the device image. The shortcut steps still detect it and give an actionable error if missing.
- `printer-utilities` is superseded by the new EpsonNet Config step.

### Added
- **Automated releases.** Pushing a `v*` tag now builds `OolioMigration.zip` and publishes the GitHub release (`.github/workflows/release.yml`). The workflow refuses to ship if the tag does not match `TOOLKIT_VERSION` in `ui/app.js`, and runs the pattern safety tests first. This closes the recurring gap where `main` ran ahead of the last published release for weeks.
- `tests/patterns.tests.ps1` — see Fixed above.

- **`default-browser`** — enforces Microsoft Edge for `http`, `https`, `.htm`, `.html`, `.pdf` via the `DefaultAssociationsConfiguration` policy, which applies to every user at sign-in. Redirects Internet Explorer launches into Edge and disables the IE11 optional feature. The per-user `UserChoice` key is hash-protected and cannot be written directly, so policy is the only supported route; it takes effect at the next sign-in.
- **`usb-power`** — disables USB selective suspend in the active power plan and clears "allow the computer to turn off this device to save power" on every present USB and COM device via `MSPower_DeviceEnable`. The usual cause of printers, cash drawers, and scanners dropping off mid-shift. Complements `power-plan`, which covers standby/monitor/disk/hibernate but not USB.
- **`check-epsonnet-config`** — downloads ENCU from `ftp.epson.com`, verifies the Epson Authenticode signature, then launches the wizard for manual click-through while polling for completion. The installer is a WinZip SFX around InstallShield: neither layer honours `/S` or `/SILENT`, and InstallShield ignores synthetic `BM_CLICK` messages, so automation was tried and abandoned.
- Favicon icons on the POS / CDS / KDS shortcuts, fetched from each site into `C:\Oolio\Assets\`, with a graceful fall back to the Chrome default icon.

- `bootstrap.ps1` gains a source selector. `$env:OOLIO_SOURCE='main'` pulls the current `main` branch archive instead of the latest release asset, so a terminal can be provisioned with unreleased code without waiting for a release to be cut. An env var is used rather than a parameter because `| iex` cannot pass arguments; `-Source main` works when the file is run directly. The `main` path strips everything `build-release.ps1` excludes, so both sources produce an identical layout on the terminal.
- The wrapper-folder lift now detects the wrapping directory by looking for `Launch.ps1` inside it, handling both the release zip's `OolioMigration\` and a branch archive's `oolio-migration-toolkit-main\`.

### Changed
- Session logs in `C:\Oolio\Logs` are rotated at server start; the newest 20 are kept.
- `bootstrap.ps1` enables TLS 1.3 where available (falls back to 1.2), matching `shared.ps1`.

- **`enable-firewall`** also sets every active network to the Private profile (domain-authenticated networks are left alone — Windows owns that classification) and enables File and Printer Sharing plus Network Discovery **scoped to Private only**, so nothing is opened up on a Public network. Starts the Function Discovery services so shared printers are actually reachable.
- **`clean-desktop`** no longer wipes both desktops. It now removes only Bepoz shortcuts, across both desktops, the Start menu (recursive, including empty Bepoz folders), and taskbar pins — matching on shortcut name *and* on target path so renamed shortcuts are still caught. Explorer is restarted only if a pin was removed. Now runs for `T` and `KDS` as well as `ST`.
- POS and CDS shortcuts moved from `--kiosk` to `--app=<url> --start-fullscreen`, matching KDS. Kiosk mode leaves no way out on a touchscreen terminal with no physical keyboard; app mode is equally chrome-free but exits with the Windows key or Alt+F4. All three also pass `--disable-pinch`.
- TeamViewer install polls up to 3 minutes for `TeamViewer.exe` instead of checking once immediately after the installer exits. The `/S` installer hands off to a background service installer and exits early, which was reporting false failures on successful installs.

- **The Oolio POS native installer is no longer committed to git or bundled in the release zip.** `installers/POS-prod-green-7.9.2-*.exe` was 35.1 MB — 99% of a 34.99 MB release asset — and only Windows-app deployments ever needed it. The release zip is now **~0.13 MB**. `installers/*.exe` is gitignored so it cannot be re-committed by accident.
- `installers/` still ships as a folder with its README, so the drop path exists on the terminal. Technicians running a Windows-app deployment copy the current `POS-*-installer.exe` in before running that step; Chrome deployments need nothing.
- `install-pos-app` now creates `installers/` if absent and, when no `.exe` is present, prints numbered instructions (where to get the build, where to put it, and that Chrome deployments can skip the step) instead of a bare "folder not found" error.
- `build-release.ps1`: `-SkipInstallers` replaced by `-IncludeInstallers` (off by default). Any `.exe` in `installers/` is stripped from the staged copy unless the switch is given, so a developer's local installer can never leak into a public release asset. `-IncludeInstallers` with no `.exe` present is a build error, not a silent no-op.

### Note
Removing the file from the working tree does not shrink existing clones — the 35.1 MB blob remains in git history and is still transferred on `git clone`. Purging it requires a history rewrite (`git filter-repo`) and a force-push, which invalidates every existing clone.

## v1.5.1 — 2026-07-08

### Security
- Autologon credentials no longer travel in the `/run` URL (EventSource is GET-only, and URLs persist in browser history on the terminal). The UI now stashes them via a CSRF-protected `POST /input`; the server holds them in memory, hands them to the step as environment variables (unchanged), and clears the stash after one use. Query-param fallback retained for backward compatibility.

### Hardened
- **Boot validator now parses every module script** (PowerShell AST) — a syntax error surfaces at server start instead of mid-migration when a tech runs the step.
- **Boot validator now cross-checks app.js against the router** — a UI step with no router mapping (the last remaining drift gap) is reported at start instead of 404ing at click time.
- **`GET /health` endpoint + UI banner** — validator results were previously buried in the server console; the home view now shows a red integrity banner listing any issues, with advice to re-extract the release zip.
- **`zip-data` nested-BackupPath guard** — if `BackupPath` sits inside `DataPath`, the zip is built in `%TEMP%` and moved into place, instead of `CreateFromDirectory` failing on its own half-written archive.
- `Invoke-StepStreaming` initialises its lock variables before the `try` block so the `finally` cleanup can never reference undefined state.
- Corrected a stale comment about env-var credential lifetime in `server.ps1`.

### Changed
- Favicon (inline data-URI, Oolio purple) — kills the `/favicon.ico` 404 noise in every session log.
- README gains a screenshots section; OVERVIEW updated for KDS in the type table, module 3/4 applicability, and honest zip-size numbers (~35 MB with the bundled installer).
- **Feedback email display** in the app header on every view (migrate, module, type-selection) shows `stephen.shaw@oolio.com` in plain text. POS terminals won't have mail clients, so technicians can note and email the address manually from their own device.

## v1.5 — 2026-07-08

### Added — native Oolio POS app deployment (Module 4)
- Deployment mode **Windows app (native installer)** is now selectable in the deployment-config form and is the new default; the native app replaces the Chrome kiosk for POS.
- `install-pos-app` step / `Invoke-OolioInstallPOSApp`: runs the bundled `installers\POS-*-installer.exe` silently (electron-builder NSIS, `/S`, per-machine to Program Files), verifies the Authenticode signature (advisory for a locally-supplied file), detects the installed executable from the uninstall registry, and drops an `Oolio POS.lnk` on the Public desktop.
- Reuses the existing `set-startup` step unchanged — because the native step names its shortcut `Oolio POS.lnk` (same as the Chrome path), shell:startup autostart works with no branching.
- `Get-OolioPosExePath` helper: resolves the installed exe via `DisplayIcon`, falling back to the largest non-uninstaller exe under `InstallLocation`.
- `install-cds-chrome` now shows whenever a CDS is present, independent of POS deployment mode (the CDS is always a Chrome kiosk page). Needs Chrome installed.
- The native step is passed `-toolkitRoot` by the server so it can locate the `installers\` folder.

### Added — disable multi-touch (Module 2)
- `disable-multitouch` step / `Invoke-WindowsDisableMultitouch`: keeps single-finger tap but turns off pinch-zoom and two/three/four-finger gestures (`Control Panel\Desktop\TouchGestureSetting=0`), touch press-and-hold right-click (`Wisp\Touch\TouchMode_hold=0`), pen press-and-hold right-click (`Wisp\Pen\SysEventParameters\HoldMode=3`), the legacy multi-touch/inking toggle (`Wisp\MultiTouch\MultiTouchEnabled=0`), and edge swipes (`EdgeUI\AllowEdgeSwipe=0`). Idempotent.
- Per-user keys are applied via `Set-RegistryForAllUsers` — every local profile plus the default-profile template — so the autologon POS user is covered even when the toolkit runs under a different admin account. (First real consumer of the v1.4 helper.)
- Output notes are explicit that gesture suppression is driver-dependent and that true hardware single-touch is enforced by the digitiser driver, not Windows.

### Fixed
- `Get-DefaultProgress` was missing `switch-dhcp`, `teamviewer`, and `install-kds-chrome` — the boot-time step-manifest validator warned about them on every server start.
- The Bepoz "Run safe steps" chain skipped `clear-startup` / `check-run-key` on KDS terminals even though both steps are shown for KDS.
- The dependencies "Check dependencies" chain ran the hidden WebView2 step on KDS terminals and never included TeamViewer. It now runs exactly the steps visible for the selected terminal type.

### Changed
- Toolkit version (`v1.5`) now shows in the app header on every view.
- `installers/README.txt` added (drop-folder convention, matching `assets/`).
- README refreshed: folder structure now includes `installers\` and `tools\`, notes the 8081–8084 port fallback, and points to `OVERVIEW.md`/`CHANGELOG.md` as current docs (`claude.md` is marked as the historical v1 spec).

## v1.4 — 2026-06-29

### Added — KDS terminal type
- New `KDS` terminal type alongside Server / Server Till / Till. Targets a kitchen display screen.
- KDS journey: Bepoz cleanup (no SQL / data backup), full Windows hardening, Chrome + TeamViewer dependencies (no WebView2 / printer utilities), then create-folders → KDS shortcut → startup → final restart. No deployment-config form and no CDS step.
- `install-kds-chrome` step / `Invoke-OolioInstallKDSChrome`: creates `Oolio KDS.lnk` on the public desktop launching `kds.oolio.io` as a fullscreen Chrome **app** window (`--app=https://kds.oolio.io --start-fullscreen`). Differs from POS/CDS, which use `--kiosk`.
- `set-startup` now also copies `Oolio KDS.lnk` into shell:startup.

### Added — touch POS hardening (Module 2)
- `touch-pos` step: enables touch-keyboard auto-popup in desktop mode, disables edge swipes / charms / hot corners, forces desktop mode (no tablet mode), suppresses Sticky/Filter/Toggle Keys prompts, disables USB autoplay/autorun.
- `power-plan` step: sets sleep / monitor / hibernate / disk-spindown to 0 on AC and DC, disables hibernation entirely, turns off Fast Startup, sets lid-close action to do nothing.
- `disable-distractions` step: disables toast notifications, Notification Center, Xbox Game Bar, Game DVR, Windows Copilot, Storage Sense, plus hides taskbar Search box / Task View / Widgets.
- `locale-time` step (with timezone input): sets Windows time zone via `tzutil`, points `w32time` at `au.pool.ntp.org` with fallbacks, forces NTP resync, sets system locale / user language / culture to `en-AU`.
- `check-join` step: detects standalone / AD-joined / Azure AD-joined / hybrid state and warns when subsequent hardening may be reverted by Group Policy or Intune.

### Added — robustness & security
- Atomic `progress.json` writes (write `.tmp` then `Move-Item -Force`) so a crash mid-write can never leave the file half-written.
- Per-session CSRF token, injected into `index.html` as a meta tag and required on `POST /progress` and `GET /run`. Mitigates same-browser cross-origin abuse of the localhost server.
- Per-step locking — a second concurrent run of the same step (e.g. two browser tabs) is now refused with a clear error.
- Step manifest validator at startup: the server confirms every router entry points to a function that actually exists in the matching module, and that `Get-DefaultProgress` covers every routed step. UI ↔ router ↔ module drift now fails loudly at boot.
- SSE client-disconnect detection: closing the browser tab now kills the running child PowerShell process so a closed-tab session can't keep mutating the terminal.
- `verify-autologon` credentials are passed to the child process via environment variables instead of command-line arguments. Passwords no longer appear in Process Explorer / Sysmon / ETW logs.
- Download retry wrapper: Chrome, WebView2, and TeamViewer downloads now retry up to 3 times with exponential backoff (2s, 4s, 8s).
- `tzutil` errors now surface the underlying message (e.g. "The time zone X was not found.") rather than a bare exit code.

### Added — UX
- Output log toolbar: line count, error count, **Copy** button (clipboard fallback for older browsers), and **Errors only** toggle on every step's output panel.
- **Retry** button: appears when a step is in `error` state. Clears the log and re-runs in one click.
- Danger-step "What will change" preview: a short bulleted list of the concrete changes that will be made, shown above the confirmation tick. Wired for `delete-registry`, `consolidate-backups`, and `final-restart`.
- CDS Chrome shortcut now detects the actual primary display width via WinForms (`Screen.PrimaryScreen.Bounds`) and offsets the kiosk window accordingly, instead of hardcoding `--window-position=1920,0`.

### Added — shared helpers
- `Set-RegistryForAllUsers` — writes a registry value into every local user's HKCU hive plus the `.DEFAULT` template. Loads `NTUSER.DAT` for not-currently-logged-in users and reliably unloads.
- `Invoke-DownloadWithRetry` — wraps the existing heartbeat downloader with retry / backoff.
- `Get-InstalledProgram` — finds installed programs by registry scan (HKLM and HKCU Uninstall keys). Replaces `Win32_Product`, which triggers an MSI reconfigure on every installed package.

## v1.3 — 2026-05-25

### Added
- Live progress bars above the output panel for long-running steps (Chrome / WebView2 / TeamViewer downloads, msiexec installs, zip-data compression).
- `active-hours` step: locks Windows Update active hours via Group Policy and clears `NoAutoRebootWithLoggedOnUsers` so the autologon user doesn't block scheduled reboots.
- `harden-pos` step: disables OneDrive sync prompts, Windows Spotlight, Cortana, news/widgets, Edge first-run, Microsoft Account sign-in nag, and other consumer-friendly prompts.

### Changed
- Migrate flow now honours **Skip** when an auto-run step errors out, instead of pausing the entire flow.
- Empty or missing Bepoz data folder is treated as zip-data success (legitimate state on a fresh till or after a partial cleanup).

### Fixed
- Launch.ps1 now probes ports with `HttpListener` (matching what `server.ps1` actually uses) rather than `TcpListener`, which missed `http.sys` URL ACL conflicts.
- Clean exit when `HttpListener.Start` fails — was previously silent.

## v1.2 — 2026-05-15

### Added
- SSE output appended incrementally instead of full re-render — preserves input focus and scroll position in the rename-device field.
- Per-session log file at `C:\Oolio\Logs\session-<timestamp>.log` (every step's output teed into a single file for support tickets).
- Reset of stale `running` statuses at startup (e.g. when the toolkit was killed mid-step).
- Authenticode signature verification helper. WebView2 / Chrome / TeamViewer installers are rejected if the signature is not valid and the signer subject doesn't match the expected publisher.
- Auto-install path for Chrome (Google enterprise MSI), WebView2 (Microsoft Evergreen Bootstrapper), and TeamViewer (full installer).
- TLS 1.3 enabled on the download path.

### Changed
- `read-registry` step is now informational only — never an error even when keys are missing.

## v1.1 — 2026-05-08

### Added
- "All modules (manual)" fallback option to the terminal-type selector.
- Guided **Migrate** flow that walks every visible step in order with module quick-jump fallback.
- Round 2 of behaviours: autologon enable, Chrome silent install, shell:startup shortcut copy.
- `bootstrap.ps1` + ScreenConnect one-liner install instructions in the README.

### Changed
- Match Bepoz processes by executable path (`C:\Bepoz\...`) instead of by name, so unrelated processes named "bepoz*" elsewhere aren't terminated.
- Terminal-type model split into S / ST / T (server-only, server-till, till-only) — most steps now showInTypes-gated to the right device class.
- Bepoz cleanup replaced uninstall with folder consolidation: move every backup zip to `C:\OolioBackup\`, then recursively remove `C:\Bepoz\`. Aborts (no deletion) if no `Bepoz_Data_*.zip` lands in the destination.

### Fixed
- Compress-Archive replaced with `[System.IO.Compression.ZipFile]::CreateFromDirectory` to handle archives >2 GB.

## v1.0 — 2026-05-01

### Added
- Initial build. Four modules (Bepoz, Windows, Dependencies, Oolio), HTTP listener on localhost:8080, SSE-streamed step output, persistent `progress.json`.
- Wallpaper application, device rename (Oolio-<suffix>), DHCP switch, firewall enable, autologon verification.
- Chrome / WebView2 detection (download links only), printer utility link list, Epson certificate loop.
- Oolio folder structure, POS / CDS Chrome kiosk shortcuts, HKCU Run-key startup, final scheduled restart.
