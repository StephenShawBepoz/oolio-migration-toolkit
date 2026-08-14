# Oolio Migration Toolkit

A locally-hosted web toolkit that guides a technician through migrating a Windows POS terminal from Bepoz to the Oolio Platform.

## Usage

### Option A — Remote (ScreenConnect / elevated PowerShell)

Paste one of these into an **elevated** ScreenConnect command (or any admin PowerShell on the terminal). It downloads the toolkit to `C:\OolioMigration\` and launches it.

**Stable — latest published release:**

```powershell
iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex
```

**Latest code — straight from `main`, no release needed:**

```powershell
$env:OOLIO_SOURCE='main'; iwr https://raw.githubusercontent.com/StephenShawBepoz/oolio-migration-toolkit/main/bootstrap.ps1 -UseBasicParsing | iex
```

Use the second when `main` is ahead of the last release. Both produce an identical layout on the terminal. The env var is used rather than a parameter because `| iex` cannot pass arguments.

> The URL always points at `main` — that is the *branch ref* for `bootstrap.ps1` itself, so the bootstrapper is always current. Which **toolkit** you get is decided inside it: the release asset, or the `main` archive. Note `raw.githubusercontent.com` caches for ~5 minutes, so a just-pushed change to `bootstrap.ps1` can take that long to appear.

### Option B — Manual (USB stick or pre-staged copy)

1. Download the latest release zip from the [Releases page](https://github.com/StephenShawBepoz/oolio-migration-toolkit/releases/latest).
2. Extract `OolioMigration\` to the terminal (e.g. `C:\OolioMigration\`).
3. (Optional) Replace `assets\wallpaper.jpg` with a different image if needed.
4. Right-click `Launch.ps1` and choose **Run as Administrator**.
5. The browser opens to `http://localhost:8080` with the technician UI (falls back to 8081–8084 if 8080 is taken).

Works on Windows 10 and Windows 11. Google Chrome is expected to be on the device image already; WebView2, TeamViewer, and EpsonNet Config are installed at run-time if missing (needs internet at those steps). The rest of the toolkit runs fully offline once unpacked.

**Windows-app deployments only:** the Oolio POS native installer (~35 MB) is not shipped with the toolkit. Copy `POS-*-installer.exe` into `C:\OolioMigration\installers\` before running that step. Chrome deployments need nothing extra.

## Screenshots

| Select terminal type | Guided migrate flow |
|---|---|
| ![Terminal type selection](screenshots/01-select-type.png) | ![Migrate pause with input form](screenshots/06-migrate-pause-form.png) |

| Module view | Deployment options |
|---|---|
| ![Bepoz module steps](screenshots/03-module-bepoz.png) | ![Deployment configuration](screenshots/10-deployment-config.png) |

## Folder structure

```
OolioMigration\
  Launch.ps1            entry point
  progress.json         auto-created, persists state
  server\               HTTP listener + router
  ui\                   single-page web app
  scripts\              module + shared PowerShell logic
  assets\               wallpaper.jpg ships here
  installers\           drop POS-*-installer.exe here (not shipped, not in git)
```

## Releasing

Releases are automated. To ship what is on `main`:

1. Update `TOOLKIT_VERSION` in `ui/app.js` and add a dated CHANGELOG entry.
2. Tag and push:

   ```bash
   git tag v1.6 && git push origin v1.6
   ```

The `release` GitHub Actions workflow verifies the tag matches `TOOLKIT_VERSION`, runs the pattern safety tests, builds `OolioMigration.zip` with `build-release.ps1`, and publishes the release. The bootstrap one-liner serves the new version immediately — `releases/latest/download/` follows the newest published release.

`./build-release.ps1` still works locally for USB builds (`-IncludeInstallers` bundles the POS installer).

## Development

`tests/patterns.tests.ps1` guards the Bepoz shortcut-matching patterns in `clean-desktop` — the step deletes files on venue terminals, so the must-keep list in that file is the contract. Run it after touching `$strongPattern` / `$targetPattern` in `scripts/windows.ps1`. The server also AST-parses every module script at boot and cross-checks the UI against the router; `GET /health` reports the result.

See `OVERVIEW.md` for how the toolkit works and `CHANGELOG.md` for release history. (`claude.md` is the original v1 design spec, kept for reference.)
