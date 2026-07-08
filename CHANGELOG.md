# Changelog

All notable changes to the Oolio Migration Toolkit. Newest first.

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
