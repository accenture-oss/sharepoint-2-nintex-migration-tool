// ============================================================
// SQLite Database Layer — SPD → K2 Migration Pipeline
// Lightweight persistence for routing, templates, analysis
// ============================================================

const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const DB_DIR = path.join(__dirname, 'data');
const DB_PATH = path.join(DB_DIR, 'migration.db');
let db;

function getDb() {
    if (!db) {
        // Ensure data directory exists
        if (!fs.existsSync(DB_DIR)) fs.mkdirSync(DB_DIR, { recursive: true });
        db = new Database(DB_PATH);
        db.pragma('journal_mode = WAL');       // Better concurrency
        db.pragma('foreign_keys = ON');
        initSchema();
    }
    return db;
}

function initSchema() {
    db.exec(`
        -- Analysis run snapshots
        CREATE TABLE IF NOT EXISTS analysis_runs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            run_date    TEXT    NOT NULL DEFAULT (datetime('now')),
            csv_type    TEXT,          -- 'workflow' | 'infopath'
            csv_filename TEXT,
            total_rows  INTEGER DEFAULT 0,
            summary     TEXT           -- JSON blob of stats
        );

        -- Core routing table (form → template linkage)
        CREATE TABLE IF NOT EXISTS form_routing (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            analysis_run_id INTEGER,
            workflow_name   TEXT NOT NULL,
            list_title      TEXT,
            web_url         TEXT,
            site            TEXT,
            tier            TEXT,
            template_name   TEXT,
            smart_object    TEXT,
            so_status       TEXT DEFAULT 'pending',
            smart_form      TEXT,
            sf_status       TEXT DEFAULT 'pending',
            readiness       TEXT DEFAULT 'pending',
            migration_path  TEXT,
            overridden      INTEGER DEFAULT 0,
            created_at      TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
        );

        -- K2 templates cache
        CREATE TABLE IF NOT EXISTS k2_templates (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            proc_name     TEXT NOT NULL,
            display_name  TEXT,
            folder        TEXT,
            version       INTEGER DEFAULT 1,
            tier_class    TEXT,
            fetched_at    TEXT NOT NULL DEFAULT (datetime('now'))
        );

        -- Indexes for performance on 10K+ rows
        CREATE INDEX IF NOT EXISTS idx_routing_site      ON form_routing(site);
        CREATE INDEX IF NOT EXISTS idx_routing_tier       ON form_routing(tier);
        CREATE INDEX IF NOT EXISTS idx_routing_readiness  ON form_routing(readiness);
        CREATE INDEX IF NOT EXISTS idx_routing_workflow   ON form_routing(workflow_name);
        CREATE INDEX IF NOT EXISTS idx_templates_proc     ON k2_templates(proc_name);
    `);
}

// ── Analysis Runs ──────────────────────────────────────────

function saveAnalysisRun(csvType, filename, totalRows, summary) {
    const stmt = getDb().prepare(`
        INSERT INTO analysis_runs (csv_type, csv_filename, total_rows, summary)
        VALUES (?, ?, ?, ?)
    `);
    return stmt.run(csvType, filename, totalRows, JSON.stringify(summary));
}

function getLatestAnalysisRun(csvType) {
    return getDb().prepare(`
        SELECT * FROM analysis_runs WHERE csv_type = ? ORDER BY id DESC LIMIT 1
    `).get(csvType);
}

// ── Form Routing (Bulk Operations) ──────────────────────────

function upsertRouting(routingArray, analysisRunId = null) {
    const d = getDb();
    const insertStmt = d.prepare(`
        INSERT INTO form_routing (analysis_run_id, workflow_name, list_title, web_url, site, 
                                   tier, template_name, smart_object, so_status, smart_form, 
                                   sf_status, readiness, migration_path, overridden, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, datetime('now'))
    `);

    // Clear previous non-overridden entries (keep manual overrides)
    const deleteNonOverridden = d.prepare(`DELETE FROM form_routing WHERE overridden = 0`);

    const txn = d.transaction((rows) => {
        deleteNonOverridden.run();
        for (const r of rows) {
            // Check if there's a manual override for this workflow
            const existing = d.prepare(
                `SELECT template_name FROM form_routing WHERE workflow_name = ? AND overridden = 1`
            ).get(r.workflowName);

            insertStmt.run(
                analysisRunId,
                r.workflowName,
                r.listTitle || null,
                r.webUrl || null,
                r.site || null,
                r.tier || null,
                existing ? existing.template_name : (r.templateName || null),
                r.smartObject ? r.smartObject.name : null,
                r.smartObject ? r.smartObject.status : 'pending',
                r.smartForm ? r.smartForm.name : null,
                r.smartForm ? r.smartForm.status : 'pending',
                r.readiness || 'pending',
                r.migrationPath || null
            );
        }
    });

    txn(routingArray);
}

function getAllRouting() {
    return getDb().prepare(`SELECT * FROM form_routing ORDER BY site, workflow_name`).all();
}

function getRoutingBySite(site) {
    return getDb().prepare(`SELECT * FROM form_routing WHERE site = ? ORDER BY workflow_name`).all(site);
}

function getRoutingStats() {
    const d = getDb();
    const total = d.prepare(`SELECT COUNT(*) as c FROM form_routing`).get().c;
    const linked = d.prepare(`SELECT COUNT(*) as c FROM form_routing WHERE template_name IS NOT NULL AND template_name != ''`).get().c;
    const soReady = d.prepare(`SELECT COUNT(*) as c FROM form_routing WHERE so_status = 'deployed'`).get().c;
    const sfReady = d.prepare(`SELECT COUNT(*) as c FROM form_routing WHERE sf_status = 'deployed'`).get().c;
    const fullyWired = d.prepare(`SELECT COUNT(*) as c FROM form_routing WHERE readiness = 'ready'`).get().c;
    const needsAttention = d.prepare(`SELECT COUNT(*) as c FROM form_routing WHERE readiness = 'pending' OR readiness = 'blocked'`).get().c;
    return { total, linked, soReady, sfReady, fullyWired, needsAttention };
}

function getSiteList() {
    return getDb().prepare(`SELECT site, COUNT(*) as count FROM form_routing GROUP BY site ORDER BY site`).all();
}

function updateRoutingTemplate(id, templateName) {
    return getDb().prepare(`
        UPDATE form_routing SET template_name = ?, overridden = 1, updated_at = datetime('now') WHERE id = ?
    `).run(templateName, id);
}

function getRoutingCount() {
    return getDb().prepare(`SELECT COUNT(*) as c FROM form_routing`).get().c;
}

function getRoutingById(id) {
    return getDb().prepare(`SELECT * FROM form_routing WHERE id = ?`).get(id);
}

function markRoutingPushed(id) {
    return getDb().prepare(`
        UPDATE form_routing SET readiness = 'pushed', updated_at = datetime('now') WHERE id = ?
    `).run(id);
}

// ── K2 Templates Cache ──────────────────────────────────────

function cacheK2Templates(templates) {
    const d = getDb();
    d.prepare(`DELETE FROM k2_templates`).run();
    const stmt = d.prepare(`
        INSERT INTO k2_templates (proc_name, display_name, folder, version, tier_class)
        VALUES (?, ?, ?, ?, ?)
    `);
    const txn = d.transaction((rows) => {
        for (const t of rows) {
            stmt.run(t.procName, t.displayName || null, t.folder || null, t.version || 1, t.tierClass || null);
        }
    });
    txn(templates);
}

function getCachedTemplates() {
    return getDb().prepare(`SELECT * FROM k2_templates ORDER BY proc_name`).all();
}

function getCachedTemplateCount() {
    return getDb().prepare(`SELECT COUNT(*) as c FROM k2_templates`).get().c;
}

// ── Utility ─────────────────────────────────────────────────

function dbToRoutingRow(row) {
    return {
        id: row.id,
        workflowName: row.workflow_name,
        listTitle: row.list_title,
        webUrl: row.web_url,
        site: row.site,
        tier: row.tier,
        templateName: row.template_name,
        smartObject: row.smart_object ? { name: row.smart_object, status: row.so_status } : null,
        smartForm: row.smart_form ? { name: row.smart_form, status: row.sf_status } : null,
        readiness: row.readiness,
        migrationPath: row.migration_path,
        overridden: !!row.overridden
    };
}

function dbToTemplateRow(row) {
    return {
        procName: row.proc_name,
        displayName: row.display_name,
        folder: row.folder,
        version: row.version,
        tierClass: row.tier_class
    };
}

module.exports = {
    getDb,
    saveAnalysisRun,
    getLatestAnalysisRun,
    upsertRouting,
    getAllRouting,
    getRoutingBySite,
    getRoutingStats,
    getSiteList,
    updateRoutingTemplate,
    getRoutingCount,
    getRoutingById,
    markRoutingPushed,
    cacheK2Templates,
    getCachedTemplates,
    getCachedTemplateCount,
    dbToRoutingRow,
    dbToTemplateRow
};
