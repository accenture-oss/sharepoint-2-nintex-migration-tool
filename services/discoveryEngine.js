// ============================================================
// SPD → K2 Five Migration Pipeline — Discovery Engine
// Parses CSV output from Get-SPMigrationComplexity.ps1
// and builds a structured artifact inventory
// ============================================================

const { parse } = require('csv-parse');
const { v4: uuidv4 } = require('uuid');

// CSV column definitions matching PowerShell output
const WORKFLOW_COLUMNS = [
    'WebUrl', 'WebTitle', 'ListTitle', 'ListUrl', 'WorkflowName',
    'WorkflowType', 'ActivityCount', 'ActionCount', 'ConditionCount',
    'ListItemCount', 'LastItemCreatedDate', 'LastModified', 'Notes'
];

const INFOPATH_COLUMNS = [
    'WebUrl', 'WebTitle', 'ListTitle', 'FormName', 'FormType', 'FormUrl',
    'RuleCount', 'ActionCount', 'ValidationCount', 'FormattingCount',
    'ConditionCount', 'DataConnectionCount', 'FieldCount',
    'ItemCount', 'LastItemCreatedDate', 'XsnLastModified', 'Notes'
];

class DiscoveryEngine {

    constructor() {
        this.workflows = [];
        this.forms = [];
        this.sites = new Map();     // WebUrl → site metadata
        this.inventory = null;
        this.lastImportTimestamp = null;
    }

    /**
     * Parse a workflow CSV buffer and add to inventory
     * @param {Buffer} csvBuffer - Raw CSV file content
     * @param {Function} onProgress - SSE progress callback (step, total, message)
     * @returns {Object} parse result summary
     */
    async parseWorkflowCSV(csvBuffer, onProgress) {
        const records = await this._parseCSV(csvBuffer);
        const total = records.length;
        let processed = 0;
        const errors = [];

        for (const row of records) {
            processed++;
            try {
                const wf = {
                    id: `wf-${uuidv4().slice(0, 8)}`,
                    webUrl: (row.WebUrl || '').trim(),
                    webTitle: (row.WebTitle || '').trim(),
                    listTitle: (row.ListTitle || '').trim(),
                    listUrl: (row.ListUrl || '').trim(),
                    workflowName: (row.WorkflowName || '').trim(),
                    workflowType: (row.WorkflowType || 'Unknown').trim(),
                    activityCount: parseInt(row.ActivityCount) || 0,
                    actionCount: parseInt(row.ActionCount) || 0,
                    conditionCount: parseInt(row.ConditionCount) || 0,
                    listItemCount: parseInt(row.ListItemCount) || 0,
                    lastItemCreatedDate: row.LastItemCreatedDate || null,
                    lastModified: row.LastModified || null,
                    notes: (row.Notes || '').trim(),
                    assetType: 'workflow'
                };

                if (wf.webUrl && wf.workflowName) {
                    this.workflows.push(wf);
                    this._registerSite(wf.webUrl, wf.webTitle);
                }
            } catch (err) {
                errors.push({ row: processed, error: err.message });
            }

            if (onProgress && processed % 100 === 0) {
                onProgress(processed, total, `Parsing workflows... ${processed}/${total}`);
            }
        }

        if (onProgress) onProgress(total, total, `Parsed ${this.workflows.length} workflows`);

        this.lastImportTimestamp = new Date().toISOString();
        return {
            type: 'workflow',
            totalRecords: total,
            imported: this.workflows.length,
            errors: errors.length,
            errorDetails: errors.slice(0, 20)
        };
    }

    /**
     * Parse an InfoPath CSV buffer and add to inventory
     */
    async parseInfoPathCSV(csvBuffer, onProgress) {
        const records = await this._parseCSV(csvBuffer);
        const total = records.length;
        let processed = 0;
        const errors = [];

        for (const row of records) {
            processed++;
            try {
                const form = {
                    id: `form-${uuidv4().slice(0, 8)}`,
                    webUrl: (row.WebUrl || '').trim(),
                    webTitle: (row.WebTitle || '').trim(),
                    listTitle: (row.ListTitle || '').trim(),
                    formName: (row.FormName || '').trim(),
                    formType: (row.FormType || 'Unknown').trim(),
                    formUrl: (row.FormUrl || '').trim(),
                    ruleCount: parseInt(row.RuleCount) || 0,
                    actionCount: parseInt(row.ActionCount) || 0,
                    validationCount: parseInt(row.ValidationCount) || 0,
                    formattingCount: parseInt(row.FormattingCount) || 0,
                    conditionCount: parseInt(row.ConditionCount) || 0,
                    dataConnectionCount: parseInt(row.DataConnectionCount) || 0,
                    fieldCount: parseInt(row.FieldCount) || 0,
                    itemCount: parseInt(row.ItemCount) || 0,
                    lastItemCreatedDate: row.LastItemCreatedDate || null,
                    xsnLastModified: row.XsnLastModified || null,
                    notes: (row.Notes || '').trim(),
                    assetType: 'form'
                };

                if (form.webUrl && form.formName) {
                    this.forms.push(form);
                    this._registerSite(form.webUrl, form.webTitle);
                }
            } catch (err) {
                errors.push({ row: processed, error: err.message });
            }

            if (onProgress && processed % 100 === 0) {
                onProgress(processed, total, `Parsing forms... ${processed}/${total}`);
            }
        }

        if (onProgress) onProgress(total, total, `Parsed ${this.forms.length} forms`);

        this.lastImportTimestamp = new Date().toISOString();
        return {
            type: 'infopath',
            totalRecords: total,
            imported: this.forms.length,
            errors: errors.length,
            errorDetails: errors.slice(0, 20)
        };
    }

    /**
     * Get site tree from discovered data
     */
    getSiteTree() {
        const tree = {};
        for (const [url, meta] of this.sites.entries()) {
            // Build hierarchy from URL structure
            const parts = url.replace(/https?:\/\/[^/]+/i, '').split('/').filter(Boolean);
            const rootUrl = url.match(/https?:\/\/[^/]+/i)?.[0] || url;

            if (!tree[rootUrl]) {
                tree[rootUrl] = { url: rootUrl, title: 'Root', children: {}, workflows: 0, forms: 0 };
            }

            // Count artifacts for this site
            const wfCount = this.workflows.filter(w => w.webUrl === url).length;
            const formCount = this.forms.filter(f => f.webUrl === url).length;

            tree[rootUrl].children[url] = {
                url,
                title: meta.title,
                path: '/' + parts.join('/'),
                workflows: wfCount,
                forms: formCount,
                totalArtifacts: wfCount + formCount
            };

            tree[rootUrl].workflows += wfCount;
            tree[rootUrl].forms += formCount;
        }
        return tree;
    }

    /**
     * Get full artifact inventory
     */
    getInventory() {
        const allItems = [...this.workflows, ...this.forms];
        return {
            totalSites: this.sites.size,
            totalWorkflows: this.workflows.length,
            totalForms: this.forms.length,
            totalArtifacts: allItems.length,
            lastImport: this.lastImportTimestamp,
            workflowsByType: this._groupBy(this.workflows, 'workflowType'),
            formsByType: this._groupBy(this.forms, 'formType'),
            siteBreakdown: Array.from(this.sites.entries()).map(([url, meta]) => ({
                url,
                title: meta.title,
                workflows: this.workflows.filter(w => w.webUrl === url).length,
                forms: this.forms.filter(f => f.webUrl === url).length
            })).sort((a, b) => (b.workflows + b.forms) - (a.workflows + a.forms))
        };
    }

    /**
     * Get all raw workflow records
     */
    getWorkflows() { return this.workflows; }

    /**
     * Get all raw form records
     */
    getForms() { return this.forms; }

    /**
     * Clear all imported data
     */
    reset() {
        this.workflows = [];
        this.forms = [];
        this.sites.clear();
        this.inventory = null;
        this.lastImportTimestamp = null;
    }

    // ── Internal helpers ─────────────────────────────────────────

    _registerSite(url, title) {
        if (!this.sites.has(url)) {
            this.sites.set(url, { title: title || url, discoveredAt: new Date().toISOString() });
        }
    }

    _groupBy(items, key) {
        const groups = {};
        items.forEach(item => {
            const val = item[key] || 'Unknown';
            if (!groups[val]) groups[val] = 0;
            groups[val]++;
        });
        return groups;
    }

    async _parseCSV(buffer) {
        return new Promise((resolve, reject) => {
            const records = [];
            const parser = parse(buffer, {
                columns: true,
                skip_empty_lines: true,
                trim: true,
                bom: true,
                relax_column_count: true
            });
            parser.on('data', (row) => records.push(row));
            parser.on('end', () => resolve(records));
            parser.on('error', (err) => reject(err));
        });
    }

    /**
     * Restore workflows from saved state
     */
    _restoreWorkflows(workflows) {
        this.workflows = workflows;
        for (const wf of workflows) {
            this._registerSite(wf.webUrl, wf.webTitle);
        }
        this.lastImportTimestamp = new Date().toISOString();
    }

    /**
     * Restore forms from saved state
     */
    _restoreForms(forms) {
        this.forms = forms;
        for (const f of forms) {
            this._registerSite(f.webUrl, f.webTitle);
        }
        this.lastImportTimestamp = new Date().toISOString();
    }
}

module.exports = { DiscoveryEngine };
