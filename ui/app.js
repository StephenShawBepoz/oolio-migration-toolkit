// app.js - Oolio Migration Toolkit single-page UI

// ---------- Module + step definitions ----------

const MODULES = [
    {
        id: 'bepoz',
        name: 'Bepoz Software',
        icon: '1',
        description: 'Back up data, stop services, and remove the legacy Bepoz install.',
        steps: [
            { id: 'read-registry',   title: 'Read Bepoz registry',   risk: 'safe',   note: 'Reads SQL_Server, DataPath, BackupPath from HKCU\\Software\\Backoffice. No changes made.' },
            { id: 'stop-sql',        title: 'Stop SQL Server',       risk: 'warn',   note: 'Stops and disables the local MSSQL$<instance> service if present. Skips silently if SQL is on a venue server.' },
            { id: 'zip-data',        title: 'Zip Bepoz data',        risk: 'safe',   note: 'Compresses the DataPath folder into the BackupPath. Verify the zip exists before continuing.' },
            { id: 'kill-processes',  title: 'Terminate processes from C:\\Bepoz', risk: 'safe', note: 'Walks every running process and force-stops any whose executable lives under C:\\Bepoz (matches by path, not by process name).' },
            { id: 'clear-startup',   title: 'Clear shell:startup',   risk: 'warn',   note: 'Removes everything from the user shell:startup folder. POS terminal only.' },
            { id: 'check-run-key',   title: 'Export & clean HKCU Run key', risk: 'warn', note: 'Exports the entire HKCU Run key to the backup folder (HKCU_Run_<timestamp>.reg), then removes known Bepoz Run keys. Restore the export with reg import if needed.' },
            { id: 'delete-registry', title: 'Delete Bepoz registry', risk: 'danger', note: 'Removes HKCU\\Software\\Backoffice. Make sure the data backup zip exists first.' },
            { id: 'uninstall',       title: 'Consolidate backup & remove Bepoz folder', risk: 'danger', note: 'Bepoz is not a real installed program. Instead: moves any .zip / .reg backups into C:\\Bepoz\\Backup, then deletes every other file and folder under C:\\Bepoz. Aborts if no Bepoz_Data_*.zip is present in the backup folder.' }
        ]
    },
    {
        id: 'windows',
        name: 'Windows Settings',
        icon: '2',
        description: 'Verify autologon, firewall, network, then rename and clean the device.',
        steps: [
            { id: 'verify-autologon', title: 'Verify / enable autologon', risk: 'warn',
              requiresInputs: [
                { name: 'username', label: 'Username', placeholder: 'e.g. POSUser' },
                { name: 'password', label: 'Password', placeholder: '', type: 'password' },
                { name: 'domain',   label: 'Domain (optional)', placeholder: 'leave blank for local machine' }
              ],
              note: 'Reads the Winlogon registry to confirm autologon. If autologon is off and you fill the form, the toolkit writes the autologon registry values. Effective after the final restart. The password is stored in plaintext at HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon - this is the standard Windows AutoAdminLogon mechanism.'
            },
            { id: 'enable-firewall',  title: 'Enable Windows Firewall', risk: 'warn', note: 'Enables firewall for Domain, Private, and Public profiles.' },
            { id: 'check-ip',         title: 'Check IP configuration', risk: 'safe', note: 'Shows current IP and DHCP status for active adapters.' },
            { id: 'switch-dhcp',      title: 'Switch to DHCP',     risk: 'warn', note: 'Switches static-IP adapters to DHCP. Skips silently if already DHCP.' },
            { id: 'rename-device',    title: 'Rename device',      risk: 'warn',
              requiresInputs: [{ name: 'value', label: 'Suffix (after "Oolio-")', placeholder: 'POS1', prefix: 'Oolio-' }],
              note: 'Renames the device to Oolio-<suffix>. Effective after the final restart.' },
            { id: 'clean-desktop',    title: 'Clean desktop',      risk: 'warn', note: 'Removes everything from user and public desktop. POS terminal only.' },
            { id: 'set-wallpaper',    title: 'Apply Oolio wallpaper', risk: 'safe', note: 'Copies assets/wallpaper.jpg to C:\\Oolio\\Assets and applies it. Drop wallpaper.jpg into the toolkit assets\\ folder before running.' }
        ]
    },
    {
        id: 'dependencies',
        name: 'Oolio Dependencies',
        icon: '3',
        description: 'Verify or install Chrome and WebView2, plus printer utility links.',
        steps: [
            { id: 'check-chrome',      title: 'Check / install Google Chrome', risk: 'safe', note: 'Reports Chrome install path and version. If Chrome is missing, downloads the Google Enterprise MSI and installs it silently (msiexec /qn). Requires internet at this step.' },
            { id: 'check-webview2',    title: 'Check Edge WebView2', risk: 'safe', note: 'Required for Windows native Oolio POS and CDS apps. Opens download page if missing.' },
            { id: 'printer-utilities', title: 'Printer utilities',   risk: 'safe', linksOnly: true,
              links: [
                { label: 'Epson TM Utility',                href: 'https://download.epson-biz.com/modules/pos/' },
                { label: 'Epson Firmware Updater',          href: 'https://download.epson-biz.com/modules/pos/' },
                { label: 'Star Utility (TSP / mC-Print)',   href: 'https://www.starmicronics.com/support/allproducts' },
                { label: 'Star Firmware Updater',           href: 'https://www.starmicronics.com/support/allproducts' },
                { label: 'Bixolon Utility and Firmware',    href: 'https://www.bixolon.com/sub_support_down.php' },
                { label: 'Element / Gravity Utility (pending Oolio confirmation)', href: '#' }
              ],
              note: 'Open each utility download in your browser. No PowerShell execution. Mark done once installed/handled.'
            }
        ]
    },
    {
        id: 'oolio',
        name: 'Oolio POS Setup',
        icon: '4',
        description: 'Configure terminal type, create folders and shortcuts, then schedule the final restart.',
        steps: [
            { id: 'terminal-type',      title: 'Configure terminal',         risk: 'safe', configStep: true, note: 'Select terminal type and deployment mode. Subsequent steps adapt to your selection.' },
            { id: 'create-folders',     title: 'Create Oolio folders',       risk: 'safe', note: 'Creates C:\\Oolio and Assets/Certs/Logs subfolders.' },
            { id: 'install-pos-chrome', title: 'Create Oolio POS shortcut (Chrome kiosk)', risk: 'safe', note: 'Public-desktop shortcut launching pos.oolio.io fullscreen.', showWhen: m => m.terminalType === 'POS' && m.deploymentMode === 'chrome' },
            { id: 'install-cds-chrome', title: 'Create Oolio CDS shortcut (Chrome kiosk)', risk: 'safe', note: 'Public-desktop shortcut launching cds.oolio.io on the second display.', showWhen: m => m.terminalType === 'POS' && m.deploymentMode === 'chrome' && m.hasCDS === true },
            { id: 'install-kds-chrome', title: 'Create Oolio KDS shortcut (Chrome kiosk)', risk: 'safe', note: 'Public-desktop shortcut launching kds.oolio.io fullscreen.', showWhen: m => m.terminalType === 'KDS' },
            { id: 'set-startup',        title: 'Configure startup',          risk: 'warn', note: 'Copies the Oolio desktop shortcut(s) into shell:startup so the kiosk launches when the autologon user signs in. Also tidies up legacy HKCU Run entries from older toolkit builds.' },
            { id: 'final-restart',      title: 'Schedule final restart',     risk: 'danger', note: 'Schedules a 30-second restart so the device rename, wallpaper, and autologon registry changes take effect. Run "shutdown /a" from a command prompt to cancel after it has scheduled.' }
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
    inputValues: {},
    confirmTicked: {},
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
    render();
});

// ---------- Helpers ----------

function getMeta() { return state.progress.meta || {}; }

function getStepStatus(moduleId, stepId) {
    const m = state.progress[moduleId];
    if (!m) return 'pending';
    return m[stepId] || 'pending';
}

function getVisibleSteps(moduleDef) {
    const meta = getMeta();
    return moduleDef.steps.filter(step => {
        if (!step.showWhen) return true;
        return step.showWhen(meta);
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
    MODULES.forEach(mod => {
        const p = getModuleProgress(mod);
        done += p.done; total += p.total;
    });
    return { done, total };
}

async function saveProgress() {
    state.progress.meta = state.progress.meta || {};
    state.progress.meta.lastUpdated = new Date().toISOString();
    try {
        await fetch('/progress', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(state.progress)
        });
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
//   - pause-form : needs technician input via inputs (verify-autologon, rename-device)
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
    for (const mod of MODULES) {
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
    const meta = getMeta();
    if (stepId === 'rename-device') {
        return { value: state.inputValues['windows.rename-device.value'] || '' };
    }
    if (stepId === 'set-startup') {
        return { value: meta.terminalType || '' };
    }
    if (stepId === 'verify-autologon') {
        const k = 'windows.verify-autologon';
        return {
            username: state.inputValues[k + '.username'] || '',
            password: state.inputValues[k + '.password'] || '',
            domain:   state.inputValues[k + '.domain']   || ''
        };
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
                try {
                    await waitForMigrateUser();
                } catch (e) {
                    return; // aborted
                }
                state.migrate.errorState = false;
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

    // pause-form / pause-confirm: run the step now, then resolve
    await runStep(next.moduleId, next.stepId, getStepExtras(next.stepId));
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

function runStep(moduleId, stepId, extras) {
    const key = moduleId + '.' + stepId;
    state.runningStep = key;
    state.outputLog[key] = [];
    setStepStatus(moduleId, stepId, 'running');
    render();

    // Backwards compat: if a plain string is passed, treat it as the legacy "value" param.
    let params = {};
    if (typeof extras === 'string') params.value = extras;
    else if (extras && typeof extras === 'object') params = extras;

    let url = `/run?module=${encodeURIComponent(moduleId)}&step=${encodeURIComponent(stepId)}`;
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
                const log = state.outputLog[key] || [];
                const hasError = log.some(line => line.includes('[ERROR]') || line.startsWith('__ERROR__'));
                setStepStatus(moduleId, stepId, hasError ? 'error' : 'complete');
                render();
                resolve(!hasError);
                return;
            }
            if (e.data.startsWith('__ERROR__')) {
                state.outputLog[key].push(e.data);
                render();
                return;
            }
            state.outputLog[key].push(e.data);
            render();
            const el = document.getElementById('output-' + moduleId + '-' + stepId);
            if (el) el.scrollTop = el.scrollHeight;
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
    // read-registry -> stop-sql -> zip-data -> pause -> kill-processes -> clear-startup
    const ids = ['read-registry', 'stop-sql', 'zip-data'];
    for (const id of ids) {
        const ok = await runStep('bepoz', id);
        if (!ok && id === 'read-registry') {
            alert('read-registry reported errors. Auto-run paused. Resolve before continuing.');
            return;
        }
    }
    const proceed = confirm('Backup zip step is complete. Confirm the zip file exists in the backup folder before continuing with kill-processes and clear-startup.');
    if (!proceed) return;
    await runStep('bepoz', 'kill-processes');
    await runStep('bepoz', 'clear-startup');
}

async function runDepsCheckChain() {
    await runStep('dependencies', 'check-chrome');
    await runStep('dependencies', 'check-webview2');
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

function renderHome() {
    const overall = getOverallProgress();
    const hasProgress = overall.done > 0 && overall.done < overall.total;
    const isComplete = overall.total > 0 && overall.done === overall.total;
    const ctaLabel = isComplete ? 'Migration complete' : (hasProgress ? 'Resume migration' : 'Migrate');
    const ctaSub = isComplete
        ? 'All steps marked complete or skipped.'
        : (hasProgress
            ? `Picks up at the next pending step (${overall.done} of ${overall.total} done).`
            : 'Walks the full Bepoz → Windows → Dependencies → Oolio flow. Pauses for input when needed.');

    const moduleButtons = MODULES.map(mod => {
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

    return `
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
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

    // pause-form / pause-confirm: show inputs and / or danger checkbox, then Run & continue.
    const inputs = step.requiresInputs || [];
    const requiredFieldsFilled = inputs.every(inp => {
        if (action.stepId === 'rename-device' && inp.name === 'value') {
            const v = state.inputValues[key + '.' + inp.name] || '';
            return v.trim().length > 0;
        }
        return true;
    });
    const runDisabled = (isDanger && !confirmed) || !requiredFieldsFilled;

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
        </div>
        <button class="btn-secondary" id="back-home">← Home</button>
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

function renderOutputLog(moduleId, stepId) {
    const key = moduleId + '.' + stepId;
    const lines = state.outputLog[key];
    if (!lines || lines.length === 0) return '';
    const html = lines.map(line => {
        let cls = '';
        if (line.includes('[OK]')) cls = 'ok';
        else if (line.includes('[WARN]')) cls = 'warn';
        else if (line.includes('[ERROR]') || line.startsWith('__ERROR__')) cls = 'error';
        return `<span class="output-line ${cls}">${escapeHtml(line)}</span>`;
    }).join('\n');
    return `<div id="output-${moduleId}-${stepId}" class="output-log">${html}</div>`;
}

function renderConfigStep() {
    const meta = getMeta();
    const tt = meta.terminalType || '';
    const dm = meta.deploymentMode || '';
    const cds = meta.hasCDS === true;
    const showDeploymentAndCDS = tt === 'POS';

    return `
      <div class="config-form">
        <h3>Terminal configuration</h3>
        <div class="form-group">
          <label class="form-group-label">Terminal type</label>
          <div class="radio-row">
            <label><input type="radio" name="terminalType" value="POS" ${tt==='POS'?'checked':''}> POS</label>
            <label><input type="radio" name="terminalType" value="KDS" ${tt==='KDS'?'checked':''}> KDS</label>
          </div>
        </div>
        ${showDeploymentAndCDS ? `
        <div class="form-group">
          <label class="form-group-label">Deployment mode</label>
          <div class="radio-row">
            <label><input type="radio" name="deploymentMode" value="chrome" ${dm==='chrome'?'checked':''}> Chrome (kiosk)</label>
            <label><input type="radio" name="deploymentMode" value="windows" ${dm==='windows'?'checked':''} disabled> Windows app (v2 — not yet available)</label>
          </div>
        </div>
        <div class="form-group">
          <label class="form-group-label">Customer Display (CDS) present?</label>
          <div class="radio-row">
            <label><input type="radio" name="hasCDS" value="yes" ${cds?'checked':''}> Yes</label>
            <label><input type="radio" name="hasCDS" value="no" ${!cds?'checked':''}> No</label>
          </div>
        </div>` : ''}
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
            // Inputs are optional by default. Only rename-device requires its single value.
            const requiredFieldsFilled = inputs.every(inp => {
                if (step.id === 'rename-device' && inp.name === 'value') {
                    const v = state.inputValues[key + '.' + inp.name] || '';
                    return v.trim().length > 0;
                }
                return true;
            });
            const runDisabled = isRunning || (isDanger && !confirmed) || !requiredFieldsFilled;

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

            const dangerWarning = isDanger ? `
              <div class="step-danger-warning">This action is destructive and cannot be undone. Make sure the data backup is complete.</div>
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
                  ${renderOutputLog(moduleDef.id, step.id)}
                  <div class="step-actions">
                    ${showRun ? `<button class="btn-primary" data-action="run" data-key="${key}" ${runDisabled ? 'disabled' : ''}>${isRunning ? 'Running…' : 'Run'}</button>` : ''}
                    <button class="btn-secondary" data-action="mark-done" data-key="${key}" ${isRunning ? 'disabled' : ''}>Mark done</button>
                    <button class="btn-ghost" data-action="skip" data-key="${key}" ${isRunning ? 'disabled' : ''}>Skip</button>
                    ${status !== 'pending' ? `<button class="btn-ghost" data-action="reset" data-key="${key}" ${isRunning ? 'disabled' : ''}>Reset</button>` : ''}
                  </div>
                </div>
              </div>`;
        }
    }

    return `
      <div class="step ${expanded ? 'expanded' : ''}" data-step-key="${key}">
        <div class="step-header" data-toggle="${key}">
          <div class="step-num ${stepNumClass}">${stepNumText}</div>
          <div class="step-title-block">
            <div class="step-title">${escapeHtml(step.title)}</div>
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
            <div class="auto-run-bar-text">Check Chrome and WebView2 in sequence.</div>
            <button class="btn-primary" id="deps-chain" ${state.runningStep ? 'disabled' : ''}>Check dependencies</button>
          </div>`;
    }

    return `
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
        </div>
        <button class="btn-secondary" id="back-home">← Back</button>
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
    if (state.view === 'home') {
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

// ---------- Event handlers ----------

function attachHomeHandlers() {
    const start = document.getElementById('start-migrate');
    if (start) start.addEventListener('click', () => startMigrate());

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

    // Inputs (verify-autologon, rename-device) - same handler as module view.
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
        const tt = document.querySelector('input[name="terminalType"]:checked');
        const dm = document.querySelector('input[name="deploymentMode"]:checked');
        const cds = document.querySelector('input[name="hasCDS"]:checked');
        if (!tt) { alert('Select a terminal type.'); return; }
        state.progress.meta = state.progress.meta || {};
        state.progress.meta.terminalType = tt.value;
        if (tt.value === 'POS') {
            state.progress.meta.deploymentMode = dm ? dm.value : 'chrome';
            state.progress.meta.hasCDS = cds ? (cds.value === 'yes') : false;
        } else {
            state.progress.meta.deploymentMode = 'chrome';
            state.progress.meta.hasCDS = false;
        }
        setStepStatus('oolio', 'terminal-type', 'complete');
        // In migrate mode, advance the loop; in module mode, just re-render.
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
                const extra = {};
                if (stepId === 'rename-device') {
                    extra.value = state.inputValues[key + '.value'] || '';
                } else if (stepId === 'set-startup') {
                    extra.value = (getMeta().terminalType || '');
                } else if (stepId === 'verify-autologon') {
                    extra.username = state.inputValues[key + '.username'] || '';
                    extra.password = state.inputValues[key + '.password'] || '';
                    extra.domain   = state.inputValues[key + '.domain']   || '';
                }
                runStep(moduleId, stepId, extra);
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
            }
        });
    });

    const chain = document.getElementById('bepoz-chain');
    if (chain) chain.addEventListener('click', runBepozSafeChain);
    const dchain = document.getElementById('deps-chain');
    if (dchain) dchain.addEventListener('click', runDepsCheckChain);

    const save = document.getElementById('config-save');
    if (save) save.addEventListener('click', () => {
        const tt = document.querySelector('input[name="terminalType"]:checked');
        const dm = document.querySelector('input[name="deploymentMode"]:checked');
        const cds = document.querySelector('input[name="hasCDS"]:checked');
        if (!tt) { alert('Select a terminal type.'); return; }
        state.progress.meta = state.progress.meta || {};
        state.progress.meta.terminalType = tt.value;
        if (tt.value === 'POS') {
            state.progress.meta.deploymentMode = dm ? dm.value : 'chrome';
            state.progress.meta.hasCDS = cds ? (cds.value === 'yes') : false;
        } else {
            state.progress.meta.deploymentMode = 'chrome';
            state.progress.meta.hasCDS = false;
        }
        setStepStatus('oolio', 'terminal-type', 'complete');
        render();
    });
}
