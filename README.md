# Oolio Migration Toolkit

A locally-hosted web toolkit that guides a technician through migrating a Windows POS terminal from Bepoz to the Oolio Platform.

## Usage

1. Copy this folder to the Windows POS terminal.
2. Drop `wallpaper.jpg` into `assets\` and any Epson `.cer` files into `certs\`.
3. Right-click `Launch.ps1` and choose **Run as Administrator**.
4. The browser opens to `http://localhost:8080` with the technician UI.

Works on Windows 10 and Windows 11. No internet connection required after copy. No installation required.

## Folder structure

```
OolioMigration\
  Launch.ps1            entry point
  progress.json         auto-created, persists state
  server\               HTTP listener + router
  ui\                   single-page web app
  scripts\              module + shared PowerShell logic
  assets\               wallpaper.jpg drops here
  certs\                Epson .cer files drop here
```

See `claude.md` for the full specification.
