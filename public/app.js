// ============================================================
// SPD → K2 Five Migration Pipeline — Frontend Application
// Tab navigation, CSV upload, analysis dashboard, detail panel
// ============================================================

const API = '';

// ── State ───────────────────────────────────────────────────

let connections = [];
let inventory = null;
let analysisData = null;
let currentPage = 1;
let complexityChart = null;

// ── Tab Navigation ──────────────────────────────────────────

document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        const tab = btn.dataset.tab;
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
        btn.classList.add('active');
        document.getElementById(`panel-${tab}`).classList.add('active');

        if (tab === 'environment') loadEnvironment();
        if (tab === 'smartobjects') loadSmartObjects();
        if (tab === 'smartforms') loadSmartForms();
        if (tab === 'blueprints') loadBlueprints();
        if (tab === 'cutover') { loadChecklist(); }
    });
});

// ── Toast Notifications ─────────────────────────────────────

function showToast(message, type = 'info') {
    const container = document.getElementById('toast-container');
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
    container.appendChild(toast);
    setTimeout(() => toast.remove(), 4000);
}

// ── Connection Management ───────────────────────────────────

document.getElementById('form-connection').addEventListener('submit', async (e) => {
    e.preventDefault();
    const payload = {
        name: document.getElementById('conn-name').value,
        siteUrl: document.getElementById('conn-url').value,
        spVersion: document.getElementById('conn-sp-version').value,
        authType: document.getElementById('conn-auth').value,
        credentialLabel: document.getElementById('conn-cred').value,
        notes: document.getElementById('conn-notes').value
    };

    try {
        const res = await fetch(`${API}/api/connections`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        const data = await res.json();
        if (data.success) {
            showToast('Connection saved', 'success');
            document.getElementById('form-connection').reset();
            loadConnections();
        }
    } catch (err) {
        showToast('Failed to save connection', 'error');
    }
});

async function loadConnections() {
    try {
        const res = await fetch(`${API}/api/connections`);
        const data = await res.json();
        connections = data.connections || [];
        renderConnections();
    } catch (err) {
        console.error('Failed to load connections:', err);
    }
}

function renderConnections() {
    const list = document.getElementById('connection-list');
    if (connections.length === 0) {
        list.innerHTML = `
            <div class="empty-state">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>
                <h3>No connections configured</h3>
                <p>Add your SharePoint site connections to begin.</p>
            </div>`;
        return;
    }

    list.innerHTML = connections.map(c => `
        <div class="conn-item">
            <div class="conn-info">
                <div class="conn-icon">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/></svg>
                </div>
                <div>
                    <div class="conn-name">${esc(c.name)}</div>
                    <div class="conn-url">${esc(c.siteUrl)} &nbsp;·&nbsp; ${esc(c.spVersion)} &nbsp;·&nbsp; ${esc(c.authType)}</div>
                </div>
            </div>
            <div class="conn-actions">
                <span class="badge badge-${c.status === 'connected' ? 'simple' : 'medium'}">${c.status}</span>
                <button class="btn btn-outline btn-sm" onclick="testConnection('${c.id}')">Test</button>
                <button class="btn btn-danger btn-sm" onclick="deleteConnection('${c.id}')">Remove</button>
            </div>
        </div>
    `).join('');
}

async function testConnection(id) {
    try {
        showToast('Testing connection...', 'info');
        const res = await fetch(`${API}/api/connections/${id}/test`, { method: 'POST' });
        const data = await res.json();
        if (data.success) {
            showToast('Connection reachable ✓', 'success');
            loadConnections();
        }
    } catch (err) {
        showToast('Connection test failed', 'error');
    }
}

async function deleteConnection(id) {
    try {
        await fetch(`${API}/api/connections/${id}`, { method: 'DELETE' });
        showToast('Connection removed', 'info');
        loadConnections();
    } catch (err) {
        showToast('Failed to remove', 'error');
    }
}

// ── SP List Schema Upload ──────────────────────────────────

document.getElementById('schema-file-input').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    if (!file) return;

    const statusEl = document.getElementById('schema-upload-status');
    statusEl.textContent = 'Uploading...';

    try {
        const formData = new FormData();
        formData.append('schemaJson', file);

        const res = await fetch(`${API}/api/discovery/upload-schema`, { method: 'POST', body: formData });
        const data = await res.json();

        if (data.success) {
            const s = data.summary;
            statusEl.textContent = `✓ ${s.listCount} lists, ${s.totalFields} fields from ${s.siteTitle}`;

            const badge = document.getElementById('schema-status-badge');
            badge.textContent = 'loaded';
            badge.style.background = 'var(--accent-emerald)';
            badge.style.color = '#fff';

            let html = `<table class="data-table"><thead><tr><th>List</th><th>Fields</th><th>Items</th></tr></thead><tbody>`;
            s.lists.forEach(l => {
                html += `<tr><td style="font-weight:500;">${esc(l.listTitle)}</td><td>${l.fieldCount}</td><td>${l.itemCount}</td></tr>`;
            });
            html += '</tbody></table>';
            document.getElementById('schema-summary').style.display = 'block';
            document.getElementById('schema-summary').innerHTML = html;

            showToast(`Real schema loaded: ${s.listCount} lists, ${s.totalFields} fields`, 'success');
        } else {
            statusEl.textContent = '✗ ' + (data.error || 'Upload failed');
            showToast(data.error || 'Schema upload failed', 'error');
        }
    } catch (err) {
        statusEl.textContent = '✗ Error: ' + err.message;
        showToast('Schema upload error', 'error');
    }
});

// ── CSV Upload (Discovery) ──────────────────────────────────

const uploadZone = document.getElementById('upload-zone');
const fileInput = document.getElementById('csv-file-input');

uploadZone.addEventListener('click', () => fileInput.click());

uploadZone.addEventListener('dragover', (e) => {
    e.preventDefault();
    uploadZone.classList.add('dragover');
});

uploadZone.addEventListener('dragleave', () => {
    uploadZone.classList.remove('dragover');
});

uploadZone.addEventListener('drop', (e) => {
    e.preventDefault();
    uploadZone.classList.remove('dragover');
    handleFiles(e.dataTransfer.files);
});

fileInput.addEventListener('change', () => {
    handleFiles(fileInput.files);
    fileInput.value = '';
});

async function handleFiles(files) {
    if (!files.length) return;

    const formData = new FormData();
    let hasWorkflow = false, hasInfoPath = false;

    for (const file of files) {
        const name = file.name.toLowerCase();
        if (name.includes('workflow')) {
            formData.append('workflowCsv', file);
            hasWorkflow = true;
        } else if (name.includes('infopath')) {
            formData.append('infopathCsv', file);
            hasInfoPath = true;
        } else {
            // Auto-detect: try workflow first
            formData.append('workflowCsv', file);
            hasWorkflow = true;
        }
    }

    const progressContainer = document.getElementById('upload-progress-container');
    const progressBar = document.getElementById('upload-progress-bar');
    const status = document.getElementById('upload-status');

    progressContainer.style.display = 'block';
    progressBar.style.width = '10%';
    status.textContent = 'Uploading files...';

    try {
        progressBar.style.width = '30%';
        status.textContent = 'Parsing CSV data...';

        const res = await fetch(`${API}/api/discovery/upload`, {
            method: 'POST',
            body: formData
        });
        const data = await res.json();

        progressBar.style.width = '80%';

        if (data.success) {
            const results = data.results;
            let msg = '';
            if (results.workflow) msg += `${results.workflow.imported} workflows imported. `;
            if (results.infopath) msg += `${results.infopath.imported} forms imported. `;
            status.textContent = msg;

            progressBar.style.width = '100%';
            showToast('Discovery data imported ✓', 'success');

            // Refresh inventory
            await loadInventory();
        } else {
            status.textContent = `Error: ${data.error}`;
            showToast('Import failed', 'error');
        }
    } catch (err) {
        status.textContent = `Upload error: ${err.message}`;
        showToast('Upload failed', 'error');
    }

    setTimeout(() => {
        progressContainer.style.display = 'none';
        progressBar.style.width = '0%';
    }, 2000);
}

async function loadInventory() {
    try {
        const [invRes, sitesRes] = await Promise.all([
            fetch(`${API}/api/discovery/inventory`),
            fetch(`${API}/api/discovery/sites`)
        ]);

        inventory = await invRes.json();
        const sitesData = await sitesRes.json();

        // Update badges
        document.getElementById('badge-discovery').textContent = inventory.totalArtifacts || 0;

        // Show import summary
        const summary = document.getElementById('import-summary');
        summary.style.display = 'flex';
        document.getElementById('import-wf-count').textContent = inventory.totalWorkflows;
        document.getElementById('import-form-count').textContent = inventory.totalForms;
        document.getElementById('import-site-count').textContent = inventory.totalSites;

        // Enable analysis
        document.getElementById('btn-run-analysis').disabled = inventory.totalArtifacts === 0;

        // Render site tree
        renderSiteTree(sitesData.sites);
        renderInventoryTable();
    } catch (err) {
        console.error('Failed to load inventory:', err);
    }
}

function renderSiteTree(sites) {
    const container = document.getElementById('site-tree-container');
    if (!sites || Object.keys(sites).length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:2rem;"><p>Import CSVs to see discovered sites</p></div>';
        return;
    }

    let html = '';
    for (const [rootUrl, root] of Object.entries(sites)) {
        html += `<div class="site-tree-root">
            <div class="tree-node">
                <div class="tree-node-label">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/></svg>
                    <strong>${esc(rootUrl)}</strong>
                </div>
                <span class="tree-count">${root.workflows} WF · ${root.forms} IP</span>
            </div>
            <div class="tree-children">`;

        for (const [childUrl, child] of Object.entries(root.children)) {
            html += `<div class="tree-node">
                <div class="tree-node-label">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>
                    ${esc(child.title || child.path)}
                </div>
                <span class="tree-count">${child.workflows} WF · ${child.forms} IP</span>
            </div>`;
        }

        html += `</div></div>`;
    }
    container.innerHTML = html;
}

function renderInventoryTable() {
    if (!inventory || inventory.totalArtifacts === 0) return;

    const container = document.getElementById('inventory-container');
    let html = `<table class="data-table">
        <thead><tr>
            <th>Site</th><th>Type</th><th>Count</th>
        </tr></thead><tbody>`;

    (inventory.siteBreakdown || []).slice(0, 30).forEach(s => {
        html += `<tr>
            <td style="color:var(--text-primary); font-weight:500; max-width:300px; overflow:hidden; text-overflow:ellipsis;">${esc(s.title || s.url)}</td>
            <td><span class="badge badge-workflow">WF: ${s.workflows}</span> <span class="badge badge-form">IP: ${s.forms}</span></td>
            <td>${s.workflows + s.forms}</td>
        </tr>`;
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

async function resetDiscovery() {
    try {
        await fetch(`${API}/api/discovery/reset`, { method: 'POST' });
        inventory = null;
        document.getElementById('import-summary').style.display = 'none';
        document.getElementById('upload-status').textContent = '';
        document.getElementById('badge-discovery').textContent = '0';
        document.getElementById('site-tree-container').innerHTML = '<div class="empty-state" style="padding:2rem;"><p>Import CSVs to see discovered sites</p></div>';
        document.getElementById('inventory-container').innerHTML = '<div class="empty-state" style="padding:2rem;"><p>No artifacts imported yet</p></div>';
        document.getElementById('btn-run-analysis').disabled = true;
        showToast('Discovery data cleared', 'info');
    } catch (err) {
        showToast('Failed to clear data', 'error');
    }
}

// ── Analysis ────────────────────────────────────────────────

async function runAnalysis() {
    try {
        showToast('Running complexity analysis...', 'info');
        const res = await fetch(`${API}/api/analysis/run`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`Analysis complete: ${data.summary.totalAnalyzed} items scored`, 'success');
            document.getElementById('badge-analysis').textContent = data.summary.totalAnalyzed;

            // Switch to analysis tab
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
            document.getElementById('tab-analysis').classList.add('active');
            document.getElementById('panel-analysis').classList.add('active');

            await loadAnalysisDashboard();
        }
    } catch (err) {
        showToast('Analysis failed: ' + err.message, 'error');
    }
}

async function loadAnalysisDashboard() {
    try {
        const [reportRes, portfolioRes] = await Promise.all([
            fetch(`${API}/api/analysis/report`),
            fetch(`${API}/api/analysis/portfolio`)
        ]);

        const report = await reportRes.json();
        const portfolio = await portfolioRes.json();

        document.getElementById('analysis-empty').style.display = 'none';
        document.getElementById('analysis-dashboard').style.display = 'block';

        renderAnalysisStats(report, portfolio);
        renderComplexityChart(portfolio.complexityDistribution);
        renderAutomationGauges();

        filterResults();
    } catch (err) {
        console.error('Dashboard load error:', err);
    }
}

function renderAnalysisStats(report, portfolio) {
    const s = report.summary;
    const d = portfolio.complexityDistribution;
    document.getElementById('analysis-stats').innerHTML = `
        <div class="stat-tile"><div class="stat-label">Total Artifacts</div><div class="stat-value cyan">${s.totalArtifacts.toLocaleString()}</div><div class="stat-sub">${s.totalWorkflows} workflows · ${s.totalForms} forms</div></div>
        <div class="stat-tile"><div class="stat-label">Simple</div><div class="stat-value emerald">${d.simple.toLocaleString()}</div><div class="stat-sub">${d.simplePct}% of portfolio</div></div>
        <div class="stat-tile"><div class="stat-label">Medium</div><div class="stat-value" style="color:var(--accent-blue)">${d.medium.toLocaleString()}</div><div class="stat-sub">${d.mediumPct}% of portfolio</div></div>
        <div class="stat-tile"><div class="stat-label">Complex</div><div class="stat-value amber">${d.complex.toLocaleString()}</div><div class="stat-sub">${d.complexPct}% of portfolio</div></div>
        <div class="stat-tile"><div class="stat-label">Critical</div><div class="stat-value red">${d.critical.toLocaleString()}</div><div class="stat-sub">${d.criticalPct}% of portfolio</div></div>

    `;
}

function renderComplexityChart(dist) {
    const ctx = document.getElementById('chart-complexity');
    if (complexityChart) complexityChart.destroy();

    complexityChart = new Chart(ctx, {
        type: 'doughnut',
        data: {
            labels: ['Simple', 'Medium', 'Complex', 'Critical'],
            datasets: [{
                data: [dist.simple, dist.medium, dist.complex, dist.critical],
                backgroundColor: ['#10b981', '#3b82f6', '#f59e0b', '#ef4444'],
                borderColor: 'transparent',
                borderWidth: 0,
                hoverOffset: 8
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: '62%',
            plugins: {
                legend: {
                    position: 'bottom',
                    labels: { color: '#94a3b8', padding: 16, font: { family: 'Inter', size: 12 }, usePointStyle: true, pointStyleWidth: 12 }
                }
            }
        }
    });
}

function renderAutomationGauges() {
    const gauges = [
        { label: 'SmartObjects', pct: 95, note: 'Data layer — SourceCode.SmartObjects.Authoring API' },
        { label: 'SmartForms', pct: 75, note: 'UI layer — FormGenerator + manual rules' },
        { label: 'Workflows', pct: 0, note: '⚠ No public API — K2 Designer only' },
        { label: 'Data Migration', pct: 90, note: 'SmartObject CRUD via REST/OData' },
        { label: 'Permissions', pct: 40, note: 'K2 role system differs from SP' },
        { label: 'Packaging', pct: 50, note: '.kspx creation manual; deploy via PS' }
    ];

    const container = document.getElementById('automation-gauges');
    container.innerHTML = gauges.map(g => {
        const r = 34;
        const circ = 2 * Math.PI * r;
        const offset = circ - (g.pct / 100) * circ;
        const cls = g.pct >= 70 ? 'high' : g.pct >= 30 ? 'medium' : g.pct === 0 ? 'zero' : 'low';
        const valColor = g.pct >= 70 ? 'var(--accent-emerald)' : g.pct >= 30 ? 'var(--accent-amber)' : 'var(--accent-red)';

        return `<div class="gauge-item">
            <div class="gauge-circle">
                <svg viewBox="0 0 80 80">
                    <circle class="gauge-bg" cx="40" cy="40" r="${r}"/>
                    <circle class="gauge-fill ${cls}" cx="40" cy="40" r="${r}"
                        stroke-dasharray="${circ}" stroke-dashoffset="${offset}"
                        stroke-linecap="round"/>
                </svg>
                <div class="gauge-value" style="color:${valColor}">${g.pct}%</div>
            </div>
            <div class="gauge-label">${g.label}</div>
            <div class="gauge-note">${g.note}</div>
        </div>`;
    }).join('');
}



async function filterResults() {
    const search = document.getElementById('filter-search').value;
    const assetType = document.getElementById('filter-type').value;
    const complexity = document.getElementById('filter-complexity').value;

    try {
        const params = new URLSearchParams({
            search, assetType, complexity, page: currentPage, pageSize: 50
        });
        const res = await fetch(`${API}/api/analysis/results?${params}`);
        const data = await res.json();
        renderResultsTable(data);
    } catch (err) {
        console.error('Filter error:', err);
    }
}

function renderResultsTable(data) {
    const container = document.getElementById('results-table-container');
    if (!data.items || data.items.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:2rem;"><p>No matching items</p></div>';
        return;
    }

    let html = `<table class="data-table">
        <thead><tr>
            <th>Name</th><th>Type</th><th>Site</th><th>Complexity</th><th>Score</th><th>Actions</th>
        </tr></thead><tbody>`;

    data.items.forEach(item => {
        const name = item.name || item.workflowName || item.formName || 'Unnamed';
        html += `<tr>
            <td style="color:var(--text-primary); font-weight:500;">${esc(name)}</td>
            <td><span class="badge badge-${item.assetType}">${item.assetType}</span></td>
            <td style="max-width:200px; overflow:hidden; text-overflow:ellipsis;">${esc(item.webUrl || '')}</td>
            <td><span class="badge badge-${item.complexity}">${item.complexity}</span></td>
            <td style="font-weight:600;">${item.complexityScore}</td>
            <td><button class="btn btn-outline btn-sm" onclick="showDetail('${item.id}')">Detail</button></td>
        </tr>`;
    });

    html += '</tbody></table>';
    container.innerHTML = html;

    // Pagination
    const pag = document.getElementById('results-pagination');
    if (data.totalPages > 1) {
        let pagHtml = '';
        for (let i = 1; i <= Math.min(data.totalPages, 10); i++) {
            pagHtml += `<button class="btn btn-sm ${i === data.page ? 'btn-primary' : 'btn-outline'}" onclick="goToPage(${i})">${i}</button>`;
        }
        if (data.totalPages > 10) pagHtml += `<span style="color:var(--text-muted); font-size:0.8rem;">... of ${data.totalPages}</span>`;
        pag.innerHTML = pagHtml;
    } else {
        pag.innerHTML = '';
    }
}

function goToPage(page) {
    currentPage = page;
    filterResults();
}

// ── Detail Panel ────────────────────────────────────────────

async function showDetail(id) {
    try {
        const res = await fetch(`${API}/api/analysis/item/${id}`);
        const item = await res.json();

        document.getElementById('detail-title').textContent = item.name || 'Item Detail';
        document.getElementById('detail-subtitle').textContent = `${item.assetType} · ${item.complexity} · Score: ${item.complexityScore}`;

        let html = '';

        // Overview
        html += `<div class="detail-section">
            <div class="detail-section-title">Overview</div>
            <div class="env-detail"><span class="env-detail-label">Type</span><span class="badge badge-${item.assetType}">${item.assetType}</span></div>
            <div class="env-detail"><span class="env-detail-label">Site</span><span class="env-detail-value">${esc(item.webUrl || '')}</span></div>
            <div class="env-detail"><span class="env-detail-label">List</span><span class="env-detail-value">${esc(item.listTitle || '')}</span></div>
            <div class="env-detail"><span class="env-detail-label">Complexity</span><span class="badge badge-${item.complexity}">${item.complexity} (${item.complexityScore})</span></div>
        </div>`;

        // Effort estimate
        if (item.effortEstimate) {
            const e = item.effortEstimate;
            html += `<div class="detail-section">
                <div class="detail-section-title">Effort Estimate</div>
                <div class="env-detail"><span class="env-detail-label">Traditional</span><span class="env-detail-value">${e.traditionalHours} hrs</span></div>
                <div class="env-detail"><span class="env-detail-label">With Automation</span><span class="env-detail-value" style="color:var(--accent-emerald);">${e.automatedHours} hrs</span></div>
                <div class="env-detail"><span class="env-detail-label">Savings</span><span class="env-detail-value" style="color:var(--accent-cyan);">${e.savingsPercent}%</span></div>
            </div>`;
        }

        // Complexity factors
        if (item.complexityFactors && item.complexityFactors.length) {
            html += `<div class="detail-section">
                <div class="detail-section-title">Complexity Factors</div>
                <div class="factor-list">`;
            item.complexityFactors.forEach(f => {
                html += `<div class="factor-item">
                    <span class="factor-label">${esc(f.label)}</span>
                    <span class="factor-weight">+${f.weight}</span>
                </div>`;
            });
            html += `</div></div>`;
        }

        // K2 Field Mappings (forms)
        if (item.k2FieldMappings && item.k2FieldMappings.length) {
            html += `<div class="detail-section">
                <div class="detail-section-title">K2 SmartObject / SmartForm Mapping</div>
                <table class="data-table">
                    <thead><tr><th>SP Field</th><th>SmartObject</th><th>SmartForm</th><th>Map</th></tr></thead>
                    <tbody>`;
            item.k2FieldMappings.forEach(m => {
                html += `<tr>
                    <td>${esc(m.spFieldType)}</td>
                    <td>${esc(m.smartObjectProperty)}</td>
                    <td>${esc(m.smartFormControl)}</td>
                    <td><span class="badge badge-${m.autoMap}">${m.autoMap}</span></td>
                </tr>`;
            });
            html += '</tbody></table></div>';
        }

        // K2 Activity Mappings (workflows)
        if (item.k2ActivityMappings && item.k2ActivityMappings.length) {
            html += `<div class="detail-section">
                <div class="detail-section-title">K2 Activity Blueprint</div>
                <table class="data-table">
                    <thead><tr><th>SPD Action</th><th>K2 Activity</th><th>Blueprint Output</th></tr></thead>
                    <tbody>`;
            item.k2ActivityMappings.forEach(m => {
                html += `<tr>
                    <td>${esc(m.spdAction)}</td>
                    <td>${esc(m.k2Activity)}</td>
                    <td style="font-size:0.75rem;">${esc(m.blueprintOutput)}</td>
                </tr>`;
            });
            html += '</tbody></table></div>';
        }

        document.getElementById('detail-body').innerHTML = html;
        document.getElementById('detail-panel').classList.add('open');
        document.getElementById('detail-overlay').classList.add('open');
    } catch (err) {
        showToast('Failed to load item detail', 'error');
    }
}

function closeDetail() {
    document.getElementById('detail-panel').classList.remove('open');
    document.getElementById('detail-overlay').classList.remove('open');
}

// ── Environment Tab ─────────────────────────────────────────

async function loadEnvironment() {
    try {
        const [envRes, mapRes] = await Promise.all([
            fetch(`${API}/api/environment`),
            fetch(`${API}/api/analysis/k2-mappings`)
        ]);

        const env = await envRes.json();
        const maps = await mapRes.json();

        // Env info cards
        document.getElementById('env-info').innerHTML = `
            <div class="env-card">
                <div class="env-card-title">Source — SharePoint</div>
                <div class="env-detail"><span class="env-detail-label">Platform</span><span class="env-detail-value">${env.source.platform}</span></div>
                <div class="env-detail"><span class="env-detail-label">Version</span><span class="env-detail-value">${env.source.version}</span></div>
                <div class="env-detail"><span class="env-detail-label">CU</span><span class="env-detail-value">${env.source.cu}</span></div>
                <div class="env-detail"><span class="env-detail-label">SQL</span><span class="env-detail-value">${env.source.sql.version}</span></div>
                <div class="env-detail"><span class="env-detail-label">Database</span><span class="env-detail-value">${env.source.sql.database}</span></div>
                <div class="env-detail"><span class="env-detail-label">Listener</span><span class="env-detail-value">${env.source.sql.listener}</span></div>
                <div class="env-detail"><span class="env-detail-label">AG</span><span class="env-detail-value">${env.source.sql.ag}</span></div>
            </div>
            <div class="env-card">
                <div class="env-card-title">Target — K2 Five</div>
                <div class="env-detail"><span class="env-detail-label">Platform</span><span class="env-detail-value">${env.target.platform}</span></div>
                <div class="env-detail"><span class="env-detail-label">Version</span><span class="env-detail-value">${env.target.version} ${env.target.featurePack}</span></div>
                <div class="env-detail"><span class="env-detail-label">Build</span><span class="env-detail-value">${env.target.build}</span></div>
                <div class="env-detail"><span class="env-detail-label">Server OS</span><span class="env-detail-value">${env.target.server}</span></div>
            </div>
        `;

        // SmartObject mapping table
        renderMappingTable('smartobject-map-table', maps.smartObjectMap, [
            { key: 'propertyType', header: 'SmartObject Property' },
            { key: 'systemName', header: 'System Type' },
            { key: 'autoMap', header: 'Auto-Map' },
            { key: 'notes', header: 'Notes' }
        ]);

        // SmartForm mapping table
        renderMappingTable('smartform-map-table', maps.smartFormMap, [
            { key: 'control', header: 'SmartForm Control' },
            { key: 'controlType', header: 'Control Type ID' },
            { key: 'autoMap', header: 'Auto-Map' }
        ]);

        // Activity mapping table
        renderMappingTable('activity-map-table', maps.activityMap, [
            { key: 'k2Activity', header: 'K2 Activity' },
            { key: 'blueprint', header: 'Blueprint Output' },
            { key: 'automatable', header: 'Automatable' }
        ]);

        // Farm topology
        renderFarmTopology(env.source.farmTopology);

    } catch (err) {
        console.error('Env load error:', err);
    }
}

function renderMappingTable(containerId, map, columns) {
    let html = `<table class="data-table"><thead><tr><th>SP Type</th>`;
    columns.forEach(c => { html += `<th>${c.header}</th>`; });
    html += '</tr></thead><tbody>';

    for (const [spType, mapping] of Object.entries(map)) {
        html += `<tr><td style="color:var(--text-primary); font-weight:500;">${esc(spType)}</td>`;
        columns.forEach(c => {
            const val = mapping[c.key];
            if (c.key === 'autoMap') {
                html += `<td><span class="badge badge-${val}">${val}</span></td>`;
            } else if (c.key === 'automatable') {
                html += `<td>${val ? '<span class="badge badge-simple">Yes</span>' : '<span class="badge badge-critical">Manual</span>'}</td>`;
            } else {
                html += `<td>${esc(String(val || '—'))}</td>`;
            }
        });
        html += '</tr>';
    }

    html += '</tbody></table>';
    document.getElementById(containerId).innerHTML = html;
}

function renderFarmTopology(topology) {
    const container = document.getElementById('farm-topology');
    let html = `<table class="data-table">
        <thead><tr><th>Role</th><th>Services</th><th>.NET Framework</th></tr></thead><tbody>`;

    for (const [key, server] of Object.entries(topology)) {
        html += `<tr>
            <td style="font-weight:600; color:var(--accent-cyan);">${esc(server.role)}</td>
            <td style="font-size:0.75rem; line-height:1.6;">${server.services.map(s => esc(s)).join('<br>')}</td>
            <td>${esc(server.dotnet)}</td>
        </tr>`;
    }

    html += '</tbody></table>';
    container.innerHTML = html;
}

// ── Phase 3: SmartObjects ─────────────────────────────────────────

let selectedSOId = null;
let previewXmlContent = '';
let previewSqlContent = '';

async function configureK2() {
    const serverUrl = document.getElementById('k2-server-url').value;
    const port = parseInt(document.getElementById('k2-server-port').value) || 5555;
    const securityLabel = document.getElementById('k2-security-label').value || 'K2';
    const brokerTypeEl = document.getElementById('k2-broker-type');
    const brokerType = brokerTypeEl ? brokerTypeEl.value : 'SmartBox';

    if (!serverUrl) { showToast('K2 server URL is required', 'error'); return; }

    try {
        const res = await fetch(`${API}/api/k2/configure`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ serverUrl, port, securityLabel, brokerType })
        });
        const data = await res.json();
        if (data.success) {
            showToast(`K2 server configured ✓ (${brokerType} broker)`, 'success');
            updateK2Status();
        }
    } catch (err) {
        showToast('Failed to configure K2', 'error');
    }
}

async function testK2() {
    showToast('Testing K2 connection...', 'info');
    const statusEl = document.getElementById('k2-connection-status');
    statusEl.innerHTML = '<div class="spinner" style="display:inline-block;"></div> Testing...';

    try {
        const res = await fetch(`${API}/api/k2/test`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            const info = data.serverInfo;
            statusEl.innerHTML = `
                <div style="color:var(--accent-emerald); font-weight:600; margin-bottom:4px;">✓ Connected</div>
                <div class="env-detail"><span class="env-detail-label">Version</span><span class="env-detail-value">${esc(info.serverVersion)}</span></div>
                <div class="env-detail"><span class="env-detail-label">Build</span><span class="env-detail-value">${esc(info.build)}</span></div>
                <div class="env-detail"><span class="env-detail-label">Database</span><span class="env-detail-value">${esc(info.database)}</span></div>
                <div class="env-detail"><span class="env-detail-label">Listener</span><span class="env-detail-value">${esc(info.listener)}</span></div>
                <div class="env-detail"><span class="env-detail-label">AG</span><span class="env-detail-value">${esc(info.ag)}</span></div>
            `;
            showToast('K2 server connected ✓', 'success');
        } else {
            statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${esc(data.error)}</span>`;
            showToast('K2 connection failed', 'error');
        }
    } catch (err) {
        statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${err.message}</span>`;
        showToast('K2 connection failed', 'error');
    }
}

async function updateK2Status() {
    try {
        const res = await fetch(`${API}/api/k2/connection`);
        const data = await res.json();
        const statusEl = document.getElementById('k2-connection-status');

        if (data.isConnected && data.details) {
            statusEl.innerHTML = `<span style="color:var(--accent-emerald);">✓ Connected to ${esc(data.config.serverUrl)}</span>`;
        } else {
            statusEl.innerHTML = `<span style="color:var(--text-muted);">Not connected — configure and test the K2 server</span>`;
        }
    } catch (err) { /* ignore */ }
}

async function generateSmartObjects() {
    try {
        showToast('Generating SmartObject definitions...', 'info');
        const res = await fetch(`${API}/api/smartobjects/generate`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`Generated ${data.summary.generated} SmartObjects with ${data.summary.totalProperties} properties`, 'success');
            document.getElementById('badge-smartobjects').textContent = data.summary.generated;
            await loadSmartObjects();
        } else {
            showToast(data.error || 'Generation failed', 'error');
        }
    } catch (err) {
        showToast('Generation failed: ' + err.message, 'error');
    }
}

async function discoverFromK2() {
    showToast('Discovering existing SmartObjects from K2 SP2013 Broker...', 'info');
    const btn = document.getElementById('btn-discover-k2');
    if (btn) { btn.disabled = true; btn.innerHTML = '⏳ Discovering...'; }

    try {
        const siteFilter = document.getElementById('discover-site-filter')?.value || '';
        const res = await fetch(`${API}/api/k2/discover-smartobjects`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ siteFilter })
        });
        const data = await res.json();

        if (data.success) {
            if (data.discovered > 0) {
                showToast(`✓ Discovered ${data.discovered} SP broker SmartObjects (${data.totalOnServer} total on K2)`, 'success');
            } else {
                showToast(`No SP broker SmartObjects found matching filter. ${data.totalOnServer} total SOs on server. Try a different site name.`, 'warning');
            }
            await loadSmartObjects();
        } else {
            showToast('Discovery failed: ' + (data.error || 'Unknown error'), 'error');
        }
    } catch (err) {
        showToast('Discovery failed: ' + err.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg> Discover from K2'; }
    }
}

async function loadSmartObjects() {
    try {
        const res = await fetch(`${API}/api/smartobjects`);
        const data = await res.json();

        renderSOStats(data.stats);
        renderSOList(data.smartObjects);

        // Enable deploy all if there are pending SOs
        const pending = (data.smartObjects || []).filter(s => s.deploymentStatus === 'pending');
        document.getElementById('btn-deploy-all').disabled = pending.length === 0;

        updateK2Status();
    } catch (err) {
        console.error('SmartObject load error:', err);
    }
}

function renderSOStats(stats) {
    if (!stats || stats.total === 0) return;

    const discCount = stats.discovered || 0;
    const genCount = stats.total - discCount;

    document.getElementById('so-stats').innerHTML = `
        <div class="stat-tile"><div class="stat-label">${discCount > 0 ? 'Discovered' : 'Generated'}</div><div class="stat-value cyan">${stats.total}</div><div class="stat-sub">${discCount > 0 ? discCount + ' from K2 broker' : stats.totalMethods + ' CRUD methods'}</div></div>
        <div class="stat-tile"><div class="stat-label">${discCount > 0 ? 'Live on K2' : 'Deployed'}</div><div class="stat-value emerald">${stats.deployed + discCount}</div><div class="stat-sub">${stats.pending > 0 ? stats.pending + ' pending' : 'SP2013 broker'}</div></div>
        <div class="stat-tile"><div class="stat-label">Properties</div><div class="stat-value" style="color:var(--accent-blue)">${stats.totalProperties}</div><div class="stat-sub">Across all SmartObjects</div></div>
        <div class="stat-tile"><div class="stat-label">Methods</div><div class="stat-value purple">${stats.totalMethods}</div><div class="stat-sub">${discCount > 0 ? 'GetListItems, Create...' : 'CRUD operations'}</div></div>
    `;
}

function renderSOList(smartObjects) {
    const container = document.getElementById('so-list-container');
    if (!smartObjects || smartObjects.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:2rem;"><h3>No SmartObjects Generated</h3><p>Run analysis first, then click "Generate".</p></div>';
        return;
    }

    let html = `<table class="data-table">
        <thead><tr>
            <th>Name</th><th>Source List</th><th>Properties</th><th>Methods</th>
            <th>Complexity</th><th>Status</th><th>Actions</th>
        </tr></thead><tbody>`;

    smartObjects.forEach(so => {
        const statusClass = so.deploymentStatus === 'deployed' ? 'simple' :
                           so.deploymentStatus === 'discovered' ? 'simple' :
                           so.deploymentStatus === 'deploying' ? 'medium' :
                           so.deploymentStatus === 'failed' ? 'critical' : 'medium';
        const statusLabel = so.deploymentStatus === 'discovered' ? '✓ live on K2' : so.deploymentStatus;
        const brokerTag = so.brokerType === 'SharePoint'
            ? '<span style="font-size:0.6rem; color:var(--accent-cyan); margin-left:4px;">(SP broker)</span>' : '';

        html += `<tr class="${selectedSOId === so.id ? 'selected' : ''}" style="cursor:pointer;" onclick="selectSmartObject('${so.id}')">
            <td style="color:var(--text-primary); font-weight:600;">
                <div style="display:flex;align-items:center;gap:8px;">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="var(--accent-cyan)" stroke-width="2" width="16" height="16"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/></svg>
                    ${esc(so.displayName)}${brokerTag}
                </div>
            </td>
            <td style="max-width:200px; overflow:hidden; text-overflow:ellipsis; font-size:0.75rem;">${esc(so.listTitle || so.webUrl || '')}</td>
            <td>${so.propertyCount}</td>
            <td>${so.methodCount}</td>
            <td><span class="badge badge-${so.complexity}">${so.complexity}</span></td>
            <td><span class="badge badge-${statusClass}">${statusLabel}</span>${so.hasBlockedFields ? ' <span class="badge badge-blocked" title="Has fields requiring custom Service Broker">⚠</span>' : ''}</td>
            <td>
                <button class="btn btn-outline btn-sm" onclick="event.stopPropagation(); selectSmartObject('${so.id}')">Preview</button>
                ${so.deploymentStatus === 'pending' ? `<button class="btn btn-success btn-sm" onclick="event.stopPropagation(); deploySingleSO('${so.id}')">Deploy</button>` : ''}
            </td>
        </tr>`;
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

async function selectSmartObject(id) {
    selectedSOId = id;

    try {
        // Load XML preview
        const xmlRes = await fetch(`${API}/api/smartobjects/${id}/xml`);
        previewXmlContent = await xmlRes.text();
        document.getElementById('xml-preview').textContent = previewXmlContent;
        document.getElementById('btn-copy-xml').style.display = 'inline-flex';

        // Load SQL preview
        const sqlRes = await fetch(`${API}/api/smartobjects/${id}/sql`);
        previewSqlContent = await sqlRes.text();
        document.getElementById('sql-preview').textContent = previewSqlContent;
        document.getElementById('btn-copy-sql').style.display = 'inline-flex';

        // Highlight selected row
        await loadSmartObjects();
    } catch (err) {
        showToast('Failed to load preview', 'error');
    }
}

function copyPreview(type) {
    const content = type === 'xml' ? previewXmlContent : previewSqlContent;
    navigator.clipboard.writeText(content).then(() => {
        showToast(`${type.toUpperCase()} copied to clipboard`, 'success');
    }).catch(() => {
        showToast('Copy failed', 'error');
    });
}

async function deploySingleSO(id) {
    try {
        showToast('Deploying SmartObject...', 'info');
        const res = await fetch(`${API}/api/smartobjects/${id}/deploy`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`SmartObject deployed ✓ (${data.deployment.durationMs}ms)`, 'success');
        } else {
            showToast(`Deployment failed: ${data.deployment.error || 'Unknown error'}`, 'error');
        }

        await loadSmartObjects();
    } catch (err) {
        showToast('Deployment failed: ' + err.message, 'error');
    }
}

async function deployAllSmartObjects() {
    try {
        showToast('Deploying all SmartObjects...', 'info');
        document.getElementById('btn-deploy-all').disabled = true;

        const res = await fetch(`${API}/api/smartobjects/deploy-all`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`Batch deployment complete: ${data.deployed}/${data.total} deployed`, data.failed > 0 ? 'error' : 'success');
        } else {
            showToast(data.error || 'Batch deployment failed', 'error');
        }

        await loadSmartObjects();
    } catch (err) {
        showToast('Batch deployment failed: ' + err.message, 'error');
        document.getElementById('btn-deploy-all').disabled = false;
    }
}

async function reconcileWithK2() {
    const btn = document.getElementById('btn-reconcile-k2');
    const statusEl = document.getElementById('reconcile-status');

    btn.disabled = true;
    btn.innerHTML = '<div class="spinner" style="display:inline-block;width:14px;height:14px;"></div> Querying K2...';
    statusEl.style.display = 'block';
    statusEl.style.background = 'var(--bg-input)';
    statusEl.style.color = 'var(--text-secondary)';
    statusEl.style.border = '1px solid var(--border-subtle)';
    statusEl.textContent = 'Querying K2 server for deployed SmartObjects...';

    try {
        const res = await fetch(`${API}/api/k2/reconcile`, {
            method: 'POST',
            signal: AbortSignal.timeout(120000) // 2 min timeout for large environments
        });
        const data = await res.json();

        if (data.success) {
            const color = data.reconciled > 0 ? 'var(--accent-emerald)' : 'var(--accent-cyan)';
            statusEl.style.background = 'rgba(16, 185, 129, 0.08)';
            statusEl.style.border = '1px solid rgba(16, 185, 129, 0.25)';
            statusEl.style.color = color;

            let msg = `✓ K2 server has ${data.k2ServerSmartObjects} SmartObjects. `;
            if (data.reconciled > 0) {
                msg += `${data.reconciled} status(es) updated. `;
                data.changes.forEach(c => {
                    msg += `[${c.name}: ${c.from} → ${c.to}] `;
                });
            } else {
                msg += `All ${data.alreadyCorrect} local SmartObjects already in sync.`;
            }
            statusEl.textContent = msg;

            showToast(`Reconciled with K2: ${data.reconciled} updated, ${data.alreadyCorrect} already correct`, 'success');
            await loadSmartObjects();
        } else {
            statusEl.style.background = 'rgba(239, 68, 68, 0.08)';
            statusEl.style.border = '1px solid rgba(239, 68, 68, 0.25)';
            statusEl.style.color = 'var(--accent-red)';
            statusEl.textContent = `✗ Reconciliation failed: ${data.error || 'Unknown error'}`;
            showToast('K2 reconciliation failed', 'error');
        }
    } catch (err) {
        statusEl.style.background = 'rgba(239, 68, 68, 0.08)';
        statusEl.style.border = '1px solid rgba(239, 68, 68, 0.25)';
        statusEl.style.color = 'var(--accent-red)';
        statusEl.textContent = `✗ Error: ${err.message}`;
        showToast('Reconciliation error: ' + err.message, 'error');
    } finally {
        btn.disabled = false;
        btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg> Reconcile with K2';

        // Auto-hide status after 30s
        setTimeout(() => { statusEl.style.display = 'none'; }, 30000);
    }
}

// ── Phase 4: SmartForms ───────────────────────────────────────────

let selectedSFId = null;
let sfXmlContent = '';

async function reconcileSmartFormsWithK2() {
    const btn = document.getElementById('btn-reconcile-sf');
    const statusEl = document.getElementById('reconcile-sf-status');

    btn.disabled = true;
    btn.innerHTML = '<div class="spinner" style="display:inline-block;width:14px;height:14px;"></div> Querying K2...';
    statusEl.style.display = 'block';
    statusEl.style.background = 'var(--bg-input)';
    statusEl.style.color = 'var(--text-secondary)';
    statusEl.style.border = '1px solid var(--border-subtle)';
    statusEl.textContent = 'Querying K2 server for deployed SmartForms and Views...';

    try {
        const res = await fetch(`${API}/api/k2/reconcile-smartforms`, {
            method: 'POST',
            signal: AbortSignal.timeout(120000)
        });
        const data = await res.json();

        if (data.success) {
            const color = data.reconciled > 0 ? 'var(--accent-emerald)' : 'var(--accent-cyan)';
            statusEl.style.background = 'rgba(16, 185, 129, 0.08)';
            statusEl.style.border = '1px solid rgba(16, 185, 129, 0.25)';
            statusEl.style.color = color;

            let msg = `✓ K2 server has ${data.k2ServerForms} Forms and ${data.k2ServerViews} Views. `;
            if (data.reconciled > 0) {
                msg += `${data.reconciled} status(es) updated. `;
                data.changes.forEach(c => {
                    msg += `[${c.name}: ${c.from} → ${c.to}] `;
                });
            } else {
                msg += `All ${data.alreadyCorrect} local SmartForms already in sync.`;
            }
            statusEl.textContent = msg;

            showToast(`SmartForms reconciled: ${data.reconciled} updated, ${data.alreadyCorrect} already correct`, 'success');
            await loadSmartForms();
        } else {
            statusEl.style.background = 'rgba(239, 68, 68, 0.08)';
            statusEl.style.border = '1px solid rgba(239, 68, 68, 0.25)';
            statusEl.style.color = 'var(--accent-red)';
            statusEl.textContent = `✗ Reconciliation failed: ${data.error || 'Unknown error'}`;
            showToast('SmartForm reconciliation failed', 'error');
        }
    } catch (err) {
        statusEl.style.background = 'rgba(239, 68, 68, 0.08)';
        statusEl.style.border = '1px solid rgba(239, 68, 68, 0.25)';
        statusEl.style.color = 'var(--accent-red)';
        statusEl.textContent = `✗ Error: ${err.message}`;
        showToast('SmartForm reconciliation error: ' + err.message, 'error');
    } finally {
        btn.disabled = false;
        btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg> Reconcile with K2';
        setTimeout(() => { statusEl.style.display = 'none'; }, 30000);
    }
}

// ── SP Broker: 1-Click Form Deploy ──────────────────────────

let spBrokerLists = [];
let spBrokerSiteUrl = '';
let spBrokerSiteTitle = '';

async function spBrokerDiscoverLists() {
    const siteUrl = document.getElementById('sp-broker-site-url').value.trim();
    if (!siteUrl) { showToast('Enter a SharePoint Site URL', 'error'); return; }

    const btn = document.getElementById('btn-sp-discover');
    const statusEl = document.getElementById('sp-broker-status');
    const container = document.getElementById('sp-broker-list-container');
    const badge = document.getElementById('sp-broker-badge');

    btn.disabled = true;
    btn.textContent = 'Discovering...';
    statusEl.style.display = 'block';
    statusEl.style.background = 'rgba(6,182,212,0.1)';
    statusEl.style.color = 'var(--accent-cyan)';
    statusEl.textContent = `Connecting to ${siteUrl}...`;

    try {
        const res = await fetch(`${API}/api/sp-broker/discover-lists`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ siteUrl })
        });
        const data = await res.json();

        if (data.success && data.lists) {
            spBrokerLists = data.lists;
            spBrokerSiteUrl = data.siteUrl || siteUrl;
            spBrokerSiteTitle = data.siteTitle || '';

            badge.textContent = `${data.lists.length} lists`;
            badge.style.background = 'var(--accent-emerald)';
            badge.style.color = '#fff';

            statusEl.style.background = 'rgba(16,185,129,0.1)';
            statusEl.style.color = 'var(--accent-emerald)';
            statusEl.textContent = `✓ Found ${data.lists.length} lists on "${data.siteTitle}" (${siteUrl})`;

            document.getElementById('btn-sp-deploy-all').disabled = false;
            renderSpBrokerLists();
            showToast(`Discovered ${data.lists.length} lists`, 'success');
        } else {
            statusEl.style.background = 'rgba(239,68,68,0.1)';
            statusEl.style.color = 'var(--accent-red)';
            statusEl.textContent = '✗ ' + (data.error || 'Discovery failed');
            container.innerHTML = '';
            showToast(data.error || 'Discovery failed', 'error');
        }
    } catch (err) {
        statusEl.style.background = 'rgba(239,68,68,0.1)';
        statusEl.style.color = 'var(--accent-red)';
        statusEl.textContent = '✗ ' + err.message;
        showToast('Discovery error: ' + err.message, 'error');
    }

    btn.disabled = false;
    btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg> Discover Lists';
}

function renderSpBrokerLists() {
    const container = document.getElementById('sp-broker-list-container');
    if (!spBrokerLists.length) {
        container.innerHTML = '<div style="padding:1rem; color:var(--text-muted); font-size:0.82rem;">No lists found.</div>';
        return;
    }

    let html = `<table class="data-table">
        <thead><tr>
            <th>List Name</th><th>Items</th><th>Fields</th><th>Created</th><th>Status</th><th>Action</th>
        </tr></thead><tbody>`;

    spBrokerLists.forEach((list, idx) => {
        const statusId = `sp-broker-status-${idx}`;
        html += `<tr id="sp-broker-row-${idx}">
            <td style="color:var(--text-primary); font-weight:500;">${esc(list.listTitle)}</td>
            <td>${list.itemCount}</td>
            <td>${list.fieldCount >= 0 ? list.fieldCount : '—'}</td>
            <td style="font-size:0.75rem; color:var(--text-muted);">${list.created || '—'}</td>
            <td><span class="badge" id="${statusId}" style="font-size:0.68rem;">pending</span></td>
            <td>
                <button class="btn btn-primary btn-sm" id="sp-broker-btn-${idx}" onclick="spBrokerDeployForms(${idx})" style="font-size:0.72rem; padding:3px 10px;">
                    Deploy
                </button>
            </td>
        </tr>`;
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

async function spBrokerDeployForms(idx) {
    const list = spBrokerLists[idx];
    const btn = document.getElementById(`sp-broker-btn-${idx}`);
    const status = document.getElementById(`sp-broker-status-${idx}`);

    btn.disabled = true;
    btn.textContent = 'Deploying...';
    status.textContent = 'deploying';
    status.style.background = 'var(--accent-amber)';
    status.style.color = '#000';

    try {
        const res = await fetch(`${API}/api/sp-broker/deploy-forms`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                siteUrl: spBrokerSiteUrl,
                siteTitle: spBrokerSiteTitle,
                listId: list.listId,
                listTitle: list.listTitle
            })
        });
        const data = await res.json();

        if (data.success) {
            status.textContent = '✓ deployed';
            status.style.background = 'var(--accent-emerald)';
            status.style.color = '#fff';
            btn.textContent = '✓ Done';
            btn.classList.remove('btn-primary');
            btn.classList.add('btn-outline');

            // Show form URLs
            const row = document.getElementById(`sp-broker-row-${idx}`);
            if (data.newFormUrl || data.editFormUrl) {
                const urlHtml = `<tr><td colspan="6" style="padding:0.5rem 1rem; font-size:0.75rem; background:rgba(16,185,129,0.05); border-top: 1px solid var(--border-subtle);">
                    <strong style="color:var(--accent-emerald);">Forms deployed:</strong>&nbsp;
                    ${data.newFormUrl ? `<a href="${esc(data.newFormUrl)}" target="_blank" style="color:var(--accent-cyan);">New</a> · ` : ''}
                    ${data.editFormUrl ? `<a href="${esc(data.editFormUrl)}" target="_blank" style="color:var(--accent-cyan);">Edit</a> · ` : ''}
                    ${data.displayFormUrl ? `<a href="${esc(data.displayFormUrl)}" target="_blank" style="color:var(--accent-cyan);">Display</a>` : ''}
                </td></tr>`;
                row.insertAdjacentHTML('afterend', urlHtml);
            }
            showToast(`${list.listTitle}: forms deployed ✓`, 'success');
        } else {
            status.textContent = '✗ failed';
            status.style.background = 'var(--accent-red)';
            status.style.color = '#fff';
            btn.textContent = 'Retry';
            btn.disabled = false;
            showToast(`${list.listTitle}: ${data.error}`, 'error');
        }
    } catch (err) {
        status.textContent = '✗ error';
        status.style.background = 'var(--accent-red)';
        status.style.color = '#fff';
        btn.textContent = 'Retry';
        btn.disabled = false;
        showToast(`${list.listTitle}: ${err.message}`, 'error');
    }
}

async function spBrokerDeployAll() {
    const btn = document.getElementById('btn-sp-deploy-all');
    btn.disabled = true;
    btn.textContent = 'Deploying...';

    for (let i = 0; i < spBrokerLists.length; i++) {
        const status = document.getElementById(`sp-broker-status-${i}`);
        if (status && status.textContent === '✓ deployed') continue; // skip already deployed
        await spBrokerDeployForms(i);
    }

    btn.textContent = '✓ All Deployed';
    showToast('All lists deployed!', 'success');
}

async function generateSmartForms() {
    try {
        showToast('Generating SmartForm definitions...', 'info');
        const res = await fetch(`${API}/api/smartforms/generate`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`Generated ${data.summary.generated} SmartForms with ${data.summary.totalViews} views and ${data.summary.totalRules} rules`, 'success');
            document.getElementById('badge-smartforms').textContent = data.summary.generated;
            await loadSmartForms();
        } else {
            showToast(data.error || 'Generation failed', 'error');
        }
    } catch (err) {
        showToast('SmartForm generation failed: ' + err.message, 'error');
    }
}

async function loadSmartForms() {
    try {
        const res = await fetch(`${API}/api/smartforms`);
        const data = await res.json();

        renderSFStats(data.stats);
        renderSFList(data.smartForms);

        const pending = (data.smartForms || []).filter(s => s.deploymentStatus === 'pending');
        document.getElementById('btn-deploy-all-sf').disabled = pending.length === 0;
    } catch (err) {
        console.error('SmartForm load error:', err);
    }
}

function renderSFStats(stats) {
    if (!stats || stats.total === 0) return;
    document.getElementById('sf-stats').innerHTML = `
        <div class="stat-tile"><div class="stat-label">Forms</div><div class="stat-value cyan">${stats.total}</div><div class="stat-sub">${stats.deployed} deployed</div></div>
        <div class="stat-tile"><div class="stat-label">Views</div><div class="stat-value" style="color:var(--accent-blue)">${stats.totalViews}</div><div class="stat-sub">List + Item + Edit</div></div>
        <div class="stat-tile"><div class="stat-label">Controls</div><div class="stat-value emerald">${stats.totalControls}</div><div class="stat-sub">Bound to SmartObject</div></div>
        <div class="stat-tile"><div class="stat-label">Rules</div><div class="stat-value purple">${stats.totalRules}</div><div class="stat-sub">Load / Save / Navigate</div></div>
        <div class="stat-tile"><div class="stat-label">Validations</div><div class="stat-value amber">${stats.totalValidations}</div><div class="stat-sub">Required + format</div></div>
        <div class="stat-tile"><div class="stat-label">Manual Config</div><div class="stat-value red">${stats.manualConfigItems}</div><div class="stat-sub">Need K2 Designer</div></div>
    `;
}

function renderSFList(smartForms) {
    const container = document.getElementById('sf-list-container');
    if (!smartForms || smartForms.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:2rem;"><h3>No SmartForms Generated</h3><p>Generate SmartObjects first, then click "Generate Forms".</p></div>';
        return;
    }

    let html = `<table class="data-table">
        <thead><tr>
            <th>Form Name</th><th>SmartObject</th><th>Views</th><th>Controls</th>
            <th>Rules</th><th>Manual</th><th>Status</th><th>Actions</th>
        </tr></thead><tbody>`;

    smartForms.forEach(sf => {
        const statusClass = sf.deploymentStatus === 'deployed' ? 'simple' :
                           sf.deploymentStatus === 'failed' ? 'critical' : 'medium';
        const manualCls = sf.manualConfigCount > 0 ? 'amber' : 'emerald';

        html += `<tr class="${selectedSFId === sf.id ? 'selected' : ''}" style="cursor:pointer;" onclick="selectSmartForm('${sf.id}')">
            <td style="color:var(--text-primary); font-weight:600;">
                <div style="display:flex;align-items:center;gap:8px;">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="var(--accent-purple)" stroke-width="2" width="16" height="16"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18"/><path d="M9 21V9"/></svg>
                    ${esc(sf.displayName)}
                </div>
            </td>
            <td style="font-size:0.75rem;">${esc(sf.smartObjectName)}</td>
            <td>${sf.viewCount}</td>
            <td>${sf.controlCount}</td>
            <td>${sf.ruleCount}</td>
            <td><span class="badge badge-${sf.manualConfigCount > 0 ? 'complex' : 'simple'}">${sf.manualConfigCount}</span></td>
            <td><span class="badge badge-${statusClass}">${sf.deploymentStatus}</span></td>
            <td>
                <button class="btn btn-outline btn-sm" onclick="event.stopPropagation(); selectSmartForm('${sf.id}')">Detail</button>
                ${sf.deploymentStatus === 'pending' ? `<button class="btn btn-success btn-sm" onclick="event.stopPropagation(); deploySingleSF('${sf.id}')">Deploy</button>` : ''}
            </td>
        </tr>`;
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

async function selectSmartForm(id) {
    selectedSFId = id;

    try {
        // Load detail
        const detRes = await fetch(`${API}/api/smartforms/${id}`);
        const sf = await detRes.json();
        renderSFDetail(sf);

        // Load XML
        const xmlRes = await fetch(`${API}/api/smartforms/${id}/xml`);
        sfXmlContent = await xmlRes.text();
        document.getElementById('sf-xml-preview').textContent = sfXmlContent;
        document.getElementById('btn-copy-sf-xml').style.display = 'inline-flex';

        await loadSmartForms();
    } catch (err) {
        showToast('Failed to load SmartForm detail', 'error');
    }
}

function renderSFDetail(sf) {
    let html = '';

    // Views summary
    sf.views.forEach(view => {
        html += `<div class="detail-section">
            <div class="detail-section-title" style="display:flex;align-items:center;gap:8px;">
                <span class="badge badge-${view.type === 'list' ? 'simple' : view.type === 'edit' ? 'medium' : 'workflow'}">${esc(view.type)}</span>
                ${esc(view.displayName)}
            </div>
            <div class="env-detail"><span class="env-detail-label">Bound Method</span><span class="env-detail-value">${esc(view.boundMethod)}</span></div>
            <div class="env-detail"><span class="env-detail-label">Controls</span><span class="env-detail-value">${view.controls.length}</span></div>
            <div class="env-detail"><span class="env-detail-label">Rules</span><span class="env-detail-value">${view.rules.length}</span></div>
            <div class="env-detail"><span class="env-detail-label">Validations</span><span class="env-detail-value">${view.validations.length}</span></div>`;

        // Show controls
        if (view.controls.length > 0) {
            html += `<div style="margin-top:0.5rem;"><table class="data-table">
                <thead><tr><th>Control</th><th>Type</th><th>Data Field</th><th>Editable</th></tr></thead><tbody>`;
            view.controls.filter(c => !c.isLabel && c.controlType !== 'Button').forEach(c => {
                html += `<tr>
                    <td style="font-size:0.75rem;">${esc(c.displayName)}</td>
                    <td><span class="badge badge-medium" style="font-size:0.65rem;">${esc(c.controlType)}</span></td>
                    <td style="font-size:0.75rem;">${esc(c.dataField || '—')}</td>
                    <td>${c.editable ? '<span style="color:var(--accent-emerald)">✓</span>' : '<span style="color:var(--text-muted)">—</span>'}</td>
                </tr>`;
            });
            html += '</tbody></table></div>';
        }

        // Show rules
        if (view.rules.length > 0) {
            html += `<div style="margin-top:0.5rem;"><strong style="font-size:0.72rem; color:var(--accent-purple);">Rules:</strong><ul style="margin:4px 0 0 1rem; padding:0; font-size:0.72rem; color:var(--text-secondary);">`;
            view.rules.forEach(r => {
                html += `<li><strong>${esc(r.name)}</strong>: ${esc(r.description)}</li>`;
            });
            html += '</ul></div>';
        }

        html += '</div>';
    });

    // Manual config items
    if (sf.manualConfigItems && sf.manualConfigItems.length > 0) {
        html += `<div class="detail-section">
            <div class="detail-section-title" style="color:var(--accent-amber);">⚠ Manual Configuration Required</div>
            <table class="data-table">
                <thead><tr><th>Property</th><th>Reason</th><th>Suggestion</th></tr></thead><tbody>`;
        sf.manualConfigItems.forEach(item => {
            html += `<tr>
                <td style="font-weight:500;">${esc(item.property)}</td>
                <td style="font-size:0.72rem;">${esc(item.reason)}</td>
                <td style="font-size:0.72rem; color:var(--accent-cyan);">${esc(item.suggestion)}</td>
            </tr>`;
        });
        html += '</tbody></table></div>';
    }

    document.getElementById('sf-detail-container').innerHTML = html || '<p style="color:var(--text-muted);">No details available</p>';
}

function copySFXml() {
    navigator.clipboard.writeText(sfXmlContent).then(() => {
        showToast('SmartForm XML copied to clipboard', 'success');
    }).catch(() => showToast('Copy failed', 'error'));
}

async function deploySingleSF(id) {
    try {
        showToast('Deploying SmartForm...', 'info');
        const res = await fetch(`${API}/api/smartforms/${id}/deploy`, { method: 'POST' });
        const data = await res.json();
        showToast(data.success ? 'SmartForm deployed ✓' : 'Deploy failed', data.success ? 'success' : 'error');
        await loadSmartForms();
    } catch (err) {
        showToast('Deploy failed: ' + err.message, 'error');
    }
}

async function deployAllSmartForms() {
    try {
        showToast('Deploying all SmartForms...', 'info');
        document.getElementById('btn-deploy-all-sf').disabled = true;
        const res = await fetch(`${API}/api/smartforms/deploy-all`, { method: 'POST' });
        const data = await res.json();
        showToast(data.success ? `Batch complete: ${data.deployed}/${data.total} deployed` : 'Batch failed', data.success ? 'success' : 'error');
        await loadSmartForms();
    } catch (err) {
        showToast('Batch deploy failed', 'error');
        document.getElementById('btn-deploy-all-sf').disabled = false;
    }
}

// ── Phase 5: Blueprints ──────────────────────────────────────────

let selectedBPId = null;

// ── Strategy A: K2 Templates (Filterable + Paginated) ─────────────

let _allK2Templates = [];
let _templatePage = 1;
const _templatePageSize = 20;
let _templateSearch = '';
let _templateApprovalOnly = false;

function _getFilteredTemplates() {
    let filtered = _allK2Templates;
    if (_templateApprovalOnly) {
        filtered = filtered.filter(t =>
            (t.procName || '').toLowerCase().includes('approval') ||
            (t.displayName || '').toLowerCase().includes('approval')
        );
    }
    if (_templateSearch) {
        const q = _templateSearch.toLowerCase();
        filtered = filtered.filter(t =>
            (t.procName || '').toLowerCase().includes(q) ||
            (t.displayName || '').toLowerCase().includes(q) ||
            (t.folder || '').toLowerCase().includes(q)
        );
    }
    return filtered;
}

async function fetchK2Templates() {
    const container = document.getElementById('k2-templates-container');
    const statusEl = document.getElementById('k2-templates-status');

    statusEl.style.display = 'block';
    statusEl.style.background = 'var(--bg-input)';
    statusEl.style.color = 'var(--text-secondary)';
    statusEl.style.border = '1px solid var(--border-subtle)';
    statusEl.textContent = 'Querying K2 server for workflow templates...';

    try {
        const res = await fetch(`${API}/api/k2/workflow-templates`, {
            method: 'POST',
            signal: AbortSignal.timeout(60000)
        });
        const data = await res.json();

        if (data.success && data.templates && data.templates.length > 0) {
            statusEl.style.background = 'rgba(16, 185, 129, 0.08)';
            statusEl.style.border = '1px solid rgba(16, 185, 129, 0.25)';
            statusEl.style.color = 'var(--accent-emerald)';
            const approvalCount = data.templates.filter(t =>
                (t.procName || '').toLowerCase().includes('approval') ||
                (t.displayName || '').toLowerCase().includes('approval')
            ).length;
            statusEl.textContent = `✓ Found ${data.count} template(s) on K2 (${approvalCount} approval-related)`;

            _allK2Templates = data.templates;
            _templatePage = 1;
            renderTemplatePage();

            setTimeout(() => { statusEl.style.display = 'none'; }, 10000);
        } else if (data.success && (!data.templates || data.templates.length === 0)) {
            statusEl.style.color = 'var(--accent-amber)';
            statusEl.textContent = '⚠ K2 connected but no workflow templates found. Deploy a master template first.';
            container.innerHTML = '<div class="empty-state" style="padding:1.5rem;"><h3 style="font-size:0.85rem;">No Templates on K2</h3><p style="font-size:0.78rem;">Deploy a template first.</p></div>';
        } else {
            statusEl.style.background = 'rgba(239, 68, 68, 0.08)';
            statusEl.style.border = '1px solid rgba(239, 68, 68, 0.25)';
            statusEl.style.color = 'var(--accent-red)';
            statusEl.textContent = `✗ ${data.error || 'Failed to query K2 templates'}`;
        }
    } catch (err) {
        statusEl.style.background = 'rgba(239, 68, 68, 0.08)';
        statusEl.style.border = '1px solid rgba(239, 68, 68, 0.25)';
        statusEl.style.color = 'var(--accent-red)';
        statusEl.textContent = `✗ Error: ${err.message}`;
        showToast('Template fetch failed: ' + err.message, 'error');
    }
}

let _tplSearchTimer = null;

// Filter button: auto-fetches from K2 on first use, then filters locally
async function filterK2Templates() {
    if (_allK2Templates.length === 0) {
        await fetchK2Templates();
    } else {
        _templatePage = 1;
        renderTemplatePage();
    }
}

function filterTemplatesDebounced() {
    clearTimeout(_tplSearchTimer);
    _tplSearchTimer = setTimeout(() => {
        if (_allK2Templates.length > 0) {
            _templatePage = 1;
            renderTemplatePage();
        }
    }, 300);
}

function clearTemplateSearch() {
    const nameEl = document.getElementById('tpl-search-name');
    const typeEl = document.getElementById('tpl-search-type');
    if (nameEl) nameEl.value = '';
    if (typeEl) typeEl.value = 'all';
    _templatePage = 1;
    renderTemplatePage();
}

function _getFilteredTemplates() {
    let filtered = _allK2Templates;
    const nameQ = (document.getElementById('tpl-search-name')?.value || '').toLowerCase();
    const typeQ = document.getElementById('tpl-search-type')?.value || 'all';

    if (nameQ) {
        filtered = filtered.filter(t =>
            (t.procName || '').toLowerCase().includes(nameQ) ||
            (t.displayName || '').toLowerCase().includes(nameQ) ||
            (t.folder || '').toLowerCase().includes(nameQ)
        );
    }

    if (typeQ !== 'all') {
        filtered = filtered.filter(t => _classifyTemplateTier(t) === typeQ);
    }
    return filtered;
}

function _classifyTemplateTier(t) {
    const name = ((t.procName || '') + ' ' + (t.displayName || '')).toLowerCase();
    // Tier 1: Simple single-step approvals
    if (/\b(approval|approve|simple.?approv|single.?step)\b/.test(name)) return 'tier1';
    // Tier 2: Multi-step, review, escalation
    if (/\b(review|escalat|multi.?step|parallel|conditional|routing)\b/.test(name)) return 'tier2';
    // Tier 3: Custom / provisioning / onboarding
    if (/\b(custom|provision|onboard|request|intake|submiss)\b/.test(name)) return 'tier3';
    // Tier 4: Everything else (complex / legacy)
    return 'tier4';
}

function renderTemplatePage() {
    const filtered = _getFilteredTemplates();
    const showCount = Math.min(filtered.length, 10); // Top 10 by default
    const totalPages = Math.max(1, Math.ceil(filtered.length / 10));
    if (_templatePage > totalPages) _templatePage = totalPages;
    const start = (_templatePage - 1) * 10;
    const pageData = filtered.slice(start, start + 10);

    const infoEl = document.getElementById('template-page-info');
    if (infoEl) infoEl.textContent = filtered.length > 0
        ? `${Math.min(start + 10, filtered.length)} of ${filtered.length} templates`
        : 'No matches';

    const container = document.getElementById('k2-templates-container');
    if (!container) return;

    if (pageData.length === 0 && _allK2Templates.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:1.5rem;"><h3 style="font-size:0.85rem;">No Templates Loaded</h3><p style="font-size:0.78rem;">Click "Fetch from K2" to discover deployed workflow templates.</p></div>';
        return;
    }
    if (pageData.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:1rem;"><p style="font-size:0.78rem;">No templates match the current filter.</p></div>';
        return;
    }

    let html = '<div style="display:grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 0.6rem; padding: 0.75rem;">';
    pageData.forEach(t => {
        const tier = _classifyTemplateTier(t);
        const tierLabel = { tier1: 'Tier 1', tier2: 'Tier 2', tier3: 'Tier 3', tier4: 'Tier 4' }[tier];
        const tierBadge = { tier1: 'simple', tier2: 'medium', tier3: 'complex', tier4: 'critical' }[tier];
        const borderColor = tier === 'tier1' ? 'var(--accent-emerald)' : tier === 'tier2' ? 'rgba(96, 165, 250, 0.4)' : 'var(--border-subtle)';

        html += `<div style="border:1px solid ${borderColor}; border-radius:var(--radius-sm); padding:0.6rem; background:var(--bg-elevated);">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
                <div style="font-weight:600; color:var(--text-primary); font-size:0.78rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:200px;" title="${esc(t.procName)}">${esc(t.procName || t.displayName)}</div>
                <span class="badge badge-${tierBadge}" style="font-size:0.58rem;">${tierLabel}</span>
            </div>
            <div style="font-size:0.68rem; color:var(--text-muted);">${esc(t.folder || 'Root')} · v${t.version || 1}</div>
        </div>`;
    });
    html += '</div>';

    // Pagination if more than 10
    if (totalPages > 1) {
        html += '<div style="display:flex; justify-content:center; gap:6px; padding:0.5rem;">';
        html += `<button class="btn btn-outline btn-sm" ${_templatePage <= 1 ? 'disabled' : ''} onclick="_templatePage--; renderTemplatePage();">‹</button>`;
        for (let p = Math.max(1, _templatePage - 3); p <= Math.min(totalPages, _templatePage + 3); p++) {
            html += `<button class="btn ${p === _templatePage ? 'btn-primary' : 'btn-outline'} btn-sm" onclick="_templatePage=${p}; renderTemplatePage();">${p}</button>`;
        }
        html += `<button class="btn btn-outline btn-sm" ${_templatePage >= totalPages ? 'disabled' : ''} onclick="_templatePage++; renderTemplatePage();">›</button>`;
        html += '</div>';
    }

    container.innerHTML = html;
}


// ── Strategy A: Form → Template Linkage (Site-Filtered) ──────────

let _allRoutingData = [];
let _linkagePage = 1;
const _linkagePageSize = 50;

async function generateRoutingConfig() {
    try {
        showToast('Generating routing configuration...', 'info');
        const res = await fetch(`${API}/api/workflow-routing/generate`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            _allRoutingData = data.routing || [];
            _linkagePage = 1;
            showToast(`Routing generated: ${data.stats.fullyWired}/${data.stats.total} fully wired`, 'success');
            document.getElementById('badge-blueprints').textContent = data.stats.total;
            renderRoutingStats(data.stats);
            populateLobDropdown();
            renderLinkagePage();
        } else {
            showToast(data.error || 'Routing generation failed', 'error');
        }
    } catch (err) {
        showToast('Routing generation failed: ' + err.message, 'error');
    }
}

async function loadBlueprints() {
    try {
        const res = await fetch(`${API}/api/workflow-routing`);
        const data = await res.json();
        if (data.success && data.routing && data.routing.length > 0) {
            _allRoutingData = data.routing;
            _linkagePage = 1;
            renderRoutingStats(data.stats);
            populateLobDropdown();
            document.getElementById('badge-blueprints').textContent = data.stats.total;
        }
    } catch (err) {
        console.error('Routing load error:', err);
    }
}

function renderRoutingStats(stats) {
    if (!stats || stats.total === 0) return;
    document.getElementById('routing-stats').innerHTML = `
        <div class="stat-tile"><div class="stat-label">Total Forms</div><div class="stat-value cyan">${stats.total}</div><div class="stat-sub">From analysis</div></div>
        <div class="stat-tile"><div class="stat-label">Template-Linked</div><div class="stat-value emerald">${stats.linked}</div><div class="stat-sub">Tier 1-2 (auto)</div></div>
        <div class="stat-tile"><div class="stat-label">SO Ready</div><div class="stat-value" style="color:var(--accent-blue)">${stats.soReady}</div><div class="stat-sub">Deployed</div></div>
        <div class="stat-tile"><div class="stat-label">SF Ready</div><div class="stat-value purple">${stats.sfReady}</div><div class="stat-sub">Deployed</div></div>
        <div class="stat-tile"><div class="stat-label">Fully Wired</div><div class="stat-value emerald">${stats.fullyWired}</div><div class="stat-sub">Ready</div></div>
        <div class="stat-tile"><div class="stat-label">Needs Attention</div><div class="stat-value red">${stats.needsAttention}</div><div class="stat-sub">Missing</div></div>
    `;
}

function _extractHierarchy(webUrl) {
    if (!webUrl) return { lob: 'Unknown', site: '', subSite: '' };
    try {
        const url = new URL(webUrl);
        const parts = url.pathname.split('/').filter(Boolean);
        // Typical SharePoint: /sites/LOB/Site/SubSite/...
        return {
            lob: parts[1] || parts[0] || 'Root',     // e.g., "HR", "Finance"
            site: parts[2] || '',                       // e.g., "Onboarding", "AP"
            subSite: parts.slice(3).join('/') || ''     // e.g., "Forms/Lists"
        };
    } catch {
        const parts = webUrl.replace(/^https?:\/\/[^/]+/, '').split('/').filter(Boolean);
        return {
            lob: parts[1] || parts[0] || 'Root',
            site: parts[2] || '',
            subSite: parts.slice(3).join('/') || ''
        };
    }
}

function _extractSite(webUrl) {
    const h = _extractHierarchy(webUrl);
    return [h.lob, h.site, h.subSite].filter(Boolean).join('/');
}

function populateLobDropdown() {
    // Extract unique LOBs with counts
    const lobMap = {};
    _allRoutingData.forEach(r => {
        const h = _extractHierarchy(r.webUrl);
        lobMap[h.lob] = (lobMap[h.lob] || 0) + 1;
    });
    const lobs = Object.keys(lobMap).sort();

    const dd = document.getElementById('linkage-lob');
    if (!dd) return;
    let html = '<option value="">— Select LOB —</option>';
    html += `<option value="__all">All LOBs (${_allRoutingData.length})</option>`;
    lobs.forEach(lob => {
        html += `<option value="${esc(lob)}">${esc(lob)} (${lobMap[lob]})</option>`;
    });
    dd.innerHTML = html;

    // Reset downstream
    const siteDD = document.getElementById('linkage-site-filter');
    const subDD = document.getElementById('linkage-subsite');
    if (siteDD) { siteDD.innerHTML = '<option value="">— Select site —</option>'; siteDD.disabled = true; }
    if (subDD) { subDD.innerHTML = '<option value="">All Sub-sites</option>'; subDD.disabled = true; }
}

// Alias for backward compat
function populateSiteDropdown() { populateLobDropdown(); }

function onLobChange() {
    const lob = document.getElementById('linkage-lob')?.value || '';
    const siteDD = document.getElementById('linkage-site-filter');
    const subDD = document.getElementById('linkage-subsite');

    // Reset sub-site
    if (subDD) { subDD.innerHTML = '<option value="">All Sub-sites</option>'; subDD.disabled = true; }

    if (!lob || lob === '__all') {
        if (siteDD) { siteDD.innerHTML = '<option value="">— Select site —</option>'; siteDD.disabled = !lob; }
        _linkagePage = 1;
        renderLinkagePage();
        return;
    }

    // Populate sites for this LOB
    const siteMap = {};
    _allRoutingData.forEach(r => {
        const h = _extractHierarchy(r.webUrl);
        if (h.lob === lob && h.site) {
            siteMap[h.site] = (siteMap[h.site] || 0) + 1;
        }
    });
    const sites = Object.keys(siteMap).sort();

    let html = '<option value="">All Sites</option>';
    sites.forEach(s => {
        html += `<option value="${esc(s)}">${esc(s)} (${siteMap[s]})</option>`;
    });
    siteDD.innerHTML = html;
    siteDD.disabled = false;

    _linkagePage = 1;
    renderLinkagePage();
}

function onSiteChange() {
    const lob = document.getElementById('linkage-lob')?.value || '';
    const site = document.getElementById('linkage-site-filter')?.value || '';
    const subDD = document.getElementById('linkage-subsite');

    if (!site) {
        if (subDD) { subDD.innerHTML = '<option value="">All Sub-sites</option>'; subDD.disabled = true; }
        _linkagePage = 1;
        renderLinkagePage();
        return;
    }

    // Populate sub-sites
    const subMap = {};
    _allRoutingData.forEach(r => {
        const h = _extractHierarchy(r.webUrl);
        if (h.lob === lob && h.site === site && h.subSite) {
            const sub = h.subSite.split('/')[0]; // First level of sub-site
            subMap[sub] = (subMap[sub] || 0) + 1;
        }
    });
    const subs = Object.keys(subMap).sort();

    let html = '<option value="">All Sub-sites</option>';
    subs.forEach(s => {
        html += `<option value="${esc(s)}">${esc(s)} (${subMap[s]})</option>`;
    });
    subDD.innerHTML = html;
    subDD.disabled = subs.length === 0;

    _linkagePage = 1;
    renderLinkagePage();
}

function onLinkageSiteChange() {
    _linkagePage = 1;
    renderLinkagePage();
}

function _getFilteredRouting() {
    let filtered = _allRoutingData;
    const lob = document.getElementById('linkage-lob')?.value || '';
    const site = document.getElementById('linkage-site-filter')?.value || '';
    const subSite = document.getElementById('linkage-subsite')?.value || '';
    const searchQ = (document.getElementById('linkage-search')?.value || '').toLowerCase();

    if (lob && lob !== '__all') {
        filtered = filtered.filter(r => _extractHierarchy(r.webUrl).lob === lob);
    }
    if (site) {
        filtered = filtered.filter(r => _extractHierarchy(r.webUrl).site === site);
    }
    if (subSite) {
        filtered = filtered.filter(r => _extractHierarchy(r.webUrl).subSite.startsWith(subSite));
    }
    if (searchQ) {
        filtered = filtered.filter(r =>
            (r.workflowName || '').toLowerCase().includes(searchQ) ||
            (r.listTitle || '').toLowerCase().includes(searchQ)
        );
    }
    return filtered;
}

function renderLinkagePage() {
    const lob = document.getElementById('linkage-lob')?.value || '';
    const container = document.getElementById('routing-table-container');

    if (!lob) {
        container.innerHTML = '<div class="empty-state" style="padding:1.5rem;"><h3 style="font-size:0.85rem;">Select a LOB</h3><p style="font-size:0.78rem;">Choose a LOB / Category from the dropdown to progressively filter sites, sub-sites, and their forms.</p></div>';
        return;
    }

    const filtered = _getFilteredRouting();

    const totalPages = Math.max(1, Math.ceil(filtered.length / _linkagePageSize));
    if (_linkagePage > totalPages) _linkagePage = totalPages;
    const start = (_linkagePage - 1) * _linkagePageSize;
    const pageData = filtered.slice(start, start + _linkagePageSize);

    const infoEl = document.getElementById('linkage-page-info');
    if (infoEl) infoEl.textContent = filtered.length > 0
        ? `${start + 1}-${Math.min(start + _linkagePageSize, filtered.length)} of ${filtered.length}`
        : '0 forms';

    if (pageData.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:1rem;"><p style="font-size:0.78rem;">No forms found for this site. Run analysis first.</p></div>';
        return;
    }

    // Auto-load K2 templates for the datalist if not yet loaded
    if (_allK2Templates.length === 0) {
        fetchK2Templates().catch(() => {}); // Silent fetch for autosuggest
    }

    // Build datalist for template typeahead
    let datalistHtml = '<datalist id="tpl-datalist">';
    _allK2Templates.forEach(t => {
        datalistHtml += `<option value="${esc(t.procName)}">`;
    });
    datalistHtml += '</datalist>';

    let html = datalistHtml + `<table class="data-table">
        <thead><tr>
            <th style="width:120px;">Site</th>
            <th>Form Name</th>
            <th style="width:200px;">Workflow Template</th>
            <th style="width:80px;">Complexity</th>
            <th>SmartObject</th><th>SmartForm</th>
            <th style="width:55px;"></th>
        </tr></thead><tbody>`;

    pageData.forEach((r, idx) => {
        const tierBadge = r.tier === 'Tier 1' ? 'simple' : r.tier === 'Tier 2' ? 'medium' : r.tier === 'Tier 3' ? 'complex' : 'critical';

        const h = _extractHierarchy(r.webUrl);
        const siteLabel = [h.site, h.subSite].filter(Boolean).join('/') || h.lob;

        const soStatus = r.smartObject
            ? (r.smartObject.status === 'deployed'
                ? `<span style="color:var(--accent-emerald); font-size:0.70rem;">✓ ${esc(r.smartObject.name)}</span>`
                : `<span style="color:var(--accent-amber); font-size:0.70rem;">⚙ ${esc(r.smartObject.name)}</span>`)
            : '<span style="color:var(--accent-red); font-size:0.70rem;">—</span>';

        const sfStatus = r.smartForm
            ? (r.smartForm.status === 'deployed'
                ? `<span style="color:var(--accent-emerald); font-size:0.70rem;">✓ ${esc(r.smartForm.name)}</span>`
                : `<span style="color:var(--accent-amber); font-size:0.70rem;">⚙ ${esc(r.smartForm.name)}</span>`)
            : '<span style="color:var(--accent-red); font-size:0.70rem;">—</span>';

        // Template typeahead input
        const currentTpl = r.templateName || '';
        const borderColor = r.overridden ? 'var(--accent-amber)' : 'var(--border-subtle)';
        const tplCell = `<input class="form-input" list="tpl-datalist" value="${esc(currentTpl)}"
                          style="font-size:0.70rem; padding:2px 6px; width:100%; border-color:${borderColor};"
                          placeholder="Type template name..."
                          id="tpl-input-${r.id}" data-row-id="${r.id}" data-orig="${esc(currentTpl)}"
                          onchange="onTemplateInput(this, ${r.id})">`;

        // Per-row Push to K2 button
        const bound = r.readiness === 'pushed';
        const bindLabel = bound ? '✓ Bound' : 'Bind';
        const bindClass = bound ? 'btn-outline' : (r.templateName ? 'btn-primary' : 'btn-outline');
        const bindDisabled = (!r.templateName && !bound) ? 'disabled' : (bound ? 'disabled' : '');
        const saveBtn = `<button class="btn ${bindClass} btn-sm" style="font-size:0.58rem; padding:2px 6px; white-space:nowrap;" 
                          id="save-btn-${r.id}" onclick="bindWorkflow(${r.id})" ${bindDisabled} title="Bind workflow template to SmartForm">${bindLabel}</button>`;

        html += `<tr>
            <td style="font-size:0.68rem; color:var(--text-muted); max-width:120px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;" title="${esc(r.webUrl)}">${esc(siteLabel)}</td>
            <td>
                <div style="font-size:0.76rem; font-weight:600; color:var(--text-primary);">${esc(r.listTitle || r.workflowName)}</div>
            </td>
            <td>${tplCell}</td>
            <td style="text-align:center;"><span class="badge badge-${tierBadge}" style="font-size:0.60rem;">${r.tier}</span></td>
            <td>${soStatus}</td>
            <td>${sfStatus}</td>
            <td style="text-align:center;">${saveBtn}</td>
        </tr>`;
    });

    html += '</tbody></table>';

    // Pagination
    if (totalPages > 1) {
        html += '<div style="display:flex; justify-content:center; gap:6px; padding:0.5rem;">';
        html += `<button class="btn btn-outline btn-sm" ${_linkagePage <= 1 ? 'disabled' : ''} onclick="_linkagePage--; renderLinkagePage();">‹</button>`;
        for (let p = Math.max(1, _linkagePage - 3); p <= Math.min(totalPages, _linkagePage + 3); p++) {
            html += `<button class="btn ${p === _linkagePage ? 'btn-primary' : 'btn-outline'} btn-sm" onclick="_linkagePage=${p}; renderLinkagePage();">${p}</button>`;
        }
        html += `<button class="btn btn-outline btn-sm" ${_linkagePage >= totalPages ? 'disabled' : ''} onclick="_linkagePage++; renderLinkagePage();">›</button>`;
        html += '</div>';
    }

    container.innerHTML = html;
}

function onTemplateInput(inputEl, rowId) {
    const newVal = inputEl.value;
    const origVal = inputEl.dataset.orig || '';
    const row = _allRoutingData.find(r => r.id === rowId);
    if (!row) return;

    const saveBtn = document.getElementById(`save-btn-${rowId}`);
    if (newVal !== origVal) {
        row.templateName = newVal;
        row._dirty = true;
        inputEl.style.borderColor = 'var(--accent-amber)';
        if (saveBtn) { saveBtn.disabled = false; saveBtn.classList.add('btn-primary'); saveBtn.classList.remove('btn-outline'); }
    } else {
        row._dirty = false;
        inputEl.style.borderColor = 'var(--border-subtle)';
        if (saveBtn) { saveBtn.disabled = true; saveBtn.classList.remove('btn-primary'); saveBtn.classList.add('btn-outline'); }
    }
}

async function bindWorkflow(rowId) {
    const row = _allRoutingData.find(r => r.id === rowId);
    if (!row) return;
    const btn = document.getElementById(`save-btn-${rowId}`);
    if (btn) { btn.textContent = '⏳'; btn.disabled = true; }

    try {
        // Step 1: Save mapping to SQLite
        if (row._dirty) {
            await fetch(`${API}/api/workflow-routing/${rowId}`, {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ templateName: row.templateName })
            });
            row._dirty = false;
            row.overridden = true;
        }

        // Step 2: Bind workflow template to SmartForm
        const res = await fetch(`${API}/api/workflow-routing/${rowId}/bind`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            row.readiness = 'pushed';
            if (btn) { btn.textContent = '✓ Bound'; btn.classList.remove('btn-primary'); btn.classList.add('btn-outline'); }
            const input = document.getElementById(`tpl-input-${rowId}`);
            if (input) input.style.borderColor = 'var(--accent-emerald)';
            showToast(`Bound: ${row.listTitle || row.workflowName} → ${row.templateName}`, 'success');
        } else {
            if (btn) { btn.textContent = 'Bind'; btn.disabled = false; }
            showToast(`Bind failed: ${data.error}`, 'error');
        }
    } catch (err) {
        if (btn) { btn.textContent = 'Bind'; btn.disabled = false; }
        showToast('Bind error: ' + err.message, 'error');
    }
}
function renderBPList(blueprints) {
    const container = document.getElementById('bp-list-container');
    if (!blueprints || blueprints.length === 0) {
        container.innerHTML = '<div class="empty-state" style="padding:2rem;"><h3>No Workflows Generated</h3></div>';
        return;
    }

    // Enable deploy all if there are pending blueprints
    const pendingBPs = blueprints.filter(b => b.status !== 'completed');
    const deployAllBtn = document.getElementById('btn-deploy-all-wf');
    if (deployAllBtn) deployAllBtn.disabled = pendingBPs.length === 0;

    let html = `<table class="data-table">
        <thead><tr>
            <th>Workflow</th><th>Site</th><th>Complexity</th><th>Steps</th>
            <th>Est. Effort</th><th>Status</th><th>Actions</th>
        </tr></thead><tbody>`;

    blueprints.forEach(bp => {
        const statusClass = bp.status === 'completed' ? 'simple' :
                           bp.status === 'in-progress' ? 'medium' : 'complex';

        html += `<tr class="${selectedBPId === bp.id ? 'selected' : ''}" style="cursor:pointer;" onclick="selectBlueprint('${bp.id}')">
            <td style="color:var(--text-primary); font-weight:600;">
                <div style="display:flex;align-items:center;gap:8px;">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="var(--accent-amber)" stroke-width="2" width="16" height="16"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
                    ${esc(bp.workflowName)}
                </div>
            </td>
            <td style="max-width:180px; overflow:hidden; text-overflow:ellipsis; font-size:0.75rem;">${esc(bp.webUrl || '')}</td>
            <td><span class="badge badge-${bp.complexity}">${bp.complexity}</span></td>
            <td>${bp.stepCount}</td>
            <td style="font-weight:600; color:var(--accent-amber);">${bp.estimatedHours}h</td>
            <td>
                <select class="form-select" style="font-size:0.72rem; padding:2px 6px; min-width:100px;" onchange="event.stopPropagation(); updateBPStatus('${bp.id}', this.value)">
                    <option value="pending" ${bp.status === 'pending' ? 'selected' : ''}>Pending</option>
                    <option value="in-progress" ${bp.status === 'in-progress' ? 'selected' : ''}>In Progress</option>
                    <option value="completed" ${bp.status === 'completed' ? 'selected' : ''}>Completed</option>
                </select>
            </td>
            <td>
                <button class="btn btn-outline btn-sm" onclick="event.stopPropagation(); selectBlueprint('${bp.id}')">Detail</button>
                ${bp.status !== 'completed' ? `<button class="btn btn-success btn-sm" onclick="event.stopPropagation(); deployBlueprint('${bp.id}')">Deploy</button>` : '<span class="badge badge-simple">✓ Deployed</span>'}
            </td>
        </tr>`;
    });

    html += '</tbody></table>';
    container.innerHTML = html;
}

async function selectBlueprint(id) {
    selectedBPId = id;
    try {
        const res = await fetch(`${API}/api/blueprints/${id}`);
        const bp = await res.json();
        renderBPDetail(bp);
        document.getElementById('btn-export-bp').style.display = 'inline-flex';
        await loadBlueprints();
    } catch (err) {
        showToast('Failed to load workflow detail', 'error');
    }
}

function renderBPDetail(bp) {
    let html = '';

    // Prerequisites
    html += `<div class="detail-section">
        <div class="detail-section-title">Prerequisites</div>
        <table class="data-table"><thead><tr><th>Item</th><th>Status</th><th>Detail</th></tr></thead><tbody>`;
    bp.prerequisites.forEach(p => {
        const cls = p.status === 'ready' ? 'simple' : 'complex';
        html += `<tr><td style="font-weight:500;">${esc(p.item)}</td><td><span class="badge badge-${cls}">${p.status}</span></td><td style="font-size:0.72rem;">${esc(p.detail)}</td></tr>`;
    });
    html += '</tbody></table></div>';

    // Steps
    html += `<div class="detail-section">
        <div class="detail-section-title">Step-by-Step K2 Activities (${bp.steps.length} steps)</div>`;

    bp.steps.forEach(step => {
        const stepColor = step.complexity === 'critical' ? 'var(--accent-red)' :
                         step.complexity === 'complex' ? 'var(--accent-amber)' :
                         step.complexity === 'medium' ? 'var(--accent-blue)' : 'var(--accent-emerald)';

        html += `<div style="border:1px solid var(--border-subtle); border-radius:var(--radius-sm); padding:12px; margin-bottom:8px; background:var(--bg-elevated);">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px;">
                <div style="display:flex; align-items:center; gap:8px;">
                    <span style="background:${stepColor}; color:#fff; width:24px; height:24px; border-radius:50%; display:flex; align-items:center; justify-content:center; font-weight:700; font-size:0.7rem;">${step.stepNumber}</span>
                    <div>
                        <div style="font-weight:600; color:var(--text-primary); font-size:0.82rem;">${esc(step.spdAction)}</div>
                        <div style="font-size:0.7rem; color:var(--text-muted);">${esc(step.category)} → <span style="color:var(--accent-cyan);">${esc(step.k2Activity)}</span></div>
                    </div>
                </div>
                <div style="text-align:right;">
                    <span class="badge badge-${step.complexity}">${step.complexity}</span>
                    <div style="font-size:0.65rem; color:var(--text-muted); margin-top:2px;">~${step.estimatedMinutes} min</div>
                </div>
            </div>
            <ol style="margin:0; padding-left:18px; color:var(--text-secondary); font-size:0.78rem; line-height:1.7;">`;
        step.instructions.forEach(inst => {
            html += `<li>${esc(inst)}</li>`;
        });
        html += '</ol></div>';
    });

    html += '</div>';

    // Designer notes
    if (bp.designerNotes && bp.designerNotes.length > 0) {
        html += `<div class="detail-section">
            <div class="detail-section-title" style="color:var(--accent-amber);">Designer Notes</div>
            <ul style="padding-left:18px; font-size:0.82rem; color:var(--text-secondary); line-height:1.8;">`;
        bp.designerNotes.forEach(n => { html += `<li>${esc(n)}</li>`; });
        html += '</ul></div>';
    }

    document.getElementById('bp-detail-container').innerHTML = html;
}

async function updateBPStatus(id, status) {
    try {
        await fetch(`${API}/api/blueprints/${id}/status`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ status })
        });
        showToast(`Workflow status: ${status}`, 'success');
        await loadBlueprints();
    } catch (err) {
        showToast('Failed to update status', 'error');
    }
}

function exportBlueprintHtml() {
    if (!selectedBPId) return;
    window.open(`${API}/api/blueprints/${selectedBPId}/html`, '_blank');
}

async function deployBlueprint(id) {
    try {
        showToast('Deploying workflow to K2...', 'info');
        const res = await fetch(`${API}/api/blueprints/${id}/deploy`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`Workflow "${data.deployment.displayName}" deployed ✓ (${data.deployment.activities} activities, ${data.deployment.lines} lines)`, 'success');
        } else {
            showToast(`Workflow deploy failed: ${data.error}`, 'error');
        }

        await loadBlueprints();
    } catch (err) {
        showToast('Workflow deploy failed: ' + err.message, 'error');
    }
}

async function deployAllBlueprints() {
    try {
        showToast('Deploying all workflows to K2...', 'info');
        const btn = document.getElementById('btn-deploy-all-wf');
        if (btn) btn.disabled = true;

        const res = await fetch(`${API}/api/blueprints/deploy-all`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            showToast(`Batch deployment: ${data.deployed}/${data.total} workflows deployed` + (data.failed > 0 ? ` (${data.failed} failed)` : ''), data.failed > 0 ? 'error' : 'success');
        } else {
            showToast('Batch deployment failed', 'error');
        }

        await loadBlueprints();
    } catch (err) {
        showToast('Batch deploy failed: ' + err.message, 'error');
        const btn = document.getElementById('btn-deploy-all-wf');
        if (btn) btn.disabled = false;
    }
}

// ── Phase 7-8: Validation & Cutover ──────────────────────────────

async function runValidation() {
    try {
        showToast('Running cross-phase validation...', 'info');
        const res = await fetch(`${API}/api/validation/run`, { method: 'POST' });
        const { report } = await res.json();

        // Stats
        const scoreColor = report.readinessScore >= 90 ? 'emerald' : report.readinessScore >= 70 ? 'amber' : 'red';
        document.getElementById('val-stats').innerHTML = `
            <div class="stat-tile"><div class="stat-label">Readiness</div><div class="stat-value ${scoreColor}">${report.readinessScore}%</div><div class="stat-sub">${report.readinessLevel}</div></div>
            <div class="stat-tile"><div class="stat-label">Passed</div><div class="stat-value emerald">${report.passed}</div><div class="stat-sub">of ${report.total}</div></div>
            <div class="stat-tile"><div class="stat-label">Failed</div><div class="stat-value red">${report.failed}</div></div>
            <div class="stat-tile"><div class="stat-label">Critical Blockers</div><div class="stat-value" style="color:var(--accent-amber)">${report.criticalBlocking}</div></div>
        `;

        // GO/NO-GO badge
        const badge = document.getElementById('go-nogo-badge');
        const isReady = report.readinessScore >= 90 && report.criticalBlocking === 0;
        badge.textContent = isReady ? 'GO' : 'NO-GO';
        badge.style.background = isReady ? 'var(--accent-emerald)' : 'var(--accent-red)';
        badge.style.color = '#fff';

        document.getElementById('badge-cutover').textContent = report.readinessScore + '%';

        // Results table
        let html = `<table class="data-table">
            <thead><tr><th>Rule</th><th>Phase</th><th>Severity</th><th>Check</th><th>Result</th><th>Fix</th></tr></thead><tbody>`;

        report.results.forEach(r => {
            const sevCls = r.severity === 'critical' ? 'critical' : r.severity === 'warning' ? 'complex' : 'medium';
            html += `<tr>
                <td style="font-weight:500; font-size:0.72rem; color:var(--text-muted);">${r.ruleId}</td>
                <td>Phase ${r.phase}</td>
                <td><span class="badge badge-${sevCls}">${r.severity}</span></td>
                <td style="font-size:0.78rem;">${esc(r.label)}</td>
                <td>${r.passed ? '<span style="color:var(--accent-emerald);">\u2713 Pass</span>' : '<span style="color:var(--accent-red);">\u2717 Fail</span>'}</td>
                <td style="font-size:0.72rem; color:var(--accent-cyan);">${r.fix ? esc(r.fix) : '\u2014'}</td>
            </tr>`;
        });

        html += '</tbody></table>';
        document.getElementById('val-results-container').innerHTML = html;
        showToast(`Validation complete: ${report.readinessScore}% ready`, report.readinessScore >= 90 ? 'success' : 'warning');

    } catch (err) {
        showToast('Validation failed: ' + err.message, 'error');
    }
}

async function loadChecklist() {
    try {
        const res = await fetch(`${API}/api/cutover/checklist`);
        const data = await res.json();
        renderChecklist(data);
    } catch (err) {
        console.error('Checklist load error:', err);
    }
}

function renderChecklist(data) {
    const { categories, stats } = data;
    document.getElementById('checklist-progress').textContent =
        `${stats.checked}/${stats.total} complete (${stats.completionPct}%) — Critical: ${stats.criticalChecked}/${stats.criticalTotal}`;

    let html = '';
    for (const [catName, items] of Object.entries(categories)) {
        html += `<div class="detail-section">
            <div class="detail-section-title">${esc(catName)}</div>`;
        items.forEach(item => {
            html += `<div style="display:flex;align-items:center;gap:10px;padding:6px 0;border-bottom:1px solid var(--border-subtle);">
                <input type="checkbox" ${item.checked ? 'checked' : ''} onchange="toggleChecklistItem('${item.id}', this.checked)"
                    style="width:18px;height:18px;accent-color:var(--accent-emerald);cursor:pointer;">
                <span style="font-size:0.82rem; color:${item.checked ? 'var(--text-muted)' : 'var(--text-primary)'}; ${item.checked ? 'text-decoration:line-through;' : ''}">
                    ${esc(item.item)}
                </span>
                ${item.critical ? '<span class="badge badge-critical" style="font-size:0.6rem;">CRITICAL</span>' : ''}
                ${item.checkedAt ? `<span style="font-size:0.65rem; color:var(--text-muted); margin-left:auto;">${new Date(item.checkedAt).toLocaleString()}</span>` : ''}
            </div>`;
        });
        html += '</div>';
    }

    document.getElementById('checklist-container').innerHTML = html;
}

async function toggleChecklistItem(id, checked) {
    try {
        const res = await fetch(`${API}/api/cutover/checklist/${id}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ checked })
        });
        const data = await res.json();
        if (data.success) {
            renderChecklist(data.checklist);

            const goNoGo = data.checklist.stats.goNoGo;
            const badge = document.getElementById('go-nogo-badge');
            badge.textContent = goNoGo;
            badge.style.background = goNoGo === 'GO' ? 'var(--accent-emerald)' : 'var(--accent-red)';
            badge.style.color = '#fff';
        }
    } catch (err) {
        showToast('Failed to update checklist', 'error');
    }
}

async function loadRollbackPlan() {
    try {
        const res = await fetch(`${API}/api/cutover/rollback`);
        const plan = await res.json();

        let html = `<div class="detail-section">
            <div class="detail-section-title" style="color:var(--accent-amber);">${esc(plan.title)}</div>
            <div style="margin-bottom:1rem;">
                <strong style="font-size:0.78rem; color:var(--accent-red);">Trigger Conditions:</strong>
                <ul style="padding-left:18px; margin:6px 0; font-size:0.78rem; line-height:1.7;">`;
        plan.triggerConditions.forEach(c => { html += `<li>${esc(c)}</li>`; });
        html += '</ul></div>';

        html += '<div style="margin-bottom:1rem;">';
        plan.steps.forEach(step => {
            html += `<div style="border:1px solid var(--border-subtle); border-radius:var(--radius-sm); padding:10px; margin-bottom:6px; background:var(--bg-elevated);">
                <div style="display:flex;justify-content:space-between;align-items:center;">
                    <div style="display:flex;align-items:center;gap:8px;">
                        <span style="background:var(--accent-amber); color:#fff; width:22px; height:22px; border-radius:50%; display:flex; align-items:center; justify-content:center; font-weight:700; font-size:0.7rem;">${step.order}</span>
                        <strong style="font-size:0.82rem; color:var(--text-primary);">${esc(step.action)}</strong>
                    </div>
                    <span style="font-size:0.7rem; color:var(--text-muted);">~${step.estimatedMinutes} min</span>
                </div>
                <p style="margin:4px 0 0 30px; font-size:0.78rem; color:var(--text-secondary);">${esc(step.detail)}</p>
            </div>`;
        });
        html += '</div>';

        // Data protection
        html += `<div style="background:rgba(16,185,129,0.08); border:1px solid rgba(16,185,129,0.3); border-radius:var(--radius-sm); padding:12px;">
            <strong style="color:var(--accent-emerald); font-size:0.82rem;">✅ ${esc(plan.dataProtection.title)}</strong>
            <ul style="padding-left:18px; margin:8px 0 0; font-size:0.78rem; color:var(--text-secondary); line-height:1.7;">`;
        plan.dataProtection.points.forEach(p => { html += `<li>${esc(p)}</li>`; });
        html += '</ul></div>';

        html += `<div style="margin-top:1rem; text-align:center; font-size:0.8rem; color:var(--text-muted);">
            Total estimated rollback time: <strong style="color:var(--accent-amber);">${plan.totalEstimatedMinutes} minutes (~${Math.round(plan.totalEstimatedMinutes / 60 * 10) / 10}h)</strong>
        </div></div>`;

        document.getElementById('rollback-container').innerHTML = html;
    } catch (err) {
        showToast('Failed to load rollback plan', 'error');
    }
}

// ── Utility ─────────────────────────────────────────────────

function esc(str) {
    if (!str) return '';
    const d = document.createElement('div');
    d.textContent = str;
    return d.innerHTML;
}

// ── K2 Connection (from Connections tab) ─────────────────────

async function saveK2Config() {
    const serverUrl = document.getElementById('k2-server-url-conn').value;
    const port = parseInt(document.getElementById('k2-server-port-conn').value) || 5555;
    const securityLabel = document.getElementById('k2-security-label-conn').value || 'K2';
    const brokerTypeEl = document.getElementById('k2-broker-type-conn');
    const brokerType = brokerTypeEl ? brokerTypeEl.value : 'SmartBox';
    const sqlServer = document.getElementById('k2-sql-server-conn').value;
    const sqlCatalog = document.getElementById('k2-sql-catalog-conn').value;
    const sqlUser = document.getElementById('k2-sql-user-conn').value;
    const sqlPassword = document.getElementById('k2-sql-pass-conn').value;
    const k2User = document.getElementById('k2-user-conn').value;
    const k2Password = document.getElementById('k2-user-pass-conn').value;
    const k2Domain = document.getElementById('k2-user-domain-conn').value;

    if (!serverUrl) { showToast('K2 server URL is required', 'error'); return; }

    try {
        const res = await fetch(`${API}/api/k2/configure`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ serverUrl, port, securityLabel, brokerType, sqlServer, sqlCatalog, sqlUser, sqlPassword, k2User, k2Password, k2Domain })
        });
        const data = await res.json();
        if (data.success) {
            showToast(`K2 configuration saved ✓ (${brokerType} broker)`, 'success');
            // Also sync to SmartObjects tab fields if they exist
            const soUrl = document.getElementById('k2-server-url');
            const soPort = document.getElementById('k2-server-port');
            const soLabel = document.getElementById('k2-security-label');
            const soBroker = document.getElementById('k2-broker-type');
            if (soUrl) soUrl.value = serverUrl;
            if (soPort) soPort.value = port;
            if (soLabel) soLabel.value = securityLabel;
            if (soBroker) soBroker.value = brokerType;
            updateK2ConnBadge(true);
        }
    } catch (err) {
        showToast('Failed to save K2 config', 'error');
    }
}

async function testK2FromConn() {
    const statusEl = document.getElementById('k2-conn-status');
    statusEl.innerHTML = '<div style="color:var(--accent-cyan);">⏳ Testing K2 server connection...</div>';
    showToast('Testing K2 connection...', 'info');

    // Save config first
    await saveK2Config();

    try {
        const res = await fetch(`${API}/api/k2/test`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            const info = data.serverInfo;
            statusEl.innerHTML = `
                <div style="color:var(--accent-emerald); font-weight:600; margin-bottom:4px;">✓ Connected</div>
                <div class="env-detail"><span class="env-detail-label">Version</span><span class="env-detail-value">${esc(info.serverVersion)}</span></div>
                <div class="env-detail"><span class="env-detail-label">Build</span><span class="env-detail-value">${esc(info.build)}</span></div>
                <div class="env-detail"><span class="env-detail-label">Database</span><span class="env-detail-value">${esc(info.database)}</span></div>
            `;
            updateK2ConnBadge(true);
            showToast('K2 server connected ✓', 'success');
        } else {
            statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${esc(data.error)}</span>`;
            updateK2ConnBadge(false);
            showToast('K2 connection failed', 'error');
        }
    } catch (err) {
        statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${err.message}</span>`;
        updateK2ConnBadge(false);
        showToast('K2 connection failed', 'error');
    }
}

async function testK2SqlFromConn() {
    // Save config first
    await saveK2Config();

    const statusEl = document.getElementById('k2-conn-status');
    statusEl.innerHTML = '<div style="color:var(--accent-cyan);">⏳ Testing SQL Server connectivity...</div>';

    try {
        const res = await fetch(`${API}/api/k2/test-sql`, { method: 'POST' });
        const data = await res.json();

        if (data.success) {
            statusEl.innerHTML = `
                <div style="color:var(--accent-emerald); font-weight:600; margin-bottom:4px;">✓ SQL Connected — ${esc(data.server)}</div>
                <div style="font-size:0.78rem; color:var(--text-secondary);">Databases: ${(data.databases || []).slice(0, 10).map(d => esc(d)).join(', ')}${(data.databases || []).length > 10 ? '...' : ''}</div>
            `;
            showToast('SQL connection successful ✓', 'success');
        } else {
            statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ SQL: ${esc(data.error)}</span>`;
            showToast('SQL connection failed', 'error');
        }
    } catch (err) {
        statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${err.message}</span>`;
        showToast('SQL test failed', 'error');
    }
}

function updateK2ConnBadge(connected) {
    const badge = document.getElementById('k2-conn-badge');
    if (badge) {
        badge.textContent = connected ? 'connected' : 'not connected';
        badge.style.background = connected ? 'rgba(16,185,129,0.15)' : '';
        badge.style.color = connected ? 'var(--accent-emerald)' : '';
        badge.style.border = connected ? '1px solid rgba(16,185,129,0.25)' : '';
    }
}

// Hydrate K2 fields from saved state on init
async function loadK2ConnState() {
    try {
        const res = await fetch(`${API}/api/k2/connection`);
        const data = await res.json();
        if (data.config && data.config.serverUrl) {
            const el = (id) => document.getElementById(id);
            if (el('k2-server-url-conn')) el('k2-server-url-conn').value = data.config.serverUrl || '';
            if (el('k2-server-port-conn')) el('k2-server-port-conn').value = data.config.port || 5555;
            if (el('k2-security-label-conn')) el('k2-security-label-conn').value = data.config.securityLabel || 'K2';
            if (el('k2-sql-server-conn')) el('k2-sql-server-conn').value = data.config.sqlServer || '';
            if (el('k2-sql-catalog-conn')) el('k2-sql-catalog-conn').value = data.config.sqlCatalog || 'K2';
            if (el('k2-user-conn')) el('k2-user-conn').value = data.config.k2User || '';
            if (el('k2-user-domain-conn')) el('k2-user-domain-conn').value = data.config.k2Domain || '';
            // Don't restore password for security — user must re-enter after restart
            updateK2ConnBadge(!!data.config.serverUrl);
        }
    } catch (e) { /* ignore on fresh start */ }
}

// ── XSN Upload (Discovery) ─────────────────────────────────

(function initXsnUpload() {
    const zone = document.getElementById('xsn-upload-zone');
    const fileInput = document.getElementById('xsn-file-input');
    if (!zone || !fileInput) return;

    zone.addEventListener('click', () => fileInput.click());
    zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('dragover'); });
    zone.addEventListener('dragleave', () => zone.classList.remove('dragover'));
    zone.addEventListener('drop', (e) => {
        e.preventDefault();
        zone.classList.remove('dragover');
        handleXsnFiles(e.dataTransfer.files);
    });
    fileInput.addEventListener('change', () => {
        handleXsnFiles(fileInput.files);
        fileInput.value = '';
    });
})();

async function handleXsnFiles(files) {
    if (!files || files.length === 0) return;

    const progressEl = document.getElementById('xsn-upload-progress');
    const progressBar = document.getElementById('xsn-progress-bar');
    const statusEl = document.getElementById('xsn-upload-status');
    const resultsEl = document.getElementById('xsn-results');

    progressEl.style.display = 'block';
    progressBar.style.width = '20%';
    statusEl.textContent = `Uploading ${files.length} file(s)...`;

    const formData = new FormData();
    for (const file of files) {
        formData.append('xsnFiles', file);
    }

    try {
        progressBar.style.width = '50%';
        statusEl.textContent = 'Parsing XSN form templates...';

        const res = await fetch(`${API}/api/discovery/upload-xsn`, {
            method: 'POST',
            body: formData
        });
        const data = await res.json();

        progressBar.style.width = '100%';

        if (data.success) {
            statusEl.innerHTML = `<span style="color:var(--accent-emerald);">✓ ${data.message}</span>`;
            showToast(`XSN parsed: ${data.parsed} forms extracted`, 'success');

            // Update badge
            const badge = document.getElementById('xsn-status-badge');
            badge.textContent = `${data.totalForms} parsed`;
            badge.style.background = 'rgba(16,185,129,0.15)';
            badge.style.color = 'var(--accent-emerald)';
            badge.style.border = '1px solid rgba(16,185,129,0.25)';

            // Show results table
            if (data.forms && data.forms.length > 0) {
                let html = `<table class="data-table"><thead><tr>
                    <th>Form</th><th>Fields</th><th>Views</th><th>Data Connections</th>
                </tr></thead><tbody>`;
                data.forms.forEach(f => {
                    html += `<tr>
                        <td style="font-weight:500; color:var(--text-primary);">${esc(f.formName || f.xsnFile || f.id)}</td>
                        <td>${f.fields ? f.fields.length : 0}</td>
                        <td>${f.views ? f.views.length : 0}</td>
                        <td>${f.dataConnections ? f.dataConnections.length : 0}</td>
                    </tr>`;
                });
                html += '</tbody></table>';
                resultsEl.innerHTML = html;
                resultsEl.style.display = 'block';
            }

            // Show errors if any
            if (data.log && data.log.length > 0) {
                const errors = data.log.filter(l => l.level === 'error');
                if (errors.length > 0) {
                    statusEl.innerHTML += `<br><span style="color:var(--accent-amber);">⚠ ${errors.length} errors — check console</span>`;
                }
            }
        } else {
            statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${data.error || 'Upload failed'}</span>`;
            showToast('XSN upload failed', 'error');
        }
    } catch (err) {
        statusEl.innerHTML = `<span style="color:var(--accent-red);">✗ ${err.message}</span>`;
        showToast('XSN upload error', 'error');
    }

    setTimeout(() => {
        progressEl.style.display = 'none';
        progressBar.style.width = '0%';
    }, 2000);
}

// Load existing XSN parse state on init
async function loadXsnState() {
    try {
        const res = await fetch(`${API}/api/discovery/xsn-forms`);
        const data = await res.json();
        if (data.success && data.count > 0) {
            const badge = document.getElementById('xsn-status-badge');
            badge.textContent = `${data.count} parsed`;
            badge.style.background = 'rgba(16,185,129,0.15)';
            badge.style.color = 'var(--accent-emerald)';
            badge.style.border = '1px solid rgba(16,185,129,0.25)';

            const resultsEl = document.getElementById('xsn-results');
            let html = `<table class="data-table"><thead><tr>
                <th>Form</th><th>Fields</th><th>Views</th><th>Data Conn</th>
            </tr></thead><tbody>`;
            data.forms.forEach(f => {
                html += `<tr>
                    <td style="font-weight:500; color:var(--text-primary);">${esc(f.formName)}</td>
                    <td>${f.fieldCount}</td>
                    <td>${f.viewCount}</td>
                    <td>${f.dataConnectionCount}</td>
                </tr>`;
            });
            html += '</tbody></table>';
            resultsEl.innerHTML = html;
            resultsEl.style.display = 'block';
        }
    } catch (e) { /* ignore */ }
}

// ── Init ───────────────────────────────────────────────────

loadConnections();
loadK2ConnState();
loadXsnState();

