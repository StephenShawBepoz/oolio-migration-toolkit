Drop the Oolio POS native Windows installer in this folder (POS-*-installer.exe).

The installer is NOT shipped with the toolkit and is NOT committed to git - it is
~35 MB, which is 99% of the download, and only Windows-app deployments need it.
installers/*.exe is gitignored so it cannot be committed by accident.

Where to get it:
  Ask the Oolio Platform team for the current POS build, or copy it from another
  terminal at C:\OolioMigration\installers\.

How it is used:
  Module 4's "Install Oolio POS (native Windows app)" step runs the newest
  matching installer silently (/S, per-machine) and creates the startup shortcut.
  If more than one installer is present, the most recently modified one is used.
  The step only appears when deployment mode is "windows" - Chrome deployments
  do not need this file at all.

Building a release that bundles it:
  ./build-release.ps1 -IncludeInstallers
