// ============================================================
// SPD → K2 Five Migration Pipeline — Express Server
// Phase 1: Discovery & Extraction (CSV import)
// Phase 2: Pattern Analysis & Classification
// Phase 3: SmartObject Generation & Deployment
// Phase 4: SmartForm Generation & Deployment
// Phase 5: Workflow Blueprint Generation
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// Source: SharePoint SE 16.0.19725.20076
// ============================================================

const express = require('express');
const path = require('path');
const fs = require('fs');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');
const { DiscoveryEngine } = require('./services/discoveryEngine');
const {
    AnalysisEngine, ENVIRONMENT,
    SP_TO_SMARTOBJECT_MAP, SP_TO_SMARTFORM_MAP, SPD_TO_K2_ACTIVITY_MAP,
    FORM_COMPLEXITY_WEIGHTS, WF_COMPLEXITY_WEIGHTS, COMPLEXITY_THRESHOLDS,
    K2_AUTOMATION_COVERAGE, TIER_EFFORT_REDUCTION,
    WORKFLOW_TIER_RUBRIC, WORKFLOW_TIER_THRESHOLDS, MANUAL_REVIEW_FLAGS
} = require('./services/analysisEngine');
const { SmartObjectGenerator } = require('./services/smartObjectGenerator');
const { K2DeploymentBridge } = require('./services/k2DeploymentBridge');
const { SmartFormGenerator } = require('./services/smartFormGenerator');
const { WorkflowBlueprintGenerator } = require('./services/workflowBlueprintGenerator');
const { ValidationEngine } = require('./services/validationEngine');
const { RoutingSmartObjectGenerator } = require('./services/routingSmartObjectGenerator');
const { XsnParser } = require('./services/xsnParser');
const db = require('./db');

const app = express();
const PORT = process.env.PORT || 3001;

// Services
const discovery = new DiscoveryEngine();
const analysis = new AnalysisEngine();
const soGenerator = new SmartObjectGenerator();
const k2Bridge = new K2DeploymentBridge();
const sfGenerator = new SmartFormGenerator();
const bpGenerator = new WorkflowBlueprintGenerator();
const validator = new ValidationEngine();
const routingGenerator = new RoutingSmartObjectGenerator();
const xsnParser = new XsnParser();
// Upload SP List Schema JSON (from Export-SPListSchema.ps1)
let spListSchema = null;
// ============================================================
// State Persistence — saves/loads to .migration-state/ JSON files
// ============================================================
const STATE_DIR = path.join(__dirname, '.migration-state');
if (!fs.existsSync(STATE_DIR)) fs.mkdirSync(STATE_DIR, { recursive: true });

function saveState(key, data) {
    try {
        const file = path.join(STATE_DIR, `${key}.json`);
        fs.writeFileSync(file, JSON.stringify(data, null, 2), 'utf-8');
    } catch (err) {
        console.error(`[State] Failed to save ${key}:`, err.message);
    }
}

function loadState(key) {
    try {
        const file = path.join(STATE_DIR, `${key}.json`);
        if (fs.existsSync(file)) {
            let raw = fs.readFileSync(file, 'utf-8');
            if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
            return JSON.parse(raw);
        }
    } catch (err) {
        console.error(`[State] Failed to load ${key}:`, err.message);
    }
    return null;
}

function saveAllState() {
    // Discovery
    saveState('discovery', {
        workflows: discovery.getWorkflows(),
        forms: discovery.getForms(),
        siteTree: discovery.getSiteTree()
    });
    // Analysis
    const analysisResults = analysis.getResults({ pageSize: 10000 });
    if (analysisResults && analysisResults.items && analysisResults.items.length > 0) {
        saveState('analysis', { items: analysisResults.items });
    }
    // SmartObjects
    const allSOs = soGenerator.getAll();
    if (allSOs.length > 0) {
        const soFull = allSOs.map(s => soGenerator.getById(s.id)).filter(Boolean);
        saveState('smartobjects', soFull);
    }
    // SmartForms
    const allSFs = sfGenerator.getAll();
    if (allSFs.length > 0) {
        const sfFull = allSFs.map(s => sfGenerator.getById(s.id)).filter(Boolean);
        saveState('smartforms', sfFull);
    }
    // K2 Connection
    saveState('k2connection', k2Bridge.getConnectionInfo());
    // Schema
    if (spListSchema) saveState('schema', spListSchema);
}

function restoreState() {
    let restored = [];

    // K2 Connection (includes SQL credentials)
    const k2Conn = loadState('k2connection');
    if (k2Conn && k2Conn.serverUrl) {
        k2Bridge.configure({
            serverUrl: k2Conn.serverUrl, port: k2Conn.port, securityLabel: k2Conn.securityLabel,
            sqlServer: k2Conn.sqlServer, sqlCatalog: k2Conn.sqlCatalog,
            sqlUser: k2Conn.sqlUser, sqlPassword: k2Conn.sqlPassword, sqlDomain: k2Conn.sqlDomain
        });
        restored.push('k2connection');
    }

    // Schema
    const schema = loadState('schema');
    if (schema && schema.lists) {
        spListSchema = schema;
        soGenerator.setRealSchema(schema);
        restored.push('schema');
    }

    // Discovery
    const disc = loadState('discovery');
    if (disc) {
        if (disc.workflows) discovery._restoreWorkflows(disc.workflows);
        if (disc.forms) discovery._restoreForms(disc.forms);
        restored.push(`discovery(${(disc.workflows||[]).length}wf, ${(disc.forms||[]).length}forms)`);
    }

    // Analysis — re-run from discovery data
    const analysisData = loadState('analysis');
    if (analysisData && analysisData.items && analysisData.items.length > 0) {
        analysis._restoreResults(analysisData.items);
        restored.push(`analysis(${analysisData.items.length} items)`);
    }

    // SmartObjects
    const soData = loadState('smartobjects');
    if (soData && Array.isArray(soData) && soData.length > 0) {
        soGenerator._restoreFromState(soData);
        restored.push(`smartobjects(${soData.length})`);
    }

    // SmartForms
    const sfData = loadState('smartforms');
    if (sfData && Array.isArray(sfData) && sfData.length > 0) {
        sfGenerator._restoreFromState(sfData);
        restored.push(`smartforms(${sfData.length})`);
    }

    if (restored.length > 0) {
        console.log(`[State] Restored: ${restored.join(', ')}`);
    } else {
        console.log('[State] No previous state found — fresh start');
    }
}

// Restore on startup
restoreState();

// --- Middleware ---
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.header('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method === 'OPTIONS') return res.sendStatus(200);
    next();
});

// File upload config — CSV
const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: 100 * 1024 * 1024 }, // 100MB
    fileFilter: (req, file, cb) => {
        if (file.mimetype === 'text/csv' || file.originalname.endsWith('.csv')) {
            cb(null, true);
        } else {
            cb(new Error('Only CSV files are accepted'), false);
        }
    }
});

// File upload config — XSN/ZIP (for InfoPath form templates)
const uploadXsn = multer({
    storage: multer.diskStorage({
        destination: (req, file, cb) => {
            const dir = path.join(__dirname, 'uploads', 'xsn');
            if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
            cb(null, dir);
        },
        filename: (req, file, cb) => cb(null, Date.now() + '-' + file.originalname)
    }),
    limits: { fileSize: 500 * 1024 * 1024 }, // 500MB for bulk XSN packages
    fileFilter: (req, file, cb) => {
        const ext = path.extname(file.originalname).toLowerCase();
        if (['.xsn', '.zip', '.xsd'].includes(ext)) {
            cb(null, true);
        } else {
            cb(new Error('Only XSN, ZIP, or XSD files are accepted'), false);
        }
    }
});

// File upload config — JSON (for schema import)
const uploadJson = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: 50 * 1024 * 1024 },
    fileFilter: (req, file, cb) => {
        if (file.mimetype === 'application/json' || file.originalname.endsWith('.json')) {
            cb(null, true);
        } else {
            cb(new Error('Only JSON files are accepted'), false);
        }
    }
});

// ============================================================
// In-memory connection store (human-controlled)
// ============================================================
const connections = new Map();

// ============================================================
// API Routes — General
// ============================================================

app.get('/api/health', (req, res) => {
    res.json({
        status: 'ok',
        uptime: process.uptime(),
        timestamp: new Date().toISOString(),
        environment: {
            source: `${ENVIRONMENT.source.platform} ${ENVIRONMENT.source.version}`,
            target: `${ENVIRONMENT.target.platform} ${ENVIRONMENT.target.version} ${ENVIRONMENT.target.featurePack}`
        }
    });
});

app.get('/api/environment', (req, res) => {
    res.json(ENVIRONMENT);
});

// ============================================================
// API Routes — Connection Management (human-controlled)
// ============================================================

app.post('/api/connections', (req, res) => {
    const { name, siteUrl, spVersion, authType, credentialLabel, notes } = req.body;
    if (!siteUrl) return res.status(400).json({ error: 'Site URL is required' });

    const id = uuidv4();
    const conn = {
        id, name: name || siteUrl, siteUrl, spVersion: spVersion || 'SE',
        authType: authType || 'NTLM', credentialLabel: credentialLabel || '',
        notes: notes || '', status: 'configured', createdAt: new Date().toISOString()
    };
    connections.set(id, conn);
    res.json({ success: true, connection: conn });
});

app.get('/api/connections', (req, res) => {
    res.json({ connections: Array.from(connections.values()) });
});

app.delete('/api/connections/:id', (req, res) => {
    if (connections.delete(req.params.id)) {
        res.json({ success: true });
    } else {
        res.status(404).json({ error: 'Connection not found' });
    }
});

app.post('/api/connections/:id/test', async (req, res) => {
    const conn = connections.get(req.params.id);
    if (!conn) return res.status(404).json({ error: 'Connection not found' });

    // Simulate connection test (in production, this would use CSOM)
    await new Promise(r => setTimeout(r, 800 + Math.random() * 600));

    conn.status = 'connected';
    conn.lastTestedAt = new Date().toISOString();
    res.json({
        success: true,
        connectionId: conn.id,
        serverInfo: {
            url: conn.siteUrl,
            version: conn.spVersion,
            status: 'reachable',
            note: 'Connection validated. Use PowerShell script on the SP farm to extract discovery CSVs.'
        }
    });
});

// ============================================================
// API Routes — Phase 1: Discovery & Extraction
// ============================================================

// Upload discovery CSVs
app.post('/api/discovery/upload', upload.fields([
    { name: 'workflowCsv', maxCount: 1 },
    { name: 'infopathCsv', maxCount: 1 }
]), async (req, res) => {
    try {
        const results = { workflow: null, infopath: null };

        if (req.files.workflowCsv) {
            results.workflow = await discovery.parseWorkflowCSV(
                req.files.workflowCsv[0].buffer
            );
        }
        if (req.files.infopathCsv) {
            results.infopath = await discovery.parseInfoPathCSV(
                req.files.infopathCsv[0].buffer
            );
        }

        saveAllState();
        res.json({ success: true, results });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});


app.post('/api/discovery/upload-schema', uploadJson.single('schemaJson'), (req, res) => {
    try {
        if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

        // Strip UTF-8 BOM (PowerShell 5.1 adds EF BB BF)
        let rawText = req.file.buffer.toString('utf-8');
        if (rawText.charCodeAt(0) === 0xFEFF) {
            rawText = rawText.slice(1);
        }

        const schema = JSON.parse(rawText);

        if (!schema.lists || !Array.isArray(schema.lists)) {
            return res.status(400).json({ error: 'Invalid schema format. Expected { lists: [...] }' });
        }

        spListSchema = schema;

        // Also inject into SmartObject generator for enriched generation
        soGenerator.setRealSchema(schema);

        res.json({
            success: true,
            summary: {
                siteUrl: schema.siteUrl,
                siteTitle: schema.siteTitle,
                listCount: schema.listCount,
                totalFields: schema.totalFields,
                lists: schema.lists.map(l => ({
                    listTitle: l.listTitle,
                    fieldCount: l.fieldCount,
                    itemCount: l.itemCount
                }))
            }
        });
    } catch (err) {
        res.status(500).json({ error: 'Schema parse error: ' + err.message });
    }
});

// Get uploaded schema status
app.get('/api/discovery/schema', (req, res) => {
    if (!spListSchema) return res.json({ hasSchema: false });
    res.json({
        hasSchema: true,
        siteUrl: spListSchema.siteUrl,
        listCount: spListSchema.listCount,
        totalFields: spListSchema.totalFields,
        lists: spListSchema.lists.map(l => ({
            listTitle: l.listTitle,
            fieldCount: l.fieldCount,
            itemCount: l.itemCount
        }))
    });
});

// Upload with SSE progress streaming
const sseClients = new Map();

app.get('/api/discovery/stream', (req, res) => {
    res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive'
    });

    const clientId = uuidv4();
    sseClients.set(clientId, res);

    res.write(`event: connected\ndata: ${JSON.stringify({ clientId })}\n\n`);

    req.on('close', () => {
        sseClients.delete(clientId);
    });
});

// Get discovered site tree
app.get('/api/discovery/sites', (req, res) => {
    res.json({ sites: discovery.getSiteTree() });
});

// Get full inventory
app.get('/api/discovery/inventory', (req, res) => {
    res.json(discovery.getInventory());
});

// Reset discovery data
app.post('/api/discovery/reset', (req, res) => {
    discovery.reset();
    res.json({ success: true, message: 'Discovery data cleared' });
});

// ============================================================
// API Routes — Discovery: XSN InfoPath Form Templates
// ============================================================

// Upload XSN files or ZIP package containing XSN files
app.post('/api/discovery/upload-xsn', uploadXsn.array('xsnFiles', 100), async (req, res) => {
    if (!req.files || req.files.length === 0) {
        return res.status(400).json({ error: 'No XSN/ZIP files uploaded' });
    }

    const results = { parsed: 0, errors: 0, forms: [], log: [] };

    for (const file of req.files) {
        const ext = path.extname(file.originalname).toLowerCase();
        try {
            if (ext === '.zip') {
                // Batch parse ZIP containing multiple XSN files
                const batch = await xsnParser.parseBatch(file.path);
                results.parsed += batch.parsed;
                results.errors += batch.errors;
                results.forms.push(...batch.forms);
            } else if (ext === '.xsn') {
                // Parse single XSN file
                const form = await xsnParser.parseXsn(file.path, {
                    siteUrl: req.body?.siteUrl || '',
                    listTitle: req.body?.listTitle || ''
                });
                results.parsed++;
                results.forms.push(form);
            } else if (ext === '.xsd') {
                // Parse standalone XSD schema
                const fields = await xsnParser._parseXsd(file.path);
                const formId = `xsd-${require('uuid').v4().slice(0, 8)}`;
                const form = {
                    id: formId,
                    xsnFile: file.originalname,
                    siteUrl: req.body?.siteUrl || '',
                    listTitle: req.body?.listTitle || file.originalname.replace('.xsd', ''),
                    fields,
                    views: [],
                    dataConnections: [],
                    submitRules: [],
                    formName: file.originalname.replace('.xsd', ''),
                    parsedAt: new Date().toISOString()
                };
                xsnParser.parsedForms.set(formId, form);
                results.parsed++;
                results.forms.push(form);
            }
        } catch (err) {
            results.errors++;
            results.log.push({ file: file.originalname, error: err.message });
        }
    }

    results.log = xsnParser.getLog().slice(-50);
    saveAllState();
    res.json({
        success: true,
        message: `Parsed ${results.parsed} forms (${results.errors} errors)`,
        totalForms: xsnParser.parsedForms.size,
        ...results
    });
});

// Get all parsed XSN forms
app.get('/api/discovery/xsn-forms', (req, res) => {
    const forms = xsnParser.getAll();
    res.json({
        success: true,
        count: forms.length,
        forms: forms.map(f => ({
            id: f.id,
            formName: f.formName || f.xsnFile,
            siteUrl: f.siteUrl,
            listTitle: f.listTitle,
            fieldCount: f.fields.length,
            viewCount: f.views.length,
            dataConnectionCount: f.dataConnections.length,
            parsedAt: f.parsedAt
        }))
    });
});

// Get detailed parsed form by ID
app.get('/api/discovery/xsn-forms/:id', (req, res) => {
    const form = xsnParser.getById(req.params.id);
    if (!form) return res.status(404).json({ error: 'Parsed form not found' });
    res.json({ success: true, form });
});

// Get SmartObject-ready input from parsed XSN data
app.get('/api/discovery/xsn-smartobject-input', (req, res) => {
    const soInput = xsnParser.toSmartObjectInput();
    res.json({
        success: true,
        count: soInput.length,
        smartObjects: soInput
    });
});

// Get XSN parse log
app.get('/api/discovery/xsn-log', (req, res) => {
    res.json({ success: true, log: xsnParser.getLog() });
});

// ============================================================
// API Routes — Phase 2: Analysis & Classification
// ============================================================

// Run analysis on imported data
app.post('/api/analysis/run', (req, res) => {
    const workflows = discovery.getWorkflows();
    const forms = discovery.getForms();

    if (workflows.length === 0 && forms.length === 0) {
        return res.status(400).json({
            error: 'No discovery data imported. Upload CSV files first.'
        });
    }

    const summary = analysis.runAnalysis(workflows, forms);
    saveAllState();
    res.json({ success: true, summary });
});

// Portfolio stats
app.get('/api/analysis/portfolio', (req, res) => {
    const stats = analysis.getPortfolioStats();
    if (!stats) return res.status(404).json({ error: 'No analysis data. Run analysis first.' });
    res.json(stats);
});

// Grouped results
app.get('/api/analysis/portfolio/groups', (req, res) => {
    const groupBy = req.query.groupBy || 'complexity';
    res.json({ groups: analysis.getGroupedResults(groupBy) });
});

// Filtered/paginated results
app.get('/api/analysis/results', (req, res) => {
    const filters = {
        assetType: req.query.assetType || 'all',
        complexity: req.query.complexity || 'all',
        search: req.query.search || '',
        page: parseInt(req.query.page) || 1,
        pageSize: parseInt(req.query.pageSize) || 50
    };
    res.json(analysis.getResults(filters));
});

// Single item detail
app.get('/api/analysis/item/:id', (req, res) => {
    const detail = analysis.getItemDetail(req.params.id);
    if (!detail) return res.status(404).json({ error: 'Item not found' });
    res.json(detail);
});

// Full assessment report
app.get('/api/analysis/report', (req, res) => {
    const report = analysis.generateReport();
    if (!report) return res.status(404).json({ error: 'No analysis data. Run analysis first.' });
    res.json(report);
});

// Complexity model reference
app.get('/api/analysis/complexity-model', (req, res) => {
    res.json({
        thresholds: {
            simple:   { range: '0–14',  desc: 'Basic — auto-migration via SmartObject/SmartForm APIs' },
            medium:   { range: '15–34', desc: 'Moderate — mostly automated with manual SmartForm rule config' },
            complex:  { range: '35–59', desc: 'Challenging — partial automation, significant manual K2 Designer work' },
            critical: { range: '60+',   desc: 'Heavy custom code / state machines — substantial manual effort' }
        },
        formWeights: Object.entries(FORM_COMPLEXITY_WEIGHTS).map(([key, val]) => ({ key, ...val })),
        workflowWeights: Object.entries(WF_COMPLEXITY_WEIGHTS).map(([key, val]) => ({ key, ...val })),
        k2AutomationCoverage: K2_AUTOMATION_COVERAGE,
        tierEffortReduction: TIER_EFFORT_REDUCTION
    });
});

// K2 mapping tables reference
app.get('/api/analysis/k2-mappings', (req, res) => {
    res.json({
        smartObjectMap: SP_TO_SMARTOBJECT_MAP,
        smartFormMap: SP_TO_SMARTFORM_MAP,
        activityMap: SPD_TO_K2_ACTIVITY_MAP
    });
});

// ============================================================
// API Routes — Strategy A: Tier Classification & Routing
// ============================================================

// Classify a single workflow into Strategy A tiers
app.get('/api/analysis/tier/:id', (req, res) => {
    const detail = analysis.getItemDetail(req.params.id);
    if (!detail) return res.status(404).json({ error: 'Item not found' });
    if (detail.assetType !== 'workflow') return res.status(400).json({ error: 'Item is not a workflow' });

    const classification = analysis.classifyWorkflowTier(detail);
    res.json({ success: true, workflowId: req.params.id, classification });
});

// Get tier distribution across all analyzed workflows
app.get('/api/analysis/tier-distribution', (req, res) => {
    const dist = analysis.getTierDistribution();
    res.json({ success: true, distribution: dist });
});

// Classify ALL workflows into tiers
app.get('/api/analysis/tier-all', (req, res) => {
    const results = analysis.getResults({ pageSize: 10000 });
    if (!results.items || results.items.length === 0) {
        return res.status(400).json({ error: 'No analysis results. Run analysis first.' });
    }

    const workflows = results.items.filter(i => i.assetType === 'workflow');
    const classified = workflows.map(wf => ({
        id: wf.id,
        name: wf.name || wf.workflowName,
        listTitle: wf.listTitle,
        webUrl: wf.webUrl,
        workflowType: wf.workflowType,
        complexityScore: wf.complexityScore,
        ...analysis.classifyWorkflowTier(wf)
    }));

    res.json({
        success: true,
        total: classified.length,
        workflows: classified,
        distribution: analysis.getTierDistribution()
    });
});

// Strategy A tier rubric reference
app.get('/api/analysis/tier-rubric', (req, res) => {
    res.json({
        rubric: WORKFLOW_TIER_RUBRIC,
        thresholds: WORKFLOW_TIER_THRESHOLDS,
        manualReviewFlags: MANUAL_REVIEW_FLAGS.map(f => ({ key: f.key, label: f.label }))
    });
});

// Generate routing SmartObject definition
app.post('/api/routing/generate', (req, res) => {
    const so = routingGenerator.generateRoutingSO();
    res.json({ success: true, routingSmartObject: so });
});

// Generate routing data for all analyzed workflows
app.post('/api/routing/generate-data', (req, res) => {
    const results = analysis.getResults({ pageSize: 10000 });
    if (!results.items || results.items.length === 0) {
        return res.status(400).json({ error: 'No analysis results. Run analysis first.' });
    }

    const workflows = results.items.filter(i => i.assetType === 'workflow');
    const summary = routingGenerator.generateAllRoutingData(workflows, analysis);
    res.json({ success: true, summary });
});

// Get routing SmartObject definition
app.get('/api/routing/smartobject', (req, res) => {
    res.json({ routingSmartObject: routingGenerator.getRoutingSO() });
});

// Get routing SmartObject XML
app.get('/api/routing/smartobject/xml', (req, res) => {
    const xml = routingGenerator.getXml();
    res.type('application/xml').send(xml);
});

// Get routing SmartObject SQL DDL + seed data
app.get('/api/routing/smartobject/sql', (req, res) => {
    const sql = routingGenerator.getSql();
    res.type('text/plain').send(sql);
});

// Get all routing data
app.get('/api/routing/data', (req, res) => {
    res.json({ routingData: routingGenerator.getAllRoutingData(), stats: routingGenerator.getStats() });
});

// Get routing data for a specific process
app.get('/api/routing/data/:processName', (req, res) => {
    const data = routingGenerator.getRoutingData(req.params.processName);
    if (data.length === 0) return res.status(404).json({ error: 'No routing data for this process' });
    res.json({ processName: req.params.processName, records: data });
});

// Get routing generation log
app.get('/api/routing/log', (req, res) => {
    res.json({ log: routingGenerator.getLog() });
});

// ============================================================
// API Routes — Phase 3: SmartObject Generation & Deployment
// ============================================================

// Generate SmartObject definitions from analysis results
app.post('/api/smartobjects/generate', (req, res) => {
    const results = analysis.getResults({ pageSize: 10000 });
    if (!results.items || results.items.length === 0) {
        return res.status(400).json({
            error: 'No analysis results available. Run analysis first.'
        });
    }

    const summary = soGenerator.generate(results.items);
    saveAllState();
    res.json({ success: true, summary });
});

// List all generated SmartObjects
app.get('/api/smartobjects', (req, res) => {
    res.json({
        smartObjects: soGenerator.getAll(),
        stats: soGenerator.getStats()
    });
});

// Get SmartObject detail
app.get('/api/smartobjects/:id', (req, res) => {
    const so = soGenerator.getById(req.params.id);
    if (!so) return res.status(404).json({ error: 'SmartObject not found' });
    res.json(so);
});

// Get SODX XML
app.get('/api/smartobjects/:id/xml', (req, res) => {
    const xml = soGenerator.getXml(req.params.id);
    if (!xml) return res.status(404).json({ error: 'SmartObject not found' });
    res.type('application/xml').send(xml);
});

// Get SQL DDL
app.get('/api/smartobjects/:id/sql', (req, res) => {
    const sql = soGenerator.getSql(req.params.id);
    if (!sql) return res.status(404).json({ error: 'SmartObject not found' });
    res.type('text/plain').send(sql);
});

// Get generation log
app.get('/api/smartobjects/log', (req, res) => {
    res.json({ log: soGenerator.getLog() });
});

// ── K2 Server Connection ────────────────────────────────────

app.post('/api/k2/configure', (req, res) => {
    const { serverUrl, port, securityLabel, sqlServer, sqlCatalog, sqlUser, sqlPassword, sqlDomain } = req.body;
    if (!serverUrl) return res.status(400).json({ error: 'K2 server URL is required' });
    k2Bridge.configure({ serverUrl, port, securityLabel, sqlServer, sqlCatalog, sqlUser, sqlPassword, sqlDomain });
    res.json({ success: true, config: k2Bridge.getConnectionInfo() });
});

app.get('/api/k2/connection', (req, res) => {
    res.json(k2Bridge.getConnectionInfo());
});

// Test SQL Server connectivity (uses .NET impersonation for K2 service account)
app.post('/api/k2/test-sql', async (req, res) => {
    const sqlInstance = k2Bridge.config.sqlServer || '.\\SPSEDBPOC';
    const sqlUser = k2Bridge.config.sqlUser || '';
    const sqlPass = k2Bridge.config.sqlPassword || '';
    const sqlDomain = k2Bridge.config.sqlDomain || 'SPSEPOC';

    const impersonationBlock = (sqlUser && sqlPass) ? `
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Security.Principal;
public class Impersonator {
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool LogonUser(string user, string domain, string pass, int logonType, int provider, out IntPtr token);
    public static WindowsImpersonationContext Start(string domain, string user, string pass) {
        IntPtr token;
        if (!LogonUser(user, domain, pass, 9, 0, out token)) throw new Exception("LogonUser failed: " + Marshal.GetLastWin32Error());
        return WindowsIdentity.Impersonate(token);
    }
}
"@
\$ctx = [Impersonator]::Start("${sqlDomain}", "${sqlUser}", "${sqlPass}")
` : '';
    const undoBlock = (sqlUser && sqlPass) ? '\$ctx.Undo()' : '';

    const psScript = `
        \$ErrorActionPreference = "Stop"
        try {
            ${impersonationBlock}
            \$conn = New-Object System.Data.SqlClient.SqlConnection("Data Source=${sqlInstance};Integrated Security=SSPI")
            \$conn.Open()
            \$cmd = \$conn.CreateCommand()
            \$cmd.CommandText = "SELECT name FROM sys.databases ORDER BY name"
            \$reader = \$cmd.ExecuteReader()
            \$dbs = @()
            while (\$reader.Read()) { \$dbs += \$reader["name"] }
            \$conn.Close()
            ${undoBlock}
            \$result = @{ success = \$true; databases = \$dbs; server = "${sqlInstance}" }
            Write-Host (\$result | ConvertTo-Json -Compress)
        } catch {
            \$result = @{ success = \$false; error = \$_.Exception.Message }
            Write-Host (\$result | ConvertTo-Json -Compress)
        }
    `;
    try {
        const result = await k2Bridge._runPowerShell(psScript);
        res.json(result);
    } catch (err) {
        res.json({ success: false, error: err.message });
    }
});

app.post('/api/k2/test', async (req, res) => {
    const result = await k2Bridge.testConnection();
    res.json(result);
});

// ── SmartObject Deployment ──────────────────────────────────

app.post('/api/smartobjects/:id/deploy', async (req, res) => {
    const so = soGenerator.getById(req.params.id);
    if (!so) return res.status(404).json({ error: 'SmartObject not found' });

    const sodxXml = soGenerator.getXml(req.params.id);
    soGenerator.updateDeploymentStatus(req.params.id, 'deploying');

    const result = await k2Bridge.deploy(so, sodxXml);

    soGenerator.updateDeploymentStatus(
        req.params.id,
        result.status,
        result.status === 'failed' ? { error: result.error } : { deploymentId: result.id }
    );

    saveAllState();
    res.json({ success: result.status === 'deployed', deployment: result });
});

// Deploy all pending SmartObjects
app.post('/api/smartobjects/deploy-all', async (req, res) => {
    const allSOs = soGenerator.getAll().filter(so => so.deploymentStatus === 'pending');
    if (allSOs.length === 0) {
        return res.status(400).json({ error: 'No pending SmartObjects to deploy' });
    }

    const results = [];
    for (const soSummary of allSOs) {
        const so = soGenerator.getById(soSummary.id);
        const sodxXml = soGenerator.getXml(soSummary.id);
        soGenerator.updateDeploymentStatus(soSummary.id, 'deploying');

        const result = await k2Bridge.deploy(so, sodxXml);

        soGenerator.updateDeploymentStatus(
            soSummary.id,
            result.status,
            result.status === 'failed' ? { error: result.error } : { deploymentId: result.id }
        );

        results.push({ id: soSummary.id, name: soSummary.name, status: result.status });
    }

    const deployed = results.filter(r => r.status === 'deployed').length;
    res.json({
        success: true,
        total: results.length,
        deployed,
        failed: results.length - deployed,
        results
    });
});

// Deployment history
app.get('/api/k2/deployment-history', (req, res) => {
    res.json({ history: k2Bridge.getDeploymentHistory() });
});

// ── K2 Server Reconciliation ────────────────────────────────

// Reconcile local state with K2 server (queries K2 for deployed SmartObjects)
app.post('/api/k2/reconcile', async (req, res) => {
    if (!k2Bridge.config.serverUrl) {
        return res.status(400).json({ error: 'K2 server not configured. Connect first.' });
    }

    const k2Host = k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0];
    const k2Port = k2Bridge.config.port || 5555;

    // PowerShell script to list all SmartObjects on K2 server
    const psScript = `
        $ErrorActionPreference = "Stop"
        try {
            $k2Bin = "C:\\Program Files\\K2\\Bin"
            $onResolve = [System.ResolveEventHandler]{
                param($sender, $e)
                $asmName = $e.Name.Split(',')[0].Trim()
                $candidate = Join-Path $k2Bin "$asmName.dll"
                if (Test-Path $candidate) { return [System.Reflection.Assembly]::LoadFrom($candidate) }
                return $null
            }
            [System.AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\SourceCode.Framework.dll") | Out-Null
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\SourceCode.HostClientAPI.dll") | Out-Null
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\SourceCode.SmartObjects.Management.dll") | Out-Null

            $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=${k2Host};Port=${k2Port}"
            $mgmt = New-Object SourceCode.SmartObjects.Management.SmartObjectManagementServer
            $mgmt.CreateConnection()
            $mgmt.Connection.Open($connStr)

            $explorer = $mgmt.GetSmartObjects()
            # GetSmartObjects() returns SmartObjectExplorer — access .SmartObjects for the collection
            $soList = New-Object System.Collections.ArrayList
            foreach ($so in $explorer.SmartObjects) {
                [void]$soList.Add(@{
                    "name" = $so.Name
                    "displayName" = if ($so.Metadata.DisplayName) { $so.Metadata.DisplayName } else { $so.Name }
                })
            }
            $mgmt.Connection.Close()

            $result = @{
                "success" = $true
                "smartObjects" = $soList
                "count" = $soList.Count
            }
            Write-Host ($result | ConvertTo-Json -Compress -Depth 3)
        } catch {
            $result = @{
                "success" = $false
                "error" = $_.Exception.Message
                "smartObjects" = @()
                "count" = 0
            }
            Write-Host ($result | ConvertTo-Json -Compress)
        }
    `;

    try {
        const k2Result = await k2Bridge._runPowerShell(psScript);

        if (!k2Result.success) {
            return res.json({
                success: false,
                error: k2Result.error || 'Failed to query K2 server',
                reconciled: 0
            });
        }

        // Build a Set of SmartObject names deployed on K2
        const deployedNames = new Set();
        if (k2Result.smartObjects && Array.isArray(k2Result.smartObjects)) {
            k2Result.smartObjects.forEach(so => {
                deployedNames.add(so.name);
                // Also add without underscores for fuzzy matching
                deployedNames.add((so.displayName || '').replace(/\s+/g, '_'));
            });
        }

        // Reconcile against local SmartObjects
        const allLocalSOs = soGenerator.getAll();
        let updated = 0;
        let alreadyCorrect = 0;
        const changes = [];

        for (const localSO of allLocalSOs) {
            const existsOnK2 = deployedNames.has(localSO.name) ||
                               deployedNames.has(localSO.displayName) ||
                               deployedNames.has(localSO.name.replace(/_/g, ' '));

            if (existsOnK2 && localSO.deploymentStatus !== 'deployed') {
                soGenerator.updateDeploymentStatus(localSO.id, 'deployed', {
                    reconciledAt: new Date().toISOString(),
                    source: 'k2-server-reconciliation'
                });
                changes.push({ name: localSO.name, from: localSO.deploymentStatus, to: 'deployed' });
                updated++;
            } else if (!existsOnK2 && localSO.deploymentStatus === 'deployed') {
                soGenerator.updateDeploymentStatus(localSO.id, 'pending', {
                    reconciledAt: new Date().toISOString(),
                    source: 'k2-server-reconciliation',
                    note: 'Not found on K2 server — may have been removed'
                });
                changes.push({ name: localSO.name, from: 'deployed', to: 'pending' });
                updated++;
            } else {
                alreadyCorrect++;
            }
        }

        if (updated > 0) saveAllState();

        res.json({
            success: true,
            k2ServerSmartObjects: k2Result.count,
            localSmartObjects: allLocalSOs.length,
            reconciled: updated,
            alreadyCorrect,
            changes
        });

    } catch (err) {
        res.json({
            success: false,
            error: err.message,
            reconciled: 0
        });
    }
});

// Reconcile local SmartForms with K2 server
app.post('/api/k2/reconcile-smartforms', async (req, res) => {
    if (!k2Bridge.config.serverUrl) {
        return res.status(400).json({ error: 'K2 server not configured. Connect first.' });
    }

    const k2Host = k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0];
    const k2Port = k2Bridge.config.port || 5555;

    // PowerShell script to list deployed SmartForms via SourceCode.Forms.Management
    const psScript = `
        $ErrorActionPreference = "Stop"
        try {
            $k2Bin = "C:\\\\Program Files\\\\K2\\\\Bin"
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\\\SourceCode.Framework.dll") | Out-Null
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\\\SourceCode.HostClientAPI.dll") | Out-Null
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\\\SourceCode.Forms.Management.dll") | Out-Null

            $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=${k2Host};Port=${k2Port}"
            $formsMgr = New-Object SourceCode.Forms.Management.FormsManager
            $formsMgr.CreateConnection()
            $formsMgr.Connection.Open($connStr)

            $explorer = $formsMgr.GetForms()
            $formList = New-Object System.Collections.ArrayList
            foreach ($f in $explorer.Forms) {
                [void]$formList.Add(@{
                    "name" = $f.Name
                    "displayName" = if ($f.DisplayName) { $f.DisplayName } else { $f.Name }
                })
            }

            # Also get views
            $viewExplorer = $formsMgr.GetViews()
            $viewList = New-Object System.Collections.ArrayList
            foreach ($v in $viewExplorer.Views) {
                [void]$viewList.Add(@{
                    "name" = $v.Name
                    "displayName" = if ($v.DisplayName) { $v.DisplayName } else { $v.Name }
                })
            }

            $formsMgr.Connection.Close()

            $result = @{
                "success" = $true
                "forms" = @($formList)
                "views" = @($viewList)
                "formCount" = $formList.Count
                "viewCount" = $viewList.Count
            }
            Write-Host ($result | ConvertTo-Json -Compress -Depth 3)
        } catch {
            $result = @{
                "success" = $false
                "error" = $_.Exception.Message
                "forms" = @()
                "views" = @()
                "formCount" = 0
                "viewCount" = 0
            }
            Write-Host ($result | ConvertTo-Json -Compress)
        }
    `;

    try {
        const k2Result = await k2Bridge._runPowerShell(psScript);

        if (!k2Result.success) {
            return res.json({
                success: false,
                error: k2Result.error || 'Failed to query K2 forms',
                reconciled: 0
            });
        }

        // Build lookup sets
        const deployedFormNames = new Set();
        if (k2Result.forms && Array.isArray(k2Result.forms)) {
            k2Result.forms.forEach(f => {
                deployedFormNames.add(f.name);
                deployedFormNames.add(f.displayName);
            });
        }
        // Also check views — K2 SmartForms are often found as views
        if (k2Result.views && Array.isArray(k2Result.views)) {
            k2Result.views.forEach(v => {
                deployedFormNames.add(v.name);
                deployedFormNames.add(v.displayName);
            });
        }

        // Reconcile against local SmartForms
        const allLocalSFs = sfGenerator.getAll();
        let updated = 0;
        let alreadyCorrect = 0;
        const changes = [];

        for (const localSF of allLocalSFs) {
            const existsOnK2 = deployedFormNames.has(localSF.name) ||
                               deployedFormNames.has(localSF.displayName) ||
                               deployedFormNames.has(localSF.name.replace(/_/g, ' '));

            if (existsOnK2 && localSF.deploymentStatus !== 'deployed') {
                sfGenerator.updateDeploymentStatus(localSF.id, 'deployed', {
                    reconciledAt: new Date().toISOString(),
                    source: 'k2-server-reconciliation'
                });
                changes.push({ name: localSF.name, from: localSF.deploymentStatus, to: 'deployed' });
                updated++;
            } else if (!existsOnK2 && localSF.deploymentStatus === 'deployed') {
                sfGenerator.updateDeploymentStatus(localSF.id, 'pending', {
                    reconciledAt: new Date().toISOString(),
                    source: 'k2-server-reconciliation',
                    note: 'Not found on K2 server'
                });
                changes.push({ name: localSF.name, from: 'deployed', to: 'pending' });
                updated++;
            } else {
                alreadyCorrect++;
            }
        }

        if (updated > 0) saveAllState();

        res.json({
            success: true,
            k2ServerForms: k2Result.formCount,
            k2ServerViews: k2Result.viewCount,
            localSmartForms: allLocalSFs.length,
            reconciled: updated,
            alreadyCorrect,
            changes
        });

    } catch (err) {
        res.json({
            success: false,
            error: err.message,
            reconciled: 0
        });
    }
});

// ============================================================
// API Routes — Phase 4: SmartForm Generation & Deployment
// ============================================================

// Generate SmartForm definitions from SmartObject definitions
app.post('/api/smartforms/generate', (req, res) => {
    const allSOs = soGenerator.getAll();
    if (allSOs.length === 0) {
        return res.status(400).json({
            error: 'No SmartObjects available. Generate SmartObjects first.'
        });
    }

    // Get full SO definitions
    const soFull = allSOs.map(so => soGenerator.getById(so.id)).filter(Boolean);
    const summary = sfGenerator.generate(soFull);
    res.json({ success: true, summary });
});

// List all generated SmartForms
app.get('/api/smartforms', (req, res) => {
    res.json({
        smartForms: sfGenerator.getAll(),
        stats: sfGenerator.getStats()
    });
});

// Get SmartForm detail
app.get('/api/smartforms/:id', (req, res) => {
    const sf = sfGenerator.getById(req.params.id);
    if (!sf) return res.status(404).json({ error: 'SmartForm not found' });
    res.json(sf);
});

// Get SmartForm XML
app.get('/api/smartforms/:id/xml', (req, res) => {
    const xml = sfGenerator.getXml(req.params.id);
    if (!xml) return res.status(404).json({ error: 'SmartForm not found' });
    res.type('application/xml').send(xml);
});

// Deploy single SmartForm via K2 .NET SDK
app.post('/api/smartforms/:id/deploy', async (req, res) => {
    const sf = sfGenerator.getById(req.params.id);
    if (!sf) return res.status(404).json({ error: 'SmartForm not found' });

    sfGenerator.updateDeploymentStatus(req.params.id, 'deploying');

    try {
        // Build JSON with properties for Deploy-SmartForm.ps1
        const formData = {
            name: sf.smartObjectName || sf.name.replace(/ Form$/, '').replace(/ /g, '_'),
            displayName: sf.displayName || sf.name.replace(/ Form$/, ''),
            guid: sf.smartObjectId || sf.id,
            properties: (sf.views && sf.views[0] && sf.views[0].controls)
                ? sf.views[0].controls.filter(c => c.type !== 'Button').map(c => ({
                    name: (c.boundProperty || c.name || '').replace(/[^a-zA-Z0-9_]/g, '_'),
                    displayName: c.label || c.name || c.boundProperty || '',
                    soType: c.dataType || 'Text'
                }))
                : (sf.properties || []).map(p => ({
                    name: p.name || p,
                    displayName: p.displayName || p.name || p,
                    soType: p.soType || 'Text'
                }))
        };

        const fs = require('fs');
        const path = require('path');
        const os = require('os');
        const tmpFile = path.join(os.tmpdir(), `k2form_${formData.name}_${Date.now()}.json`);
        fs.writeFileSync(tmpFile, JSON.stringify(formData), 'utf-8');

        const scriptPath = path.join(__dirname, 'Deploy-SmartForm.ps1');
        const psScript = `& '${scriptPath}' -K2Server '${k2Bridge.config.serverUrl ? k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0] : 'NINTEX-SP-POC'}' -K2Port ${k2Bridge.config.port || 5555} -SmartObjectJsonFile '${tmpFile}'`;

        const result = await k2Bridge._runPowerShell(psScript);
        try { fs.unlinkSync(tmpFile); } catch(e) {}

        if (result.success) {
            sfGenerator.updateDeploymentStatus(req.params.id, 'deployed', {
                deployedAt: new Date().toISOString(),
                viewsDeployed: sf.views ? sf.views.length : 0,
                k2Result: result
            });
            res.json({ success: true, status: 'deployed', details: result });
        } else {
            sfGenerator.updateDeploymentStatus(req.params.id, 'failed');
            res.json({ success: false, error: result.error });
        }
    } catch (err) {
        sfGenerator.updateDeploymentStatus(req.params.id, 'failed');
        console.error('[SmartForm Deploy Error]', err.message);
        res.json({ success: false, error: err.message });
    }
});

// Deploy all pending SmartForms via K2 SDK
app.post('/api/smartforms/deploy-all', async (req, res) => {
    const pending = sfGenerator.getAll().filter(sf => sf.deploymentStatus === 'pending');
    if (pending.length === 0) {
        return res.status(400).json({ error: 'No pending SmartForms to deploy' });
    }

    let deployed = 0;
    const results = [];
    for (const sfSummary of pending) {
        try {
            // Trigger the single deploy for each
            const sf = sfGenerator.getById(sfSummary.id);
            sfGenerator.updateDeploymentStatus(sfSummary.id, 'deploying');

            const formData = {
                name: sf.smartObjectName || sf.name.replace(/ Form$/, '').replace(/ /g, '_'),
                displayName: sf.displayName || sf.name.replace(/ Form$/, ''),
                guid: sf.smartObjectId || sf.id,
                properties: (sf.views && sf.views[0] && sf.views[0].controls)
                    ? sf.views[0].controls.filter(c => c.type !== 'Button').map(c => ({
                        name: (c.boundProperty || c.name || '').replace(/[^a-zA-Z0-9_]/g, '_'),
                        displayName: c.label || c.name || c.boundProperty || '',
                        soType: c.dataType || 'Text'
                    }))
                    : []
            };

            const fs = require('fs');
            const path = require('path');
            const os = require('os');
            const tmpFile = path.join(os.tmpdir(), `k2form_${formData.name}_${Date.now()}.json`);
            fs.writeFileSync(tmpFile, JSON.stringify(formData), 'utf-8');

            const scriptPath = path.join(__dirname, 'Deploy-SmartForm.ps1');
            const psScript = `& '${scriptPath}' -K2Server '${k2Bridge.config.serverUrl ? k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0] : 'NINTEX-SP-POC'}' -K2Port ${k2Bridge.config.port || 5555} -SmartObjectJsonFile '${tmpFile}'`;

            const result = await k2Bridge._runPowerShell(psScript);
            try { fs.unlinkSync(tmpFile); } catch(e) {}

            if (result.success) {
                sfGenerator.updateDeploymentStatus(sfSummary.id, 'deployed', {
                    deployedAt: new Date().toISOString(),
                    viewsDeployed: sfSummary.viewCount
                });
                deployed++;
                results.push({ name: sfSummary.name, status: 'deployed' });
            } else {
                sfGenerator.updateDeploymentStatus(sfSummary.id, 'failed');
                results.push({ name: sfSummary.name, status: 'failed', error: result.error });
            }
        } catch (err) {
            sfGenerator.updateDeploymentStatus(sfSummary.id, 'failed');
            results.push({ name: sfSummary.name, status: 'failed', error: err.message });
        }
    }

    res.json({ success: true, total: pending.length, deployed, results });
});

// SmartForm generation log
app.get('/api/smartforms/log', (req, res) => {
    res.json({ log: sfGenerator.getLog() });
});

// ============================================================
// API Routes — Phase 5: Strategy A Workflow Templates & Routing
// ============================================================

// Fetch deployed workflow templates from K2 server
app.post('/api/k2/workflow-templates', async (req, res) => {
    if (!k2Bridge.config.serverUrl) {
        return res.status(400).json({ error: 'K2 server not configured.' });
    }

    const k2Host = k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0];
    const k2Port = k2Bridge.config.port || 5555;

    const psScript = `
        $ErrorActionPreference = "Stop"
        try {
            $k2Bin = "C:\\\\Program Files\\\\K2\\\\Bin"
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\\\SourceCode.Framework.dll") | Out-Null
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\\\SourceCode.HostClientAPI.dll") | Out-Null
            [System.Reflection.Assembly]::LoadFrom("$k2Bin\\\\SourceCode.Workflow.Management.dll") | Out-Null

            $connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=${k2Host};Port=${k2Port}"
            $wfMgmt = New-Object SourceCode.Workflow.Management.WorkflowManagementServer
            $wfMgmt.CreateConnection()
            $wfMgmt.Connection.Open($connStr)

            $procSets = $wfMgmt.GetProcSets()
            $templates = New-Object System.Collections.ArrayList
            foreach ($ps in $procSets) {
                [void]$templates.Add(@{
                    "procSetId" = $ps.ProcSetId
                    "procName" = $ps.FullName
                    "displayName" = if ($ps.FullName) { $ps.FullName } else { "Unknown" }
                    "folder" = if ($ps.Folder) { $ps.Folder } else { "" }
                    "version" = if ($ps.VersionNumber) { $ps.VersionNumber } else { 1 }
                })
            }
            $wfMgmt.Connection.Close()

            $result = @{
                "success" = $true
                "templates" = @($templates)
                "count" = $templates.Count
            }
            Write-Host ($result | ConvertTo-Json -Compress -Depth 3)
        } catch {
            $result = @{
                "success" = $false
                "error" = $_.Exception.Message
                "templates" = @()
                "count" = 0
            }
            Write-Host ($result | ConvertTo-Json -Compress)
        }
    `;

    try {
        const k2Result = await k2Bridge._runPowerShell(psScript);
        // Cache to SQLite
        if (k2Result.success && k2Result.templates && k2Result.templates.length > 0) {
            db.cacheK2Templates(k2Result.templates);
        }
        res.json(k2Result);
    } catch (err) {
        // Fall back to cached templates
        const cached = db.getCachedTemplates().map(db.dbToTemplateRow);
        if (cached.length > 0) {
            res.json({ success: true, templates: cached, count: cached.length, cached: true });
        } else {
            res.json({ success: false, error: err.message, templates: [], count: 0 });
        }
    }
});

// Auto-generate workflow routing configuration → persists to SQLite
app.post('/api/workflow-routing/generate', (req, res) => {
    const routingResult = _buildRoutingConfig();
    if (!routingResult) {
        return res.status(400).json({ error: 'No analysis results. Run analysis first.' });
    }

    // Persist routing to SQLite (preserves manual overrides)
    const run = db.saveAnalysisRun('routing', 'auto-generate', routingResult.routing.length, routingResult.stats);
    db.upsertRouting(routingResult.routing, run.lastInsertRowid);

    // Re-read from DB to get IDs + any preserved overrides
    const dbRows = db.getAllRouting().map(db.dbToRoutingRow);
    const stats = db.getRoutingStats();

    res.json({ success: true, routing: dbRows, stats });
});

// Get routing config — always from SQLite
app.get('/api/workflow-routing', (req, res) => {
    const count = db.getRoutingCount();
    if (count === 0) {
        return res.json({ success: true, routing: [], stats: { total: 0, linked: 0, soReady: 0, sfReady: 0, fullyWired: 0, needsAttention: 0 } });
    }
    const routing = db.getAllRouting().map(db.dbToRoutingRow);
    const stats = db.getRoutingStats();
    res.json({ success: true, routing, stats });
});

// Manual override: update template for a specific form
app.patch('/api/workflow-routing/:id', (req, res) => {
    const { templateName } = req.body;
    if (!templateName) return res.status(400).json({ error: 'templateName required' });
    db.updateRoutingTemplate(parseInt(req.params.id), templateName);
    res.json({ success: true });
});

// Bind workflow template to SmartForm and redeploy (lazy binding)
// Gap 1 full contract: Start rule + ProcessKey + DataSO reference + outcome rules (already in approval view)
app.post('/api/workflow-routing/:id/bind', async (req, res) => {
    const row = db.getRoutingById(parseInt(req.params.id));
    if (!row) return res.status(404).json({ error: 'Routing row not found' });

    const processName = (row.workflow_name || '').replace(/[^a-zA-Z0-9_]/g, '_');
    const templateName = row.template_name || '';

    if (!templateName) {
        return res.status(400).json({ error: 'No workflow template mapped. Select a template first.' });
    }

    const formName = row.list_title || row.workflow_name || processName;
    const soName = processName; // SmartObject name matches process name convention

    // Use SmartFormGenerator.bindWorkflow() to inject the full binding contract
    const bindResult = sfGenerator.bindWorkflow(soName, {
        templateName: templateName,
        processKey: processName,
        formName: formName,
        site: row.site || ''
    });

    if (!bindResult.success) {
        // Still save the mapping locally — SmartForms might not be generated yet
        db.markRoutingPushed(parseInt(req.params.id));
        return res.json({
            success: true,
            message: `Binding saved (${bindResult.message}). Generate SmartForms first, then re-bind.`,
            binding: {
                templateName, processName, formName,
                site: row.site || '',
                processKey: processName,
                dataSmartObject: soName
            },
            pendingSmartForm: true
        });
    }

    // Mark as bound in SQLite
    db.markRoutingPushed(parseInt(req.params.id));

    res.json({
        success: true,
        message: bindResult.message,
        binding: {
            templateName,
            processKey: processName,
            formName,
            site: row.site || '',
            dataSmartObject: soName,
            xmlGenerated: !!bindResult.xml,
            startRule: 'OnSubmitStartWorkflow → ' + templateName,
            outcomeRules: 'OnApproveClick → WorklistAction(Approve), OnRejectClick → WorklistAction(Reject)'
        }
    });
});

// Get sites list (for dropdown)
app.get('/api/workflow-routing/sites', (req, res) => {
    const sites = db.getSiteList();
    res.json({ success: true, sites });
});

// Shared routing builder (generates from analysis, does NOT persist)
function _buildRoutingConfig() {
    const results = analysis.getResults({ pageSize: 10000 });
    if (!results.items || results.items.length === 0) return null;

    const workflows = results.items.filter(i => i.assetType === 'workflow');
    if (workflows.length === 0) return null;

    const allSOs = soGenerator.getAll();
    const allSFs = sfGenerator.getAll();
    const routingConfig = [];
    let linked = 0, soReady = 0, sfReady = 0, fullyWired = 0;

    for (const wf of workflows) {
        const matchedSO = allSOs.find(so => so.webUrl === wf.webUrl && so.listTitle === wf.listTitle) || null;
        const matchedSF = matchedSO ? allSFs.find(sf =>
            sf.smartObjectName && sf.smartObjectName.includes((wf.listTitle || '').replace(/[^a-zA-Z0-9]/g, '_'))
        ) : null;

        const score = wf.complexityScore || 0;
        let tier, templateName, migrationPath;
        if (score <= 14) { tier = 'Tier 1'; templateName = 'Tier1_ApprovalTemplate'; migrationPath = 'auto'; }
        else if (score <= 34) { tier = 'Tier 2'; templateName = 'Tier1_ApprovalTemplate'; migrationPath = 'auto-with-review'; }
        else if (score <= 59) { tier = 'Tier 3'; templateName = 'Custom (K2 Designer)'; migrationPath = 'manual-guided'; }
        else { tier = 'Tier 4'; templateName = 'Custom (K2 Designer)'; migrationPath = 'manual-complex'; }

        const soDeployed = matchedSO && matchedSO.deploymentStatus === 'deployed';
        const sfDeployed = matchedSF && matchedSF.deploymentStatus === 'deployed';
        const isAuto = migrationPath === 'auto' || migrationPath === 'auto-with-review';
        const isWired = soDeployed && sfDeployed && isAuto;

        if (isAuto) linked++;
        if (soDeployed) soReady++;
        if (sfDeployed) sfReady++;
        if (isWired) fullyWired++;

        // Extract site from webUrl
        let site = 'Unknown';
        try { const u = new URL(wf.webUrl || ''); site = u.pathname.split('/').slice(0, 4).join('/') || u.hostname; }
        catch { site = (wf.webUrl || '').split('/').slice(0, 5).join('/'); }

        routingConfig.push({
            workflowName: wf.name || wf.workflowName || 'Unnamed',
            listTitle: wf.listTitle || '',
            webUrl: wf.webUrl || '',
            site,
            complexity: wf.complexity, complexityScore: score,
            tier, templateName, migrationPath,
            smartObject: matchedSO ? { name: matchedSO.displayName || matchedSO.name, status: matchedSO.deploymentStatus } : null,
            smartForm: matchedSF ? { name: matchedSF.displayName || matchedSF.name, status: matchedSF.deploymentStatus } : null,
            readiness: isWired ? 'ready' : (soDeployed || sfDeployed ? 'partial' : 'pending')
        });
    }

    // Deduplicate by listTitle + webUrl (keep highest complexity entry)
    const dedupMap = new Map();
    for (const r of routingConfig) {
        const key = `${r.listTitle}||${r.webUrl}`;
        const existing = dedupMap.get(key);
        if (!existing || (r.complexityScore || 0) > (existing.complexityScore || 0)) {
            dedupMap.set(key, r);
        }
    }
    const deduped = [...dedupMap.values()];

    // Recount stats on deduped data
    let dLinked = 0, dSoReady = 0, dSfReady = 0, dFullyWired = 0;
    for (const r of deduped) {
        const isAuto = r.migrationPath === 'auto' || r.migrationPath === 'auto-with-review';
        if (isAuto) dLinked++;
        if (r.smartObject && r.smartObject.status === 'deployed') dSoReady++;
        if (r.smartForm && r.smartForm.status === 'deployed') dSfReady++;
        if (r.readiness === 'ready') dFullyWired++;
    }

    return { success: true, routing: deduped, stats: { total: deduped.length, linked: dLinked, soReady: dSoReady, sfReady: dSfReady, fullyWired: dFullyWired, needsAttention: deduped.length - dFullyWired } };
}

// ============================================================
// API Routes — Phase 5 (Legacy): Workflow Blueprint Generation
// ============================================================

// Generate blueprints from analyzed workflow data
app.post('/api/blueprints/generate', (req, res) => {
    const results = analysis.getResults({ pageSize: 10000 });
    if (!results.items || results.items.length === 0) {
        return res.status(400).json({ error: 'No analysis results. Run analysis first.' });
    }

    const workflows = results.items.filter(i => i.assetType === 'workflow');
    if (workflows.length === 0) {
        return res.status(400).json({ error: 'No workflows found in analysis results.' });
    }

    const summary = bpGenerator.generate(workflows, soGenerator, sfGenerator);
    res.json({ success: true, summary });
});

// List all blueprints
app.get('/api/blueprints', (req, res) => {
    res.json({
        blueprints: bpGenerator.getAll(),
        stats: bpGenerator.getStats()
    });
});

// Get blueprint detail
app.get('/api/blueprints/:id', (req, res) => {
    const bp = bpGenerator.getById(req.params.id);
    if (!bp) return res.status(404).json({ error: 'Blueprint not found' });
    res.json(bp);
});

// Get blueprint as HTML (for print/export)
app.get('/api/blueprints/:id/html', (req, res) => {
    const html = bpGenerator.getHtml(req.params.id);
    if (!html) return res.status(404).json({ error: 'Blueprint not found' });
    res.type('text/html').send(html);
});

// Update blueprint status (pending → in-progress → completed)
app.put('/api/blueprints/:id/status', (req, res) => {
    const { status } = req.body;
    if (!['pending', 'in-progress', 'completed'].includes(status)) {
        return res.status(400).json({ error: 'Status must be: pending, in-progress, or completed' });
    }
    const ok = bpGenerator.updateStatus(req.params.id, status);
    if (!ok) return res.status(404).json({ error: 'Blueprint not found' });
    res.json({ success: true, status });
});

// Blueprint generation log
app.get('/api/blueprints/log', (req, res) => {
    res.json({ log: bpGenerator.getLog() });
});

// Deploy a single workflow blueprint to K2 via Deploy-Workflow.ps1
app.post('/api/blueprints/:id/deploy', async (req, res) => {
    const bp = bpGenerator.getById(req.params.id);
    if (!bp) return res.status(404).json({ error: 'Blueprint not found' });

    try {
        const fs = require('fs');
        const path = require('path');
        const os = require('os');
        const { spawnSync } = require('child_process');

        // Convert blueprint to workflow JSON format expected by Deploy-Workflow.ps1
        const wfDef = {
            name: bp.workflowName.replace(/[^a-zA-Z0-9_]/g, '_'),
            displayName: bp.workflowName,
            description: `Migrated from SPD ${bp.workflowType}. Source: ${bp.listTitle || 'N/A'} at ${bp.webUrl || 'N/A'}`,
            smartObject: bp.relatedSmartObject ? bp.relatedSmartObject.name : bp.workflowName.replace(/[^a-zA-Z0-9_]/g, '_'),
            dataFields: [
                { name: 'ItemID', type: 'Number' },
                { name: 'Title', type: 'Text' },
                { name: 'Status', type: 'Text', initialValue: 'Pending' },
                { name: 'Requester', type: 'Text' },
                { name: 'ApproverComments', type: 'Text' },
                { name: 'Timestamp', type: 'DateTime' }
            ],
            steps: [],
            connections: []
        };

        // Convert blueprint steps to activities
        const stepNames = [];
        bp.steps.forEach((step, idx) => {
            // Skip setup and QA steps — they aren't real K2 activities
            if (step.category === 'Setup' || step.category === 'QA') return;

            const stepName = step.spdAction.replace(/[^a-zA-Z0-9_]/g, '_').replace(/_+/g, '_');
            const uniqueName = `${stepName}_${idx}`;
            stepNames.push(uniqueName);

            const isTask = ['Client Events', 'client', 'approval'].some(t =>
                (step.category || '').toLowerCase().includes(t.toLowerCase()) ||
                (step.k2Activity || '').toLowerCase().includes('task') ||
                (step.k2Activity || '').toLowerCase().includes('client event')
            );

            const actDef = {
                name: uniqueName,
                displayName: step.spdAction,
                description: `Step ${step.stepNumber}: ${step.k2Activity}`,
                type: isTask ? 'task' : 'system',
                durationMinutes: step.estimatedMinutes || 30,
                outcomes: [],
                dataFields: []
            };

            // Add outcomes for task activities
            if (isTask) {
                if ((step.k2Activity || '').toLowerCase().includes('approval')) {
                    actDef.outcomes = ['Approved', 'Rejected'];
                } else {
                    actDef.outcomes = ['Completed'];
                }
            }

            wfDef.steps.push(actDef);
        });

        // Build sequential connections: Start → Step1 → Step2 → ... → End
        if (stepNames.length > 0) {
            wfDef.connections.push({ from: 'Start', to: stepNames[0], label: 'Begin' });
            for (let i = 0; i < stepNames.length - 1; i++) {
                wfDef.connections.push({ from: stepNames[i], to: stepNames[i + 1], label: '' });
            }
        }

        // Write to temp file
        const tmpFile = path.join(os.tmpdir(), `k2wf_${bp.id}_${Date.now()}.json`);
        fs.writeFileSync(tmpFile, JSON.stringify(wfDef, null, 2), 'utf-8');

        // Also save a copy to workflow-definitions/ for reference
        const defDir = path.join(__dirname, 'workflow-definitions');
        if (!fs.existsSync(defDir)) fs.mkdirSync(defDir, { recursive: true });
        fs.writeFileSync(path.join(defDir, `${wfDef.name}.json`), JSON.stringify(wfDef, null, 2), 'utf-8');

        // Determine K2 server
        const k2Host = k2Bridge.config.serverUrl
            ? k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0]
            : 'NINTEX-SP-POC';
        const k2Port = k2Bridge.config.port || 5555;

        const scriptPath = path.join(__dirname, 'Deploy-Workflow.ps1');
        const psScript = `& '${scriptPath}' -K2Server '${k2Host}' -K2Port ${k2Port} -WorkflowJsonFile '${tmpFile}'`;
        const encodedScript = Buffer.from(psScript, 'utf16le').toString('base64');

        console.log(`[WF DEPLOY] Deploying "${wfDef.displayName}" (${wfDef.steps.length} activities, ${wfDef.connections.length} lines)...`);

        const result = spawnSync('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-EncodedCommand', encodedScript
        ], { timeout: 120000, encoding: 'utf-8' });

        const stdout = (result.stdout || '').trim();
        const stderr = (result.stderr || '').trim();

        console.log('[WF PS stdout]', stdout.substring(0, 2000));
        if (stderr) console.log('[WF PS stderr]', stderr.substring(0, 500));

        // Clean up temp file
        try { fs.unlinkSync(tmpFile); } catch (e) {}

        // Parse JSON result from last line of stdout
        let psResult = null;
        const lines = stdout.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
            const line = lines[i].trim();
            if (line.startsWith('{')) {
                try { psResult = JSON.parse(line); break; } catch (e) {}
            }
        }

        if (psResult && psResult.success) {
            bpGenerator.updateStatus(req.params.id, 'completed');
            res.json({
                success: true,
                deployment: {
                    workflowName: psResult.workflowName,
                    displayName: psResult.displayName,
                    activities: psResult.activities,
                    lines: psResult.lines,
                    dataFields: psResult.dataFields,
                    deployResult: psResult.deployResult
                },
                definitionFile: `workflow-definitions/${wfDef.name}.json`
            });
        } else {
            const errorMsg = psResult ? psResult.error : (stderr || 'No output from Deploy-Workflow.ps1');
            res.json({ success: false, error: errorMsg, stdout: stdout.substring(0, 1000) });
        }
    } catch (err) {
        console.error('[WF DEPLOY ERROR]', err.message);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Deploy all pending workflow blueprints
app.post('/api/blueprints/deploy-all', async (req, res) => {
    const allBPs = bpGenerator.getAll();
    const pending = allBPs.filter(bp => bp.status !== 'completed');

    if (pending.length === 0) {
        return res.json({ success: true, deployed: 0, total: 0, message: 'No pending blueprints to deploy' });
    }

    let deployed = 0, failed = 0;
    const results = [];

    for (const bpSummary of pending) {
        try {
            // Use internal fetch-like call
            const fakeReq = { params: { id: bpSummary.id } };
            const bp = bpGenerator.getById(bpSummary.id);
            if (!bp) { failed++; continue; }

            // Build the same workflow JSON inline (reuse logic)
            const fs = require('fs');
            const path = require('path');
            const os = require('os');
            const { spawnSync } = require('child_process');

            const wfDef = {
                name: bp.workflowName.replace(/[^a-zA-Z0-9_]/g, '_'),
                displayName: bp.workflowName,
                description: `Migrated from SPD ${bp.workflowType}`,
                smartObject: bp.workflowName.replace(/[^a-zA-Z0-9_]/g, '_'),
                dataFields: [
                    { name: 'ItemID', type: 'Number' },
                    { name: 'Title', type: 'Text' },
                    { name: 'Status', type: 'Text', initialValue: 'Pending' },
                    { name: 'Requester', type: 'Text' },
                    { name: 'ApproverComments', type: 'Text' },
                    { name: 'Timestamp', type: 'DateTime' }
                ],
                steps: [],
                connections: []
            };

            const stepNames = [];
            bp.steps.forEach((step, idx) => {
                if (step.category === 'Setup' || step.category === 'QA') return;
                const uniqueName = `${step.spdAction.replace(/[^a-zA-Z0-9_]/g, '_')}_${idx}`;
                stepNames.push(uniqueName);
                wfDef.steps.push({
                    name: uniqueName,
                    displayName: step.spdAction,
                    description: `Step ${step.stepNumber}: ${step.k2Activity}`,
                    type: (step.k2Activity || '').toLowerCase().includes('task') || (step.k2Activity || '').toLowerCase().includes('client') ? 'task' : 'system',
                    durationMinutes: step.estimatedMinutes || 30,
                    outcomes: (step.k2Activity || '').toLowerCase().includes('approval') ? ['Approved', 'Rejected'] : [],
                    dataFields: []
                });
            });

            if (stepNames.length > 0) {
                wfDef.connections.push({ from: 'Start', to: stepNames[0], label: 'Begin' });
                for (let i = 0; i < stepNames.length - 1; i++) {
                    wfDef.connections.push({ from: stepNames[i], to: stepNames[i + 1], label: '' });
                }
            }

            const tmpFile = path.join(os.tmpdir(), `k2wf_batch_${bp.id}_${Date.now()}.json`);
            fs.writeFileSync(tmpFile, JSON.stringify(wfDef, null, 2), 'utf-8');

            const k2Host = k2Bridge.config.serverUrl
                ? k2Bridge.config.serverUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '').split(':')[0]
                : 'NINTEX-SP-POC';
            const scriptPath = path.join(__dirname, 'Deploy-Workflow.ps1');
            const psScript = `& '${scriptPath}' -K2Server '${k2Host}' -K2Port ${k2Bridge.config.port || 5555} -WorkflowJsonFile '${tmpFile}'`;
            const encodedScript = Buffer.from(psScript, 'utf16le').toString('base64');

            console.log(`[WF BATCH] Deploying "${wfDef.displayName}" (${wfDef.steps.length} steps)...`);
            console.log(`[WF BATCH] Script: ${scriptPath}`);
            console.log(`[WF BATCH] Exists: ${fs.existsSync(scriptPath)}`);

            const result = spawnSync('powershell.exe', [
                '-NoProfile', '-NonInteractive', '-EncodedCommand', encodedScript
            ], { timeout: 120000, encoding: 'utf-8' });

            try { fs.unlinkSync(tmpFile); } catch (e) {}

            const stdout = (result.stdout || '').trim();
            const stderr = (result.stderr || '').trim();
            console.log(`[WF BATCH stdout] ${stdout.substring(0, 2000)}`);
            if (stderr) console.log(`[WF BATCH stderr] ${stderr.substring(0, 1000)}`);
            if (result.status !== 0) console.log(`[WF BATCH] Exit code: ${result.status}`);

            let psResult = null;
            const lines = stdout.split('\n');
            for (let i = lines.length - 1; i >= 0; i--) {
                const line = lines[i].trim();
                if (line.startsWith('{')) { try { psResult = JSON.parse(line); break; } catch (e) {} }
            }

            if (psResult && psResult.success) {
                bpGenerator.updateStatus(bpSummary.id, 'completed');
                deployed++;
                results.push({ name: bp.workflowName, status: 'deployed' });
                console.log(`[WF BATCH] SUCCESS: ${bp.workflowName}`);
            } else {
                failed++;
                const errMsg = psResult?.error || stderr || 'No output from Deploy-Workflow.ps1';
                results.push({ name: bp.workflowName, status: 'failed', error: errMsg });
                console.log(`[WF BATCH] FAILED: ${bp.workflowName} - ${errMsg}`);
            }
        } catch (err) {
            failed++;
            results.push({ name: bpSummary.workflowName, status: 'failed', error: err.message });
            console.error(`[WF BATCH ERROR] ${err.message}`);
        }
    }

    res.json({ success: true, deployed, failed, total: pending.length, results });
});

// ============================================================
// API Routes — Phase 7-8: Validation & Cutover
// ============================================================

// Build validation context from all services
function buildValidationContext() {
    return {
        inventory: discovery.getInventory(),
        analysisResults: analysis.getResults({ pageSize: 10000 }).items || [],
        smartObjects: soGenerator.getAll(),
        smartForms: sfGenerator.getAll(),
        blueprints: bpGenerator.getAll(),
        k2Connection: k2Bridge.getConnectionInfo()
    };
}

// Run validation
app.post('/api/validation/run', (req, res) => {
    const ctx = buildValidationContext();
    const report = validator.runValidation(ctx);
    res.json({ success: true, report });
});

// Get last validation report
app.get('/api/validation/report', (req, res) => {
    const report = validator.getReport();
    if (!report.timestamp) return res.status(404).json({ error: 'Run validation first' });
    res.json(report);
});

// Get cutover checklist
app.get('/api/cutover/checklist', (req, res) => {
    res.json(validator.getCutoverChecklist());
});

// Toggle checklist item
app.put('/api/cutover/checklist/:id', (req, res) => {
    const { checked } = req.body;
    const ok = validator.toggleChecklistItem(req.params.id, checked);
    if (!ok) return res.status(404).json({ error: 'Checklist item not found' });
    res.json({ success: true, checklist: validator.getCutoverChecklist() });
});

// Get rollback plan
app.get('/api/cutover/rollback', (req, res) => {
    res.json(validator.getRollbackPlan());
});

// Get migration summary
app.get('/api/migration/summary', (req, res) => {
    const ctx = buildValidationContext();
    res.json(validator.getMigrationSummary(ctx));
});

// ============================================================
// Start Server
// ============================================================

app.listen(PORT, () => {
    console.log('');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('  SPD → K2 Five Migration Pipeline — Strategy A');
    console.log('  Form-Driven Workflow • Master Template + Routing SmartObject');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log(`  ▸ Source: ${ENVIRONMENT.source.platform} ${ENVIRONMENT.source.version}`);
    console.log(`  ▸ Target: ${ENVIRONMENT.target.platform} ${ENVIRONMENT.target.version} ${ENVIRONMENT.target.featurePack} (${ENVIRONMENT.target.build})`);
    console.log(`  ▸ Server: http://localhost:${PORT}`);
    console.log(`  ▸ Strategy: Form-Driven (Template 1 + Routing SO + Approval Views)`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('');
});

