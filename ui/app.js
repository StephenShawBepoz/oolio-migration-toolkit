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
            { id: 'kill-processes',  title: 'Terminate Bepoz processes', risk: 'safe', note: 'Force-stops any running Bepoz/Backoffice processes.' },
            { id: 'clear-startup',   title: 'Clear shell:startup',   risk: 'warn',   note: 'Removes everything from the user shell:startup folder. POS terminal only.' },
            { id: 'check-run-key',   title: 'Clean HKCU Run key',    risk: 'warn',   note: 'Lists current entries and removes known Bepoz Run keys.' },
            { id: 'delete-registry', title: 'Delete Bepoz registry', risk: 'danger', note: 'Removes HKCU\\Software\\Backoffice. Make sure the data backup zip exists first.' },
            { id: 'uninstall',       title: 'Uninstall Bepoz programs', risk: 'danger', note: 'Optional. Calls Win32_Product uninstall for any program containing "Bepoz".' }
        ]
    },
    {
        id: 'windows',
        name: 'Windows Settings',
        icon: '2',
        description: 'Verify autologon, firewall, network, then rename and clean the device.',
        steps: [
            { id: 'verify-autologon', title: 'Verify autologon',  risk: 'safe', note: 'Reads Winlogon registry to confirm the terminal will boot directly to its user.' },
            { id: 'enable-firewall',  title: 'Enable Windows Firewall', risk: 'warn', note: 'Enables firewall for Domain, Private, and Public profiles.' },
            { id: 'check-ip',         title: 'Check IP configuration', risk: 'safe', note: 'Shows current IP and DHCP status for active adapters.' },
            { id: 'switch-dhcp',      title: 'Switch to DHCP',     risk: 'warn', note: 'Switches static-IP adapters to DHCP. Skips silently if already DHCP.' },
            { id: 'rename-device',    title: 'Rename device',      risk: 'warn', requiresInput: true, inputLabel: 'Suffix (after "Oolio-")', inputPlaceholder: 'POS1', note: 'Renames the device to Oolio-<suffix>. Effective after the final restart.' },
            { id: 'clean-desktop',    title: 'Clean desktop',      risk: 'warn', note: 'Removes everything from user and public desktop. POS terminal only.' },
            { id: 'set-wallpaper',    title: 'Apply Oolio wallpaper', risk: 'safe', note: 'Copies assets/wallpaper.jpg to C:\\Oolio\\Assets and applies it. Drop wallpaper.jpg into the toolkit assets\\ folder before running.' }
        ]
    },
    {
        id: 'dependencies',
        name: 'Oolio Dependencies',
        icon: '3',
        description: 'Verify Chrome and WebView2, install printer certs and utility links.',
        steps: [
            { id: 'check-chrome',      title: 'Check Google Chrome', risk: 'safe', note: 'Reports Chrome install path and version. Opens download page if missing.' },
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
            },
            { id: 'install-certs',     title: 'Install Epson printer certs', risk: 'warn', note: 'Installs every .cer file in the certs\\ folder into the Root store. Drop .cer files into the toolkit certs\\ folder first. Epson only.' }
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
            { id: 'set-startup',        title: 'Configure startup',          risk: 'warn', note: 'Adds an HKCU Run key entry so Oolio launches on boot.' },
            { id: 'final-restart',      title: 'Schedule final restart',     risk: 'warn', note: 'Schedules a 30-second restart. Run "shutdown /a" to cancel.' }
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
    confirmTicked: {}
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

// ---------- SSE step runner ----------

function runStep(moduleId, stepId, inputValue) {
    const key = moduleId + '.' + stepId;
    state.runningStep = key;
    state.outputLog[key] = [];
    setStepStatus(moduleId, stepId, 'running');
    render();

    let url = `/run?module=${encodeURIComponent(moduleId)}&step=${encodeURIComponent(stepId)}`;
    if (inputValue) url += `&value=${encodeURIComponent(inputValue)}`;

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
    const cards = MODULES.map(mod => {
        const p = getModuleProgress(mod);
        const pct = p.total === 0 ? 0 : Math.round((p.done / p.total) * 100);
        const isComplete = p.total > 0 && p.done === p.total;
        return `
          <div class="module-card" data-module="${mod.id}">
            <div class="module-card-head">
              <div class="module-icon">${mod.icon}</div>
              ${isComplete ? '<span class="complete-badge">COMPLETE</span>' : ''}
            </div>
            <div class="module-name">${escapeHtml(mod.name)}</div>
            <div class="module-desc">${escapeHtml(mod.description)}</div>
            <div class="module-progress-text">${p.done} of ${p.total} steps</div>
            <div class="progress-track"><div class="progress-fill" style="width:${pct}%"></div></div>
          </div>`;
    }).join('');

    return `
      <div class="app-header">
        <div class="app-title">
          <div class="app-title-dot"></div>
          <div>Oolio Migration Toolkit</div>
        </div>
      </div>
      ${renderOverallProgress()}
      <div class="module-grid">${cards}</div>
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
            const inputVal = state.inputValues[key] || '';
            const isDanger = step.risk === 'danger';
            const confirmed = state.confirmTicked[key] === true;
            const hasInput = step.requiresInput;
            const inputOk = !hasInput || (inputVal && inputVal.trim().length > 0);
            const runDisabled = isRunning || (isDanger && !confirmed) || !inputOk;

            const linksHtml = step.links ? `
              <ul class="links-list">
                ${step.links.map(l => `<li><a href="${escapeHtml(l.href)}" target="_blank" rel="noopener">${escapeHtml(l.label)}</a></li>`).join('')}
              </ul>` : '';

            const inputHtml = hasInput ? `
              <div class="step-input-row">
                ${step.id === 'rename-device' ? '<span class="step-input-prefix">Oolio-</span>' : ''}
                <input type="text" data-step-input="${key}" value="${escapeHtml(inputVal)}" placeholder="${escapeHtml(step.inputPlaceholder || '')}" />
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
    } else {
        app.innerHTML = renderModule();
        attachModuleHandlers();
    }
}

// ---------- Event handlers ----------

function attachHomeHandlers() {
    document.querySelectorAll('.module-card').forEach(card => {
        card.addEventListener('click', () => {
            state.activeModule = card.dataset.module;
            state.view = 'module';
            render();
        });
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
                let value = null;
                if (stepId === 'rename-device') value = state.inputValues[key] || '';
                else if (stepId === 'set-startup') value = (getMeta().terminalType || '');
                runStep(moduleId, stepId, value);
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
