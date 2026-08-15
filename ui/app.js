// app.js - Oolio Migration Toolkit single-page UI

// Bump alongside CHANGELOG.md on every release. Shown in the app header so a
// technician (or a support ticket screenshot) instantly identifies the build.
const TOOLKIT_VERSION = 'v1.7';

// ---------- Module + step definitions ----------

// Terminal types are now session-level. They drive which modules / steps are visible.
// S = Server (no till, no Bepoz folder cleanup)
// ST = Server Till (everything)
// T = Till (no SQL / data backup; still has the till cleanup steps)
// KDS = Kitchen Display (Bepoz cleanup, full hardening, Chrome app-mode KDS screen; no SQL / data backup / CDS)

const TERMINAL_TYPES = [
    { code: 'S',   label: 'Server',              desc: 'On-premises venue server. Runs SQL Server and holds Bepoz data. No POS interface.' },
    { code: 'ST',  label: 'Server Till',         desc: 'Acts as both venue server and POS terminal. Runs SQL Server, holds Bepoz data, and runs the till.' },
    { code: 'T',   label: 'Till',                desc: 'POS terminal only. No SQL Server. No Bepoz data stored locally. Connects to the server for data.' },
    { code: 'KDS', label: 'KDS',                 desc: 'Kitchen Display screen. No SQL, no data backup, no CDS. Wipes any old Bepoz install, hardens Windows, then runs kds.oolio.io as a fullscreen Chrome app.' },
    { code: 'ALL', label: 'All modules (manual)', desc: 'Skip the type filter. Show every module and step in the original 1 / 2 / 3 / 4 order so you can cherry-pick. Use for unusual configurations or one-off troubleshooting.' }
];

const MODULES = [
    {
        id: 'system',
        name: 'System Check',
        icon: '0',
        description: 'Check the hardware is fit for the job before touching anything.',
        showInTypes: ['S', 'ST', 'T', 'KDS'],
        steps: [
            { id: 'check-hardware', title: 'Check hardware suitability', risk: 'safe', showInTypes: ['S','ST','T','KDS'],
              note: 'Reads RAM, CPU, disk and model (no changes made) and gives a verdict. Below 4 GB RAM the unit is unsuitable - replace it. 4-7 GB is usable but sluggish; the advice is to wipe/reimage first (clears years of Windows Update backlog and bloat) and replace only if it is still slow. Run this before migrating so a doomed unit is caught in two minutes, not twenty.' }
        ]
    },
    {
        id: 'bepoz',
        name: 'Bepoz Software',
        icon: '1',
        description: 'Back up data, stop services, and remove the legacy Bepoz install.',
        showInTypes: ['S', 'ST', 'T', 'KDS'],
        steps: [
            { id: 'read-registry',       title: 'Read Bepoz registry',   risk: 'safe',   showInTypes: ['S','ST','T','KDS'], note: 'Reads SQL_Server, DataPath, BackupPath from HKCU\\Software\\Backoffice. No changes made.' },
            { id: 'terminate-processes', title: 'Terminate processes from C:\\Bepoz', risk: 'safe', showInTypes: ['S','ST','T','KDS'], note: 'Walks every running process and force-stops any whose executable lives under C:\\Bepoz (matches by path, not by process name).' },
            { id: 'stop-sql',            title: 'Stop and disable SQL Server', risk: 'warn', showInTypes: ['S','ST'], note: 'Stops and disables the local MSSQL$<instance> service if present. Server and server-till only.' },
            { id: 'zip-data',            title: 'Zip Bepoz data',        risk: 'safe',   showInTypes: ['S','ST'], note: 'Compresses the DataPath folder into the BackupPath using .NET ZipFile (no 2 GB limit). Server and server-till only.' },
            { id: 'clear-startup',       title: 'Clear shell:startup',   risk: 'warn',   showInTypes: ['ST','T','KDS'], note: 'Removes everything from the user shell:startup folder. Till, server-till and KDS only.' },
            { id: 'check-run-key',       title: 'Export & clean HKCU Run key', risk: 'warn', showInTypes: ['ST','T','KDS'], note: 'Exports the full HKCU Run key to C:\\OolioBackup\\HKCU_Run_<timestamp>.reg, then removes known Bepoz Run entries. Restore with reg import if needed.' },
            { id: 'delete-registry',     title: 'Delete Bepoz registry', risk: 'danger', showInTypes: ['ST','T','KDS'], note: 'Removes HKCU\\Software\\Backoffice. Make sure the data backup is complete first.',
              preview: ['Deletes registry key HKCU\\Software\\Backoffice and every value/subkey beneath it.', 'Does not touch HKLM autologon, HKCU Run, or any non-Bepoz key.'] },
            { id: 'consolidate-backups', title: 'Consolidate backups & remove Bepoz folder', risk: 'danger', showInTypes: ['ST','T','KDS'],
              note: 'Moves all .zip files from C:\\Bepoz\\Backup\\ (recursive) to C:\\OolioBackup\\, then removes C:\\Bepoz\\ and all its contents. Aborts if no Bepoz_Data_*.zip ends up in the destination.',
              preview: ['Moves every *.zip under C:\\Bepoz\\Backup\\ into C:\\OolioBackup\\.', 'Then recursively deletes C:\\Bepoz\\ and everything in it.', 'Aborts (no deletion) if no Bepoz_Data_*.zip lands in the destination.'] }
        ]
    },
    {
        id: 'windows',
        name: 'Windows Settings',
        icon: '2',
        description: 'Verify autologon, firewall, network, then rename / clean the device.',
        showInTypes: ['S', 'ST', 'T', 'KDS'],
        steps: [
            { id: 'enable-firewall',  title: 'Firewall, Private network & sharing', risk: 'warn', showInTypes: ['S','ST','T','KDS'],
              note: 'Turns the firewall on for Domain, Private, and Public profiles. Sets every active network to the Private profile (domain-authenticated networks are left alone - Windows owns that classification). Enables File and Printer Sharing plus Network Discovery on the Private profile only, and starts the Function Discovery services so shared printers are reachable.' },
            { id: 'default-browser',  title: 'Set Microsoft Edge as default browser', risk: 'warn', showInTypes: ['S','ST','T','KDS'],
              note: 'Enforces Edge as the default for http, https, .htm, .html and .pdf via the DefaultAssociationsConfiguration policy, which applies to every user at sign-in. Also redirects any Internet Explorer launch into Edge and disables the IE11 optional feature. Takes effect at the next sign-in.' },
            { id: 'usb-power',        title: 'Disable USB / serial port power saving', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Stops Windows powering down USB and serial/COM devices to save energy - the usual cause of printers, cash drawers, and scanners "dropping off" during a shift. Disables USB selective suspend in the active power plan and clears the "allow the computer to turn off this device" checkbox on every present USB and COM device. Complements the power plan step, which covers standby and monitor timeouts but not USB. Re-run after adding new peripherals.' },
            { id: 'active-hours',     title: 'Configure Windows Update active hours', risk: 'warn', showInTypes: ['S','ST','T','KDS'],
              requiresInputs: [{ name: 'value', label: 'Update window hour (24h, 0-23)', placeholder: '3' }],
              note: 'Locks Windows Update active hours via Group Policy. Updates only install in a 6-hour window centred on the supplied hour. Recommended: 3 (3am). Also clears NoAutoRebootWithLoggedOnUsers so the autologon user does not block reboots.' },
            { id: 'harden-pos',       title: 'Disable Windows nags / OneDrive / Spotlight', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Turns off OneDrive sync prompts, Windows Spotlight, Cortana, news/widgets, Edge first-run, Microsoft Account sign-in nag, and other consumer-friendly prompts that get in the way on a POS. Idempotent - safe to re-run.' },
            { id: 'touch-pos',        title: 'Harden touch input (keyboard / swipes / autoplay)', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Enables touch keyboard auto-popup in desktop mode, disables edge swipes and hot corners, forces desktop mode (no tablet mode), suppresses Sticky/Filter/Toggle Keys prompts, and disables USB autoplay/autorun. Idempotent.' },
            { id: 'disable-multitouch', title: 'Disable multi-touch gestures (pinch-zoom / press-and-hold)', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Keeps single-finger tap but turns off pinch-zoom, two/three/four-finger swipes, touch and pen press-and-hold right-click, and edge swipes so accidental multi-touch does not misfire the POS. Applied to every local user profile (plus the default-profile template), so the autologon POS user is covered regardless of which account runs the toolkit. True single-touch is ultimately a digitiser-driver setting - see the output notes. Idempotent.' },
            { id: 'power-plan',       title: 'Power plan (never sleep, hibernate off)', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Sets sleep, monitor, hibernate, and disk-spindown timeouts to 0 on AC and DC, disables hibernation entirely (reclaims hiberfil.sys), turns off Fast Startup so reboots are real reboots, and sets lid-close action to do nothing.' },
            { id: 'disable-distractions', title: 'Disable notifications, Game Bar, Copilot, Storage Sense', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Disables toast notifications and Notification Center, Xbox Game Bar / Game DVR, Windows Copilot, Storage Sense (so backup zips aren\'t auto-deleted), the Search box, Task View button, and Widgets icon on the taskbar. Idempotent.' },
            { id: 'check-ip',         title: 'Check IP configuration', risk: 'safe', showInTypes: ['S','ST','T','KDS'], note: 'Shows current IP and DHCP status for every active adapter. If a static IP is detected, the migrate flow surfaces a "Switch to DHCP" prompt as an inline action.' },
            { id: 'clean-desktop',    title: 'Remove Bepoz apps from desktop, taskbar & Start', risk: 'warn', showInTypes: ['ST','T','KDS'],
              note: 'Removes Bepoz shortcuts from both desktops, the Start menu (recursive, including empty Bepoz folders), and taskbar pins. Matches on shortcut name and on where the shortcut points, so renamed shortcuts are still caught. Non-Bepoz shortcuts are left untouched. Restarts Explorer if any taskbar pin was removed.' },
            { id: 'set-wallpaper',    title: 'Apply Oolio wallpaper', risk: 'safe', showInTypes: ['ST','KDS'], note: 'Copies assets/wallpaper.jpg to C:\\Oolio\\Assets and applies it. Server-till and KDS only.' }
        ]
    },
    {
        id: 'dependencies',
        name: 'Oolio Dependencies',
        icon: '3',
        description: 'Verify or install Chrome and WebView2, plus printer utility links.',
        showInTypes: ['ST', 'KDS'],
        steps: [
            { id: 'check-webview2',    title: 'Check / install Edge WebView2', risk: 'safe', showInTypes: ['ST'], note: 'Required for Windows native Oolio POS and CDS apps. If missing, downloads the Microsoft Evergreen Bootstrapper and installs silently (/silent /install). Requires internet at this step.' },
            { id: 'check-epsonnet-config', title: 'Check / install EpsonNet Config', risk: 'safe', showInTypes: ['ST'],
              note: 'Network configuration utility for Epson printers. Detects an existing install via known paths and the uninstall registry. If missing, downloads ENCU from ftp.epson.com and verifies the Epson signature, then launches the wizard - the installer is a WinZip SFX around InstallShield and cannot be silenced, so the technician clicks through while the toolkit polls for completion. Requires internet.' },
            { id: 'teamviewer',        title: 'Check / install TeamViewer', risk: 'safe', showInTypes: ['ST','KDS'], note: 'Reports TeamViewer install path and version. If missing, downloads the full TeamViewer installer (TeamViewer_Setup_x64.exe) and installs silently with /S. Requires internet at this step.' },
        ]
    },
    {
        id: 'oolio',
        name: 'Oolio POS Setup',
        icon: '4',
        description: 'Set deployment options, create folders and shortcuts, schedule the final restart.',
        showInTypes: ['ST', 'KDS'],
        steps: [
            { id: 'deployment-config',  title: 'Deployment options',         risk: 'safe', configStep: true, showInTypes: ['ST'], note: 'Choose deployment mode - the native Windows app (installer copied into the toolkit installers\\ folder on the terminal; not bundled) or the Chrome fullscreen shortcut - and whether a CDS is present.' },
            { id: 'create-folders',     title: 'Create Oolio folders',       risk: 'safe', showInTypes: ['ST','KDS'], note: 'Creates C:\\Oolio and Assets/Certs/Logs subfolders.' },
            { id: 'install-pos-app',    title: 'Install Oolio POS (native Windows app)', risk: 'safe', showInTypes: ['ST'], note: 'Runs installers\\POS-*-installer.exe silently (electron-builder NSIS, /S, per-machine to Program Files), detects the installed executable, and drops an "Oolio POS" shortcut on the Public desktop for the startup step to pick up. This native app replaces the Chrome fullscreen shortcut. The installer is NOT bundled with the toolkit (~35 MB) - copy POS-*-installer.exe into the toolkit installers\\ folder on this terminal before running this step.', showWhen: m => (m.deploymentMode || 'windows') === 'windows' },
            { id: 'install-pos-chrome', title: 'Create Oolio POS shortcut (Chrome fullscreen)', risk: 'safe', showInTypes: ['ST'], note: 'Public-desktop shortcut launching pos.oolio.io in Chrome app mode - fullscreen, no browser UI, pinch-zoom disabled, with the site favicon as its icon. Exits with the Windows key or Alt+F4, unlike kiosk mode.', showWhen: m => m.deploymentMode === 'chrome' },
            { id: 'install-cds-chrome', title: 'Create Oolio CDS shortcut (Chrome fullscreen)', risk: 'safe', showInTypes: ['ST'], note: 'Public-desktop shortcut launching cds.oolio.io in Chrome app mode on the second display, with the site favicon as its icon.', showWhen: m => m.hasCDS === true },
            { id: 'install-kds-chrome', title: 'Create Oolio KDS shortcut (Chrome fullscreen)', risk: 'safe', showInTypes: ['KDS'], note: 'Public-desktop shortcut "Oolio KDS" launching kds.oolio.io as a fullscreen Chrome app window (--app + --start-fullscreen).' },
            { id: 'set-startup',        title: 'Configure startup',          risk: 'warn', showInTypes: ['ST','KDS'], note: 'Copies the Oolio desktop shortcut(s) into shell:startup so Oolio launches when the autologon user signs in. Also tidies up legacy HKCU Run entries from older toolkit builds.' },
            { id: 'final-restart',      title: 'Schedule final restart',     risk: 'danger', showInTypes: ['ST','KDS'], note: 'Schedules a 30-second restart so the device rename, wallpaper, and autologon changes take effect. Run "shutdown /a" from a command prompt to cancel.',
              preview: ['Runs: shutdown /r /t 30. The terminal restarts in 30 seconds.', 'No data is destroyed - this only reboots so device-rename, wallpaper, and autologon take effect.', 'Cancel with: shutdown /a (from any command prompt within 30 seconds).'] }
        ]
    }
];

// ---------- State ----------

let state = {
    view: 'home',
    activeModule: null,
    progress: {},
    expandedSteps: {},
    runningStep: null,
    outputLog: {},
    outputFilter: {},
    inputValues: {},
    confirmTicked: {},
    healthIssues: [],
    // Latest progress event per step. Updated 1x/sec while a download or install
    // is running; cleared via { done: true } when the operation finishes.
    progressBars: {},
    migrate: {
        active: false,
        aborted: false,
        currentAction: null,   // { type, moduleId, stepId, stepDef, moduleDef }
        errorState: false,
        done: false,
        // Promise resolver/rejecter set up while waiting for user action at a pause.
        resolve: null,
        reject: null
    }
};

// ---------- Boot ----------

window.addEventListener('DOMContentLoaded', async () => {
    try {
        const resp = await fetch('/progress');
        state.progress = await resp.json();
        if (!state.progress.meta) state.progress.meta = {};
    } catch (e) {
        state.progress = { meta: {} };
    }
    // Boot-time integrity check: the server validates router <-> module <->
    // defaults <-> UI consistency and parses every module script at startup.
    // Surface any issues as a banner instead of leaving them buried in the
    // server console the technician never sees.
    try {
        const h = await fetch('/health');
        const hj = await h.json();
        state.healthIssues = (hj && hj.issues) || [];
    } catch (e) {
        state.healthIssues = [];
    }
    if (!state.progress.meta.terminalType) state.view = 'select-type';
    render();
});

// ---------- Helpers ----------

// Per-session CSRF token. Injected into <meta name="oolio-token"> by the server.
// Required on POST /progress (header) and GET /run (query string).
function getCsrfToken() {
    const m = document.querySelector('meta[name="oolio-token"]');
    return (m && m.getAttribute('content')) || '';
}

function getMeta() { return state.progress.meta || {}; }

function getStepStatus(moduleId, stepId) {
    const m = state.progress[moduleId];
    if (!m) return 'pending';
    return m[stepId] || 'pending';
}

function getTerminalType() { return getMeta().terminalType || ''; }

function isModuleVisible(moduleDef) {
    const tt = getTerminalType();
    if (!tt) return false;
    if (tt === 'ALL') return true;
    if (!moduleDef.showInTypes) return true;
    return moduleDef.showInTypes.includes(tt);
}

function getVisibleModules() {
    return MODULES.filter(isModuleVisible);
}

function getVisibleSteps(moduleDef) {
    const meta = getMeta();
    const tt = meta.terminalType || '';
    return moduleDef.steps.filter(step => {
        if (tt !== 'ALL' && step.showInTypes && !step.showInTypes.includes(tt)) return false;
        if (step.showWhen && !step.showWhen(meta)) return false;
        return true;
    });
}

function getModuleProgress(moduleDef) {
    const visible = getVisibleSteps(moduleDef);
    const m = state.progress[moduleDef.id] || {};
    let done = 0;
    visible.forEach(s => {
        const st = m[s.id];
        if (st === 'complete' || st === 'skipped') done++;
    });
    return { done, total: visible.length };
}

function getOverallProgress() {
    let done = 0, total = 0;
    getVisibleModules().forEach(mod => {
        const p = getModuleProgress(mod);
        done += p.done; total += p.total;
    });
    return { done, total };
}

async function saveProgress() {
    state.progress.meta = state.progress.meta || {};
    state.progress.meta.lastUpdated = new Date().toISOString();
    try {
        const resp = await fetch('/progress', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Oolio-Token': getCsrfToken()
            },
            body: JSON.stringify(state.progress)
        });
        // A 403 here almost always means the server was restarted (e.g. the
        // Launch.ps1 window was closed and reopened) and this tab is holding a
        // stale CSRF token. The UI would otherwise keep flipping steps on screen
        // while nothing persists - warn loudly, once, so the technician reloads.
        if (!resp.ok && !state.staleTokenWarned) {
            state.staleTokenWarned = true;
            console.error('Progress save rejected:', resp.status);
            if (resp.status === 403) {
                alert('The toolkit server was restarted, so this page can no longer save progress. Reload the page (F5) to reconnect - your completed steps are already saved on disk.');
            }
        }
    } catch (e) {
        console.error('Failed to save progress', e);
    }
}

function setStepStatus(moduleId, stepId, status) {
    state.progress[moduleId] = state.progress[moduleId] || {};
    state.progress[moduleId][stepId] = status;
    saveProgress();
}

// ---------- Migrate flow planner ----------
//
// Walks every module's visible steps in order and classifies each pending step as:
//   - auto-run   : safe enough to run unattended in the migrate loop
//   - pause-form : needs technician input via inputs (active-hours)
//   - pause-config: terminal-type configuration form
//   - pause-manual: link-only step that needs the technician to do something off-script
//   - pause-confirm: danger step requiring a confirmation tick before running

function classifyStep(step) {
    if (step.configStep)            return 'pause-config';
    if (step.linksOnly)             return 'pause-manual';
    if (step.requiresInputs && step.requiresInputs.length > 0) return 'pause-form';
    if (step.risk === 'danger')     return 'pause-confirm';
    return 'auto-run';
}

function getNextMigrateAction() {
    for (const mod of getVisibleModules()) {
        const visible = getVisibleSteps(mod);
        for (const step of visible) {
            const status = getStepStatus(mod.id, step.id);
            if (status === 'complete' || status === 'skipped') continue;
            return {
                type: classifyStep(step),
                moduleId: mod.id,
                stepId: step.id,
                stepDef: step,
                moduleDef: mod
            };
        }
    }
    return null;
}

function getStepExtras(stepId) {
    if (stepId === 'active-hours') {
        // Default to 3 (3am) when the tech leaves the field blank.
        return { value: state.inputValues['windows.active-hours.value'] || '3' };
    }
    return {};
}

function waitForMigrateUser() {
    return new Promise((resolve, reject) => {
        state.migrate.resolve = resolve;
        state.migrate.reject = reject;
    });
}

async function startMigrate() {
    state.view = 'migrate';
    state.migrate.active = true;
    state.migrate.aborted = false;
    state.migrate.done = false;
    state.migrate.errorState = false;
    state.migrate.currentAction = null;
    render();
    runMigrateLoop();
}

function abortMigrate() {
    state.migrate.aborted = true;
    if (state.migrate.reject) {
        const r = state.migrate.reject;
        state.migrate.resolve = null;
        state.migrate.reject = null;
        r(new Error('aborted'));
    }
    state.migrate.active = false;
    render();
}

function resolveMigrateWait(skipped = false) {
    if (state.migrate.resolve) {
        const r = state.migrate.resolve;
        state.migrate.resolve = null;
        state.migrate.reject = null;
        r({ skipped });
    }
}

async function runMigrateLoop() {
    while (true) {
        if (state.migrate.aborted) return;

        const next = getNextMigrateAction();
        if (!next) {
            state.migrate.active = false;
            state.migrate.done = true;
            state.migrate.currentAction = null;
            render();
            return;
        }

        state.migrate.currentAction = next;
        state.migrate.errorState = false;
        render();

        if (next.type === 'auto-run') {
            await runStep(next.moduleId, next.stepId, getStepExtras(next.stepId));
            await new Promise(r => setTimeout(r, 350));

            const status = getStepStatus(next.moduleId, next.stepId);
            if (status === 'error') {
                state.migrate.errorState = true;
                render();
                let result;
                try {
                    result = await waitForMigrateUser();
                } catch (e) {
                    return; // aborted
                }
                state.migrate.errorState = false;
                // Honour Skip from the error popup. Without this, skipMigrateStep
                // resolved the wait but the step status stayed 'error', so the loop
                // immediately re-ran and re-errored - the Skip button looked broken.
                // retryMigrateStep flips status to 'pending' itself before resolving,
                // so its path still works the same way.
                if (result && result.skipped) {
                    setStepStatus(next.moduleId, next.stepId, 'skipped');
                }
                continue;
            }

            // Special-case: after check-ip, scan output for a static-IP detection. If found,
            // surface an inline "Switch to DHCP" pause-optional card.
            if (next.stepId === 'check-ip') {
                const log = state.outputLog['windows.check-ip'] || [];
                const hasStatic = log.some(l => /DHCP:\s*Disabled/i.test(l));
                if (hasStatic) {
                    const switchAction = {
                        type: 'pause-optional',
                        moduleId: 'windows',
                        stepId: 'switch-dhcp',
                        stepDef: { title: 'Switch to DHCP', risk: 'warn', note: 'A static-IP adapter was detected. Switching to DHCP will briefly drop the network while a new IP is acquired.' },
                        moduleDef: next.moduleDef,
                        runLabel: 'Switch to DHCP'
                    };
                    state.migrate.currentAction = switchAction;
                    render();
                    try { await waitForMigrateUser(); } catch (e) { return; }
                }
            }
            continue;
        }

        // Pause types - render the pause UI and wait for the user.
        try {
            const result = await waitForMigrateUser();
            // After the user resolves the wait, the step is either marked complete/skipped
            // by the action handler (continueMigrateStep / skipMigrateStep). The loop just
            // re-evaluates getNextMigrateAction on the next iteration.
            if (result && result.skipped) {
                setStepStatus(next.moduleId, next.stepId, 'skipped');
            }
        } catch (e) {
            return; // aborted
        }
    }
}

// Called by the "Continue" button on a pause card.
async function continueMigrateStep() {
    const next = state.migrate.currentAction;
    if (!next) return;

    if (next.type === 'pause-config') {
        // The config form's Save button has already written meta + marked the step complete.
        resolveMigrateWait();
        return;
    }
    if (next.type === 'pause-manual') {
        setStepStatus(next.moduleId, next.stepId, 'complete');
        resolveMigrateWait();
        return;
    }

    // pause-form / pause-confirm / pause-optional: run the step, then resolve.
    // If the step FAILS, surface the error card (Retry / Skip / Stop) instead of
    // resolving - otherwise the loop just re-evaluates, finds the step still not
    // complete, and silently re-presents the identical pause card with no sign
    // anything went wrong. A failed danger step (e.g. consolidate-backups) must
    // never look like it succeeded.
    const ok = await runStep(next.moduleId, next.stepId, getStepExtras(next.stepId));
    if (ok === false) {
        state.migrate.errorState = true;
        render();
        return;
    }
    resolveMigrateWait();
}

function skipMigrateStep() {
    resolveMigrateWait(true);
}

function retryMigrateStep() {
    // Clear the error and re-run the same step.
    state.migrate.errorState = false;
    setStepStatus(state.migrate.currentAction.moduleId, state.migrate.currentAction.stepId, 'pending');
    resolveMigrateWait();
}

// ---------- SSE step runner ----------

async function runStep(moduleId, stepId, extras) {
    const key = moduleId + '.' + stepId;
    state.runningStep = key;
    state.outputLog[key] = [];
    setStepStatus(moduleId, stepId, 'running');
    render();

    // Backwards compat: if a plain string is passed, treat it as the legacy "value" param.
    let params = {};
    if (typeof extras === 'string') params.value = extras;
    else if (extras && typeof extras === 'object') params = extras;

    // Secrets never travel in the /run URL - EventSource is GET-only and URLs
    // persist in browser history on the terminal. Stash them server-side via
    // POST /input first; the server hands them to the step as environment
    // variables and clears the stash after one use.
    // No step currently takes secrets - the autologon step was removed. The
    // mechanism is kept so any future secret-bearing step routes through
    // POST /input rather than regressing to query parameters.
    const SECRET_STEPS = {};
    const secretFields = SECRET_STEPS[stepId];
    if (secretFields && secretFields.some(f => params[f])) {
        const fields = {};
        secretFields.forEach(f => { fields[f] = params[f] || ''; delete params[f]; });
        try {
            await fetch('/input', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Oolio-Token': getCsrfToken() },
                body: JSON.stringify({ module: moduleId, step: stepId, fields })
            });
        } catch (e) {
            console.error('Failed to stash step inputs; running without them', e);
        }
    }

    let url = `/run?module=${encodeURIComponent(moduleId)}&step=${encodeURIComponent(stepId)}&t=${encodeURIComponent(getCsrfToken())}`;
    Object.keys(params).forEach(k => {
        if (params[k] !== undefined && params[k] !== null && params[k] !== '') {
            url += `&${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`;
        }
    });

    const es = new EventSource(url);

    return new Promise((resolve) => {
        es.onmessage = function (e) {
            if (e.data === '__DONE__') {
                es.close();
                state.runningStep = null;
                state.progressBars[key] = null;  // hide any leftover bar
                const log = state.outputLog[key] || [];
                const hasError = log.some(line => line.includes('[ERROR]') || line.startsWith('__ERROR__'));
                setStepStatus(moduleId, stepId, hasError ? 'error' : 'complete');
                render();
                resolve(!hasError);
                return;
            }
            if (e.data.startsWith('__PROGRESS__:')) {
                try {
                    const payload = JSON.parse(e.data.substring('__PROGRESS__:'.length).trim());
                    updateProgressBar(moduleId, stepId, payload);
                } catch (err) {
                    // Malformed event - drop silently
                }
                return;
            }
            // Both regular output and __ERROR__ lines append to the live log without
            // a full re-render, so input focus and scroll positions are preserved.
            appendOutputLine(moduleId, stepId, e.data);
        };
        es.onerror = function () {
            es.close();
            if (state.runningStep === key) {
                state.runningStep = null;
                setStepStatus(moduleId, stepId, 'error');
                render();
            }
            resolve(false);
        };
    });
}

// ---------- Auto-chain runners ----------

async function runBepozSafeChain() {
    // New step order: read-registry -> terminate-processes -> stop-sql -> zip-data -> pause -> clear-startup -> check-run-key
    const tt = getTerminalType();
    const ids = ['read-registry', 'terminate-processes'];
    if (tt === 'S' || tt === 'ST') { ids.push('stop-sql', 'zip-data'); }
    for (const id of ids) {
        const ok = await runStep('bepoz', id);
        if (!ok && id === 'read-registry') {
            alert('read-registry reported errors. Auto-run paused. Resolve before continuing.');
            return;
        }
    }
    if (tt === 'S' || tt === 'ST') {
        const proceed = confirm('Backup zip step is complete. Confirm the zip file exists in the backup folder before continuing.');
        if (!proceed) return;
    }
    if (tt === 'ST' || tt === 'T' || tt === 'KDS') {
        await runStep('bepoz', 'clear-startup');
        await runStep('bepoz', 'check-run-key');
    }
}

async function runDepsCheckChain() {
    // Drive off visibility so KDS terminals don't run the hidden WebView2 step
    // and TeamViewer is included for the types that show it.
    const mod = MODULES.find(m => m.id === 'dependencies');
    const runnable = getVisibleSteps(mod).filter(s => !s.linksOnly);
    for (const step of runnable) {
        await runStep('dependencies', step.id);
    }
}

// ---------- Rendering ----------

function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function renderOverallProgress() {
    const { done, total } = getOverallProgress();
    const pct = total === 0 ? 0 : Math.round((done / total) * 100);
    return `
      <div class="overall-progress">
        <div class="overall-progress-label">
          <span>Overall progress</span>
          <span>${done} of ${total} steps</span>
        </div>
        <div class="progress-track"><div class="progress-fill" style="width:${pct}%"></div></div>
      </div>`;
}

function renderSelectType(forChange = false) {
    const current = getTerminalType();
    const primaryTypes = TERMINAL_TYPES.filter(t => t.code !== 'ALL');
    const fallbackType = TERMINAL_TYPES.find(t => t.code === 'ALL');

    const primaryHtml = primaryTypes.map(t => `
      <button class="terminal-type-card${current === t.code ? ' selected' : ''}" data-type="${t.code}">
        <div class="terminal-type-code">${t.code}</div>
        <div class="terminal-type-label">${escapeHtml(t.label)}</div>
        <div class="terminal-type-desc">${escapeHtml(t.desc)}</div>
      </button>
    `).join('');

    const fallbackHtml = fallbackType ? `
      <button class="terminal-type-card-fallback${current === 'ALL' ? ' selected' : ''}" data-type="ALL">
        <div class="terminal-type-fallback-row">
          <div class="terminal-type-fallback-label">${escapeHtml(fallbackType.label)}</div>
          <div class="terminal-type-fallback-arrow">→</div>
        </div>
        <div class="terminal-type-desc">${escapeHtml(fallbackType.desc)}</div>
      </button>` : '';

    return `
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
          <span class="app-version">${TOOLKIT_VERSION}</span>
        </div>
        <div class="app-header-actions">
          ${forChange ? '<button class="btn-secondary" id="cancel-type-change">Cancel</button>' : ''}
          <div class="feedback-email">Feedback: stephen.shaw@oolio.com</div>
        </div>
      </div>
      <div class="select-type">
        <h2 class="select-type-heading">${forChange ? 'Change terminal type' : 'Select this terminal type'}</h2>
        <p class="select-type-sub">This drives which modules and steps the toolkit shows. You can change it later from the home page.</p>
        <div class="terminal-type-grid">${primaryHtml}</div>
        <div class="terminal-type-fallback-section">
          <div class="terminal-type-fallback-divider"><span>or</span></div>
          ${fallbackHtml}
        </div>
        ${forChange && current ? '<div class="select-type-warning">Changing the terminal type may make some completed steps no longer relevant. Their status is preserved in progress.json but they will not show in the new module list.</div>' : ''}
      </div>
    `;
}

function renderHome() {
    const overall = getOverallProgress();
    const hasProgress = overall.done > 0 && overall.done < overall.total;
    const isComplete = overall.total > 0 && overall.done === overall.total;
    const ctaLabel = isComplete ? 'Migration complete' : (hasProgress ? 'Resume migration' : 'Migrate');
    const ctaSub = isComplete
        ? 'All steps marked complete or skipped.'
        : (hasProgress
            ? `Picks up at the next pending step (${overall.done} of ${overall.total} done).`
            : 'Walks the full migration flow. Pauses for input when needed.');

    const visibleModules = getVisibleModules();
    const moduleButtons = visibleModules.map(mod => {
        const p = getModuleProgress(mod);
        const done = p.total > 0 && p.done === p.total;
        return `
          <button class="module-jump" data-module="${mod.id}">
            <span class="module-jump-icon">${mod.icon}</span>
            <span class="module-jump-text">
              <span class="module-jump-title">${escapeHtml(mod.name)}</span>
              <span class="module-jump-meta">${p.done} / ${p.total}${done ? ' · complete' : ''}</span>
            </span>
          </button>`;
    }).join('');

    const tt = getTerminalType();
    const ttLabel = (TERMINAL_TYPES.find(t => t.code === tt) || {}).label || '';

    const healthBanner = state.healthIssues.length ? `
      <div class="health-banner">
        <strong>Toolkit integrity check found ${state.healthIssues.length} issue(s) at startup:</strong>
        <ul>${state.healthIssues.map(i => `<li>${escapeHtml(i)}</li>`).join('')}</ul>
        <div>This copy of the toolkit may be corrupted or partially updated. Re-extract the release zip before migrating.</div>
      </div>` : '';

    return `
      ${healthBanner}
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
          <span class="app-version">${TOOLKIT_VERSION}</span>
        </div>
        <div class="terminal-type-pill">
          <span class="terminal-type-pill-label">Type:</span>
          <span class="terminal-type-pill-value">${escapeHtml(tt)} - ${escapeHtml(ttLabel)}</span>
          <button class="btn-ghost" id="change-type">Change</button>
        </div>
      </div>
      ${renderOverallProgress()}

      <div class="migrate-cta">
        <button class="migrate-cta-button" id="start-migrate" ${isComplete ? 'disabled' : ''}>
          <span class="migrate-cta-label">${escapeHtml(ctaLabel)}</span>
          <span class="migrate-cta-arrow">→</span>
        </button>
        <div class="migrate-cta-sub">${escapeHtml(ctaSub)}</div>
      </div>

      <div class="module-jump-section">
        <div class="module-jump-header">Or jump to a specific module</div>
        <div class="module-jump-grid">${moduleButtons}</div>
      </div>
    `;
}

// ---------- Migrate view ----------

function renderPauseCard(action) {
    const step = action.stepDef;
    const moduleDef = action.moduleDef;
    const key = action.moduleId + '.' + action.stepId;
    const isDanger = step.risk === 'danger';
    const confirmed = state.confirmTicked[key] === true;

    if (action.type === 'pause-config') {
        return `
          <div class="migrate-pause">
            <div class="migrate-pause-title">Configure terminal</div>
            <div class="migrate-pause-note">${escapeHtml(step.note || '')}</div>
            ${renderConfigStep()}
            <div class="step-actions">
              <button class="btn-ghost" data-migrate-action="skip">Skip</button>
              <button class="btn-ghost" data-migrate-action="abort">Stop migration</button>
            </div>
          </div>`;
    }

    if (action.type === 'pause-manual') {
        const linksHtml = step.links ? `
          <ul class="links-list">
            ${step.links.map(l => `<li><a href="${escapeHtml(l.href)}" target="_blank" rel="noopener">${escapeHtml(l.label)}</a></li>`).join('')}
          </ul>` : '';
        return `
          <div class="migrate-pause">
            <div class="migrate-pause-title">${escapeHtml(step.title)}</div>
            <div class="migrate-pause-note">${escapeHtml(step.note || '')}</div>
            ${linksHtml}
            <div class="step-actions">
              <button class="btn-primary" data-migrate-action="continue">Mark done & continue</button>
              <button class="btn-ghost" data-migrate-action="skip">Skip</button>
              <button class="btn-ghost" data-migrate-action="abort">Stop migration</button>
            </div>
          </div>`;
    }

    if (action.type === 'pause-optional') {
        const runLabel = action.runLabel || ('Run ' + step.title);
        return `
          <div class="migrate-pause">
            <div class="migrate-pause-title">${escapeHtml(step.title)}</div>
            <div class="migrate-pause-note">${escapeHtml(step.note || '')}</div>
            ${renderProgressBar(action.moduleId, action.stepId)}
            ${renderOutputLog(action.moduleId, action.stepId)}
            <div class="step-actions">
              <button class="btn-primary" data-migrate-action="continue">${escapeHtml(runLabel)}</button>
              <button class="btn-secondary" data-migrate-action="skip">Skip</button>
              <button class="btn-ghost" data-migrate-action="abort">Stop migration</button>
            </div>
          </div>`;
    }

    // pause-form / pause-confirm: show inputs and / or danger checkbox, then Run & continue.
    // Every remaining input is optional (active-hours defaults to 3), so the Run
    // button is gated only on the danger confirmation.
    const inputs = step.requiresInputs || [];
    const runDisabled = (isDanger && !confirmed);

    const inputHtml = inputs.length > 0 ? `
      <div class="step-inputs">
        ${inputs.map(inp => {
            const fieldKey = key + '.' + inp.name;
            const val = state.inputValues[fieldKey] || '';
            const inputType = inp.type === 'password' ? 'password' : 'text';
            return `
              <label class="step-input-field">
                <span class="step-input-label">${escapeHtml(inp.label)}</span>
                <span class="step-input-row">
                  ${inp.prefix ? `<span class="step-input-prefix">${escapeHtml(inp.prefix)}</span>` : ''}
                  <input type="${inputType}" data-step-input="${fieldKey}" value="${escapeHtml(val)}" placeholder="${escapeHtml(inp.placeholder || '')}" autocomplete="off" />
                </span>
              </label>`;
        }).join('')}
      </div>` : '';

    const dangerWarning = isDanger ? `
      <div class="step-danger-warning">This action is destructive and cannot be undone. Make sure the data backup is complete.</div>
      <label class="step-confirm">
        <input type="checkbox" data-step-confirm="${key}" ${confirmed ? 'checked' : ''}>
        I confirm this action is intentional and the data backup is complete.
      </label>` : '';

    return `
      <div class="migrate-pause">
        <div class="migrate-pause-title">${escapeHtml(step.title)} <span class="risk-dot risk-${step.risk}"></span></div>
        <div class="migrate-pause-note">${escapeHtml(step.note || '')}</div>
        ${dangerWarning}
        ${inputHtml}
        <div class="step-actions">
          <button class="btn-primary" data-migrate-action="continue" ${runDisabled ? 'disabled' : ''}>Run & continue</button>
          <button class="btn-ghost" data-migrate-action="skip">Skip</button>
          <button class="btn-ghost" data-migrate-action="abort">Stop migration</button>
        </div>
      </div>`;
}

function renderMigrate() {
    const overall = getOverallProgress();
    const pct = overall.total === 0 ? 0 : Math.round((overall.done / overall.total) * 100);
    const action = state.migrate.currentAction;

    let centerHtml = '';

    if (state.migrate.done) {
        centerHtml = `
          <div class="migrate-status">
            <div class="migrate-status-icon ok">✓</div>
            <div class="migrate-status-title">Migration complete</div>
            <div class="migrate-status-sub">Every visible step is complete or skipped. Restart the terminal if the final-restart step didn't already.</div>
            <div class="step-actions">
              <button class="btn-secondary" id="back-home">Back to home</button>
            </div>
          </div>`;
    } else if (!action) {
        centerHtml = `
          <div class="migrate-status">
            <div class="migrate-status-icon">…</div>
            <div class="migrate-status-title">Starting migration</div>
          </div>`;
    } else if (state.migrate.errorState) {
        centerHtml = `
          <div class="migrate-pause">
            <div class="migrate-pause-title">Step reported an error: ${escapeHtml(action.stepDef.title)}</div>
            <div class="migrate-pause-note">Review the output below. Retry, skip, or stop the migration.</div>
            ${renderProgressBar(action.moduleId, action.stepId)}
            ${renderOutputLog(action.moduleId, action.stepId)}
            <div class="step-actions">
              <button class="btn-primary" data-migrate-action="retry">Retry step</button>
              <button class="btn-secondary" data-migrate-action="skip">Skip step</button>
              <button class="btn-ghost" data-migrate-action="abort">Stop migration</button>
            </div>
          </div>`;
    } else if (action.type === 'auto-run') {
        const isRunning = state.runningStep === (action.moduleId + '.' + action.stepId);
        centerHtml = `
          <div class="migrate-now">
            <div class="migrate-now-label">${isRunning ? 'Running' : 'Preparing'} - ${escapeHtml(action.moduleDef.name)}</div>
            <div class="migrate-now-title">${escapeHtml(action.stepDef.title)}</div>
            ${renderProgressBar(action.moduleId, action.stepId)}
            ${renderOutputLog(action.moduleId, action.stepId)}
            <div class="step-actions">
              <button class="btn-ghost" data-migrate-action="abort">Stop migration</button>
            </div>
          </div>`;
    } else {
        centerHtml = `
          <div class="migrate-now-label">Action needed - ${escapeHtml(action.moduleDef.name)}</div>
          ${renderPauseCard(action)}
        `;
    }

    return `
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
          <span class="app-version">${TOOLKIT_VERSION}</span>
        </div>
        <div class="app-header-actions">
          <button class="btn-secondary" id="back-home">← Home</button>
          <div class="feedback-email">Feedback: stephen.shaw@oolio.com</div>
        </div>
      </div>

      <div class="migrate-progress">
        <div class="overall-progress-label">
          <span>Migration progress</span>
          <span>${overall.done} of ${overall.total}</span>
        </div>
        <div class="progress-track"><div class="progress-fill" style="width:${pct}%"></div></div>
      </div>

      ${centerHtml}
    `;
}

// Render the progress bar HTML for a step. Returns empty string if no progress
// is active. Called from renderStep / renderMigrate; kept in sync with live
// updates by updateProgressBar.
function renderProgressBar(moduleId, stepId) {
    const key = moduleId + '.' + stepId;
    const p = state.progressBars[key];
    if (!p || p.done) return '';
    return `
        <div id="progress-${moduleId}-${stepId}" class="progress-bar-container">
            <div class="progress-bar-track"><div class="progress-bar-fill"></div></div>
            <div class="progress-bar-label"></div>
        </div>`;
}

// Parse a __PROGRESS__ payload and update the live progress bar without a full
// re-render (so input focus and scroll are preserved). Falls back to triggering
// a render if the bar container is not yet in the DOM.
function updateProgressBar(moduleId, stepId, payload) {
    const key = moduleId + '.' + stepId;
    state.progressBars[key] = payload;

    const container = document.getElementById('progress-' + moduleId + '-' + stepId);
    if (!container) {
        // First progress event for this step - need a render to materialise the
        // container. Subsequent events update it directly.
        if (state.runningStep === key) render();
        return;
    }

    if (payload.done) {
        container.style.display = 'none';
        return;
    }
    container.style.display = '';

    const fill  = container.querySelector('.progress-bar-fill');
    const label = container.querySelector('.progress-bar-label');
    if (!fill || !label) return;

    if (payload.total > 0) {
        const pct = Math.min(100, Math.floor((payload.current / payload.total) * 100));
        const cur = (payload.current / 1024 / 1024).toFixed(1);
        const tot = (payload.total / 1024 / 1024).toFixed(1);
        fill.classList.remove('indeterminate');
        fill.style.width = pct + '%';
        label.textContent = `${payload.label} · ${cur} / ${tot} MB · ${pct}% · ${payload.elapsed}s`;
    } else {
        fill.classList.add('indeterminate');
        fill.style.width = '100%';
        const mins = Math.floor(payload.elapsed / 60);
        const secs = (payload.elapsed % 60).toString().padStart(2, '0');
        label.textContent = `${payload.label} · ${mins}:${secs} elapsed`;
    }
}

// Append a single output line to the live log without re-rendering the whole UI.
// Re-rendering on every SSE line was eating keystrokes in text inputs
// and resetting scroll position. This appends directly to the existing DOM node;
// state.outputLog still accumulates so a later full render reproduces the same view.
function appendOutputLine(moduleId, stepId, line) {
    const key = moduleId + '.' + stepId;
    state.outputLog[key] = state.outputLog[key] || [];
    state.outputLog[key].push(line);

    const el = document.getElementById('output-' + moduleId + '-' + stepId);
    if (!el) return;

    let cls = '';
    if (line.includes('[OK]')) cls = 'ok';
    else if (line.includes('[WARN]')) cls = 'warn';
    else if (line.includes('[ERROR]') || line.startsWith('__ERROR__')) cls = 'error';

    const prefix = el.childNodes.length > 0 ? '\n' : '';
    el.insertAdjacentHTML('beforeend',
        prefix + `<span class="output-line ${cls}">${escapeHtml(line)}</span>`);
    el.scrollTop = el.scrollHeight;
}

function renderOutputLog(moduleId, stepId) {
    const key = moduleId + '.' + stepId;
    const lines = state.outputLog[key];
    if (!lines || lines.length === 0) return '';
    const errorsOnly = state.outputFilter && state.outputFilter[key] === 'errors';
    const errorCount = lines.filter(l => l.includes('[ERROR]') || l.startsWith('__ERROR__')).length;
    const visibleLines = errorsOnly ? lines.filter(l => l.includes('[ERROR]') || l.startsWith('__ERROR__')) : lines;
    const html = visibleLines.map(line => {
        let cls = '';
        if (line.includes('[OK]')) cls = 'ok';
        else if (line.includes('[WARN]')) cls = 'warn';
        else if (line.includes('[ERROR]') || line.startsWith('__ERROR__')) cls = 'error';
        return `<span class="output-line ${cls}">${escapeHtml(line)}</span>`;
    }).join('\n');
    return `
      <div class="output-toolbar">
        <span class="output-stats">${lines.length} line${lines.length === 1 ? '' : 's'}${errorCount > 0 ? ` · <span class="output-stats-err">${errorCount} error${errorCount === 1 ? '' : 's'}</span>` : ''}</span>
        <button class="btn-ghost btn-tiny" data-action="output-copy" data-key="${key}">Copy</button>
        <button class="btn-ghost btn-tiny" data-action="output-filter" data-key="${key}">${errorsOnly ? 'Show all' : 'Errors only'}</button>
      </div>
      <div id="output-${moduleId}-${stepId}" class="output-log" data-errors-only="${errorsOnly ? '1' : '0'}">${html}</div>`;
}

function renderConfigStep() {
    const meta = getMeta();
    const dm = meta.deploymentMode || 'windows';
    const cds = meta.hasCDS === true;

    return `
      <div class="config-form">
        <h3>Deployment options</h3>
        <div class="form-group">
          <label class="form-group-label">Deployment mode</label>
          <div class="radio-row">
            <label><input type="radio" name="deploymentMode" value="windows" ${dm==='windows'?'checked':''}> Windows app (native installer)</label>
            <label><input type="radio" name="deploymentMode" value="chrome" ${dm==='chrome'?'checked':''}> Chrome (fullscreen)</label>
          </div>
        </div>
        <div class="form-group">
          <label class="form-group-label">Customer Display (CDS) present?</label>
          <div class="radio-row">
            <label><input type="radio" name="hasCDS" value="yes" ${cds?'checked':''}> Yes</label>
            <label><input type="radio" name="hasCDS" value="no" ${!cds?'checked':''}> No</label>
          </div>
        </div>
        <div class="step-actions">
          <button class="btn-primary" id="config-save">Save configuration</button>
        </div>
      </div>
    `;
}

function renderStep(moduleDef, step, index) {
    const status = getStepStatus(moduleDef.id, step.id);
    const key = moduleDef.id + '.' + step.id;
    const expanded = state.expandedSteps[key] === true || (status === 'running');
    const isRunning = state.runningStep === key;

    let stepNumClass = '';
    let stepNumText = String(index + 1);
    if (status === 'complete') { stepNumClass = 'complete'; stepNumText = '✓'; }
    else if (status === 'skipped') { stepNumClass = 'skipped'; stepNumText = '–'; }
    else if (status === 'running') { stepNumClass = 'running'; stepNumText = '·'; }
    else if (status === 'error')   { stepNumClass = 'error'; stepNumText = '!'; }

    let body = '';
    if (expanded) {
        if (step.configStep) {
            body = `<div class="step-body"><div class="step-body-inner">${renderConfigStep()}</div></div>`;
        } else {
            const isDanger = step.risk === 'danger';
            const confirmed = state.confirmTicked[key] === true;
            const inputs = step.requiresInputs || [];
            // Every remaining input is optional (active-hours defaults to 3).
            const runDisabled = isRunning || (isDanger && !confirmed);

            const linksHtml = step.links ? `
              <ul class="links-list">
                ${step.links.map(l => `<li><a href="${escapeHtml(l.href)}" target="_blank" rel="noopener">${escapeHtml(l.label)}</a></li>`).join('')}
              </ul>` : '';

            const inputHtml = inputs.length > 0 ? `
              <div class="step-inputs">
                ${inputs.map(inp => {
                    const fieldKey = key + '.' + inp.name;
                    const val = state.inputValues[fieldKey] || '';
                    const inputType = inp.type === 'password' ? 'password' : 'text';
                    return `
                      <label class="step-input-field">
                        <span class="step-input-label">${escapeHtml(inp.label)}</span>
                        <span class="step-input-row">
                          ${inp.prefix ? `<span class="step-input-prefix">${escapeHtml(inp.prefix)}</span>` : ''}
                          <input type="${inputType}" data-step-input="${fieldKey}" value="${escapeHtml(val)}" placeholder="${escapeHtml(inp.placeholder || '')}" autocomplete="off" />
                        </span>
                      </label>`;
                }).join('')}
              </div>` : '';

            const previewHtml = (isDanger && step.preview && step.preview.length > 0) ? `
              <div class="step-danger-preview">
                <div class="step-danger-preview-title">What will change:</div>
                <ul>${step.preview.map(p => `<li>${escapeHtml(p)}</li>`).join('')}</ul>
              </div>` : '';
            const dangerWarning = isDanger ? `
              <div class="step-danger-warning">This action is destructive and cannot be undone. Make sure the data backup is complete.</div>
              ${previewHtml}
              <label class="step-confirm">
                <input type="checkbox" data-step-confirm="${key}" ${confirmed ? 'checked' : ''}>
                I confirm this action is intentional and the data backup is complete.
              </label>` : '';

            const showRun = !step.linksOnly;

            body = `
              <div class="step-body">
                <div class="step-body-inner">
                  <div class="step-note">${escapeHtml(step.note || '')}</div>
                  ${dangerWarning}
                  ${linksHtml}
                  ${inputHtml}
                  ${renderProgressBar(moduleDef.id, step.id)}
                  ${renderOutputLog(moduleDef.id, step.id)}
                  <div class="step-actions">
                    ${showRun ? `<button class="btn-primary" data-action="run" data-key="${key}" ${runDisabled ? 'disabled' : ''}>${isRunning ? 'Running…' : 'Run'}</button>` : ''}
                    ${status === 'error' ? `<button class="btn-primary" data-action="retry" data-key="${key}" ${isRunning ? 'disabled' : ''}>Retry</button>` : ''}
                    <button class="btn-secondary" data-action="mark-done" data-key="${key}" ${isRunning ? 'disabled' : ''}>Mark done</button>
                    <button class="btn-ghost" data-action="skip" data-key="${key}" ${isRunning ? 'disabled' : ''}>Skip</button>
                    ${status !== 'pending' ? `<button class="btn-ghost" data-action="reset" data-key="${key}" ${isRunning ? 'disabled' : ''}>Reset</button>` : ''}
                  </div>
                </div>
              </div>`;
        }
    }

    const optionalBadge = step.optional ? '<span class="step-optional-badge">optional</span>' : '';

    return `
      <div class="step ${expanded ? 'expanded' : ''}" data-step-key="${key}">
        <div class="step-header" data-toggle="${key}">
          <div class="step-num ${stepNumClass}">${stepNumText}</div>
          <div class="step-title-block">
            <div class="step-title">${escapeHtml(step.title)}${optionalBadge}</div>
            <div class="step-meta">${status.toUpperCase()}</div>
          </div>
          <div class="risk-dot risk-${step.risk}" title="risk: ${step.risk}"></div>
          <div class="step-chevron">›</div>
        </div>
        ${body}
      </div>`;
}

function renderModule() {
    const mod = MODULES.find(m => m.id === state.activeModule);
    if (!mod) return renderHome();

    const visible = getVisibleSteps(mod);
    const p = getModuleProgress(mod);
    const stepsHtml = visible.map((step, i) => renderStep(mod, step, i)).join('');

    let autoRunBar = '';
    if (mod.id === 'bepoz') {
        autoRunBar = `
          <div class="auto-run-bar">
            <div class="auto-run-bar-text">Run safe steps as a chain (with a pause to verify the backup zip).</div>
            <button class="btn-primary" id="bepoz-chain" ${state.runningStep ? 'disabled' : ''}>Run safe steps</button>
          </div>`;
    } else if (mod.id === 'dependencies') {
        autoRunBar = `
          <div class="auto-run-bar">
            <div class="auto-run-bar-text">Run every check / install step for this terminal type in sequence.</div>
            <button class="btn-primary" id="deps-chain" ${state.runningStep ? 'disabled' : ''}>Check dependencies</button>
          </div>`;
    }

    return `
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
          <span class="app-version">${TOOLKIT_VERSION}</span>
        </div>
        <div class="app-header-actions">
          <button class="btn-secondary" id="back-home">← Back</button>
          <div class="feedback-email">Feedback: stephen.shaw@oolio.com</div>
        </div>
      </div>
      <div class="module-header">
        <div class="module-title-block">
          <div class="module-title">${escapeHtml(mod.name)}</div>
          <div class="module-subtitle">${p.done} of ${p.total} steps complete</div>
        </div>
      </div>
      ${autoRunBar}
      ${stepsHtml}
    `;
}

function render() {
    const app = document.getElementById('app');
    if (state.view === 'select-type' || state.view === 'change-type') {
        app.innerHTML = renderSelectType(state.view === 'change-type');
        attachSelectTypeHandlers();
    } else if (state.view === 'home') {
        app.innerHTML = renderHome();
        attachHomeHandlers();
    } else if (state.view === 'migrate') {
        app.innerHTML = renderMigrate();
        attachMigrateHandlers();
    } else {
        app.innerHTML = renderModule();
        attachModuleHandlers();
    }
}

function attachSelectTypeHandlers() {
    document.querySelectorAll('[data-type]').forEach(card => {
        card.addEventListener('click', () => {
            const code = card.dataset.type;
            const previous = getTerminalType();
            if (previous && previous !== code) {
                if (!confirm(`Change selection from ${previous} to ${code}?\n\nCompleted steps that don't apply may no longer appear in the module list. Their status is preserved.`)) return;
            }
            state.progress.meta = state.progress.meta || {};
            state.progress.meta.terminalType = code;
            saveProgress();
            state.view = 'home';
            render();
        });
    });
    const cancel = document.getElementById('cancel-type-change');
    if (cancel) cancel.addEventListener('click', () => { state.view = 'home'; render(); });
}

// ---------- Event handlers ----------

function attachHomeHandlers() {
    const start = document.getElementById('start-migrate');
    if (start) start.addEventListener('click', () => startMigrate());

    const change = document.getElementById('change-type');
    if (change) change.addEventListener('click', () => { state.view = 'change-type'; render(); });

    document.querySelectorAll('.module-jump').forEach(btn => {
        btn.addEventListener('click', () => {
            state.activeModule = btn.dataset.module;
            state.view = 'module';
            render();
        });
    });
}

function attachMigrateHandlers() {
    const back = document.getElementById('back-home');
    if (back) back.addEventListener('click', () => {
        if (state.migrate.active && !state.migrate.done) {
            if (!confirm('Migration is in progress. Stop it and return to home?')) return;
            abortMigrate();
        }
        state.view = 'home';
        state.migrate.currentAction = null;
        state.migrate.active = false;
        state.migrate.done = false;
        render();
    });

    // Step inputs - same handler as module view.
    document.querySelectorAll('[data-step-input]').forEach(el => {
        el.addEventListener('input', (e) => {
            state.inputValues[el.dataset.stepInput] = e.target.value;
        });
    });

    document.querySelectorAll('[data-step-confirm]').forEach(el => {
        el.addEventListener('change', (e) => {
            state.confirmTicked[el.dataset.stepConfirm] = e.target.checked;
            render();
        });
    });

    document.querySelectorAll('[data-migrate-action]').forEach(btn => {
        btn.addEventListener('click', () => {
            const action = btn.dataset.migrateAction;
            if (action === 'continue') continueMigrateStep();
            else if (action === 'skip') skipMigrateStep();
            else if (action === 'retry') retryMigrateStep();
            else if (action === 'abort') {
                if (confirm('Stop the migration?')) abortMigrate();
            }
        });
    });

    // The Save button on the embedded config form.
    const save = document.getElementById('config-save');
    if (save) save.addEventListener('click', () => {
        const dm = document.querySelector('input[name="deploymentMode"]:checked');
        const cds = document.querySelector('input[name="hasCDS"]:checked');
        state.progress.meta = state.progress.meta || {};
        state.progress.meta.deploymentMode = dm ? dm.value : 'windows';
        state.progress.meta.hasCDS = cds ? (cds.value === 'yes') : false;
        setStepStatus('oolio', 'deployment-config', 'complete');
        if (state.view === 'migrate') {
            resolveMigrateWait();
        } else {
            render();
        }
    });
}

function attachModuleHandlers() {
    const back = document.getElementById('back-home');
    if (back) back.addEventListener('click', () => { state.view = 'home'; render(); });

    document.querySelectorAll('[data-toggle]').forEach(el => {
        el.addEventListener('click', () => {
            const key = el.dataset.toggle;
            state.expandedSteps[key] = !state.expandedSteps[key];
            render();
        });
    });

    document.querySelectorAll('[data-step-input]').forEach(el => {
        el.addEventListener('input', (e) => {
            state.inputValues[el.dataset.stepInput] = e.target.value;
        });
    });

    document.querySelectorAll('[data-step-confirm]').forEach(el => {
        el.addEventListener('change', (e) => {
            state.confirmTicked[el.dataset.stepConfirm] = e.target.checked;
            render();
        });
    });

    document.querySelectorAll('[data-action]').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const action = btn.dataset.action;
            const [moduleId, stepId] = btn.dataset.key.split('.');
            const key = btn.dataset.key;

            if (action === 'run') {
                runStep(moduleId, stepId, getStepExtras(stepId));
            } else if (action === 'mark-done') {
                setStepStatus(moduleId, stepId, 'complete');
                render();
            } else if (action === 'skip') {
                setStepStatus(moduleId, stepId, 'skipped');
                render();
            } else if (action === 'reset') {
                setStepStatus(moduleId, stepId, 'pending');
                state.outputLog[key] = [];
                render();
            } else if (action === 'retry') {
                state.outputLog[key] = [];
                setStepStatus(moduleId, stepId, 'pending');
                render();
                runStep(moduleId, stepId, getStepExtras(stepId));
            } else if (action === 'output-copy') {
                const lines = state.outputLog[key] || [];
                const text = lines.join('\n');
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text).then(() => {
                        btn.textContent = 'Copied';
                        setTimeout(() => { btn.textContent = 'Copy'; }, 1200);
                    });
                } else {
                    // Fallback for older browsers
                    const ta = document.createElement('textarea');
                    ta.value = text;
                    document.body.appendChild(ta);
                    ta.select();
                    try { document.execCommand('copy'); } catch (e) {}
                    document.body.removeChild(ta);
                    btn.textContent = 'Copied';
                    setTimeout(() => { btn.textContent = 'Copy'; }, 1200);
                }
            } else if (action === 'output-filter') {
                state.outputFilter = state.outputFilter || {};
                state.outputFilter[key] = state.outputFilter[key] === 'errors' ? 'all' : 'errors';
                render();
            }
        });
    });

    const chain = document.getElementById('bepoz-chain');
    if (chain) chain.addEventListener('click', runBepozSafeChain);
    const dchain = document.getElementById('deps-chain');
    if (dchain) dchain.addEventListener('click', runDepsCheckChain);

    const save = document.getElementById('config-save');
    if (save) save.addEventListener('click', () => {
        const dm = document.querySelector('input[name="deploymentMode"]:checked');
        const cds = document.querySelector('input[name="hasCDS"]:checked');
        state.progress.meta = state.progress.meta || {};
        state.progress.meta.deploymentMode = dm ? dm.value : 'windows';
        state.progress.meta.hasCDS = cds ? (cds.value === 'yes') : false;
        setStepStatus('oolio', 'deployment-config', 'complete');
        render();
    });
}
