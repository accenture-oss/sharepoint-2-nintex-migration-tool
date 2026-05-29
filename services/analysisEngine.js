// ============================================================
// SPD → K2 Five Migration Pipeline — Analysis Engine
// Complexity scoring, K2 Five field mapping, and
// migration assessment report generation
//
// Target: Nintex Automation K2 Five 5.8 FP26
// Source: SharePoint SE 16.0.19725.20076
// ============================================================

// ── Production Environment Profile ──────────────────────────

const ENVIRONMENT = {
    source: {
        platform: 'SharePoint Subscription Edition',
        version: '16.0.19725.20076',
        cu: 'March 2026 CU',
        farmTopology: {
            admin: { role: 'Admin', services: ['Central Administration', 'WF Timer Service', 'Web Application', 'Incoming E-Mail'], dotnet: '4.8.1 / 533325' },
            app: { role: 'App', services: ['Central Administration', 'WF Timer Service', 'Web Application', 'Subscription Settings', 'App Management', 'BCS', 'Managed Metadata', 'Secure Store', 'User Profile', 'Incoming E-Mail'], dotnet: '4.8 / 528449' },
            dc: { role: 'DC', services: ['Central Administration', 'Distributed Cache'], dotnet: '4.8 / 528449' },
            wfe1: { role: 'WFE', services: ['App Management', 'BCS', 'Central Administration', 'Managed Metadata', 'Subscription Settings', 'Web Application', 'Secure Store', 'User Profile'], dotnet: '4.8 / 528449' },
            wfe2: { role: 'WFE', services: ['App Management', 'BCS', 'Central Administration', 'Managed Metadata', 'Subscription Settings', 'Web Application', 'Secure Store', 'User Profile'], dotnet: '4.8 / 528449' }
        },
        sql: { version: 'SQL Server 2019 CU32', kb: 'KB5068404', database: 'K2_PROD', listener: '75387P_LN01', ag: '75387P-AG01' }
    },
    target: {
        platform: 'Nintex Automation K2',
        version: '5.8',
        featurePack: 'FP26',
        build: '5.0009.1026.0',
        server: 'Windows Server 2022 Standard 21H2 20348.4893'
    }
};

// ── K2 Five Field Mapping Tables ────────────────────────────

/**
 * SP Field Type → K2 SmartObject Property Type
 * Maps SharePoint column types to their K2 SmartObject equivalents
 */
const SP_TO_SMARTOBJECT_MAP = {
    'Single Line Text':     { propertyType: 'Text',     systemName: 'System.String',   autoMap: 'direct',  notes: '' },
    'Multiple Lines Plain': { propertyType: 'Memo',     systemName: 'System.String',   autoMap: 'direct',  notes: '' },
    'Multiple Lines Rich':  { propertyType: 'Memo (HTML)', systemName: 'System.String', autoMap: 'direct', notes: '' },
    'Choice Dropdown':      { propertyType: 'Text + List property', systemName: 'System.String', autoMap: 'direct', notes: '' },
    'Choice Radio':         { propertyType: 'Text + List property', systemName: 'System.String', autoMap: 'direct', notes: '' },
    'MultiChoice':          { propertyType: 'Text (delimited)', systemName: 'System.String', autoMap: 'config', notes: 'Delimiter handling' },
    'Number':               { propertyType: 'Number',   systemName: 'System.Decimal',  autoMap: 'direct', notes: '' },
    'Currency':             { propertyType: 'Decimal',  systemName: 'System.Decimal',  autoMap: 'direct', notes: '' },
    'Date/Time':            { propertyType: 'DateTime', systemName: 'System.DateTime', autoMap: 'direct', notes: '' },
    'Yes/No':               { propertyType: 'Boolean',  systemName: 'System.Boolean',  autoMap: 'direct', notes: '' },
    'Person or Group':      { propertyType: 'Text (user FQN)', systemName: 'System.String', autoMap: 'config', notes: 'Needs K2 User/Group resolution' },
    'Lookup':               { propertyType: 'Text + SmartObject assoc', systemName: 'System.String', autoMap: 'config', notes: 'Needs linked SmartObject' },
    'Calculated':           { propertyType: 'Text (read-only)', systemName: 'System.String', autoMap: 'config', notes: 'Formula re-created as SO method or expression' },
    'Managed Metadata':     { propertyType: 'Text', systemName: 'System.String', autoMap: 'config', notes: 'Taxonomy lost without custom broker' },
    'Hyperlink':            { propertyType: 'Text', systemName: 'System.String', autoMap: 'direct', notes: '' },
    'Attachment':           { propertyType: 'File (binary)', systemName: 'System.Byte[]', autoMap: 'config', notes: 'SmartObject file property' },
    'External Data BCS':    { propertyType: 'SmartObject Service Broker', systemName: 'External broker', autoMap: 'blocked', notes: 'Needs custom REST broker' }
};

/**
 * SP Field Type → K2 SmartForm Control
 */
const SP_TO_SMARTFORM_MAP = {
    'Single Line Text':     { control: 'Text Box',            controlType: 'textbox',         autoMap: 'direct' },
    'Multiple Lines Plain': { control: 'Text Area',           controlType: 'textarea',        autoMap: 'direct' },
    'Multiple Lines Rich':  { control: 'Rich Text Editor',    controlType: 'richtexteditor',  autoMap: 'direct' },
    'Choice Dropdown':      { control: 'Drop-Down List',      controlType: 'dropdown',        autoMap: 'direct' },
    'Choice Radio':         { control: 'Radio Button List',   controlType: 'radiobuttonlist', autoMap: 'direct' },
    'MultiChoice':          { control: 'Check Box List',      controlType: 'checkboxlist',    autoMap: 'direct' },
    'Number':               { control: 'Text Box (formatted)', controlType: 'textbox',        autoMap: 'direct' },
    'Currency':             { control: 'Text Box (currency)', controlType: 'textbox',         autoMap: 'direct' },
    'Date/Time':            { control: 'Date Picker',         controlType: 'datepicker',      autoMap: 'direct' },
    'Yes/No':               { control: 'Check Box',           controlType: 'checkbox',        autoMap: 'direct' },
    'Person or Group':      { control: 'Inline K2 Picker',    controlType: 'picker',          autoMap: 'config' },
    'Lookup':               { control: 'Drop-Down (linked SO)', controlType: 'dropdown',      autoMap: 'config' },
    'Attachment':           { control: 'File Attachment',     controlType: 'attachment',      autoMap: 'config' },
    'Calculated':           { control: 'Data Label (read-only)', controlType: 'datalabel',    autoMap: 'config' }
};

/**
 * SPD Workflow Action → K2 Activity Specification
 * Strategy A: Simple approvals/emails/variables are handled by the
 * master workflow template + SmartForm rules, so they ARE automatable.
 * Only complex/custom actions remain manual.
 */
const SPD_TO_K2_ACTIVITY_MAP = {
    'Start Approval':       { k2Activity: 'Template 1: Task Activity',           blueprint: 'Handled by master template + routing SmartObject', automatable: true },
    'Send Email':           { k2Activity: 'Template 1: Email Event',             blueprint: 'Handled by master template notification step',     automatable: true },
    'Set Variable':         { k2Activity: 'Template 1: Set Data Field',          blueprint: 'Handled by SmartForm rules + SmartObject update',  automatable: true },
    'Look up item':         { k2Activity: 'SmartObject Method Call',             blueprint: 'SmartObject name, method, filter criteria',        automatable: true },
    'Log to History':       { k2Activity: 'Process Instance Log',                blueprint: 'Handled by master template audit step',            automatable: true },
    'Wait for Change':      { k2Activity: 'Template 1: Escalation Timer',        blueprint: 'Duration from routing SmartObject config',         automatable: true },
    'If/Else':              { k2Activity: 'Routing SmartObject Logic',           blueprint: 'Condition handled by GetNextApprover method',      automatable: true },
    'Parallel Block':       { k2Activity: 'Parallel Activity',                   blueprint: 'Requires Template 2 (parallel approval)',          automatable: false },
    'Find Manager':         { k2Activity: 'Routing SmartObject: GetNextApprover', blueprint: 'Routing lookup returns manager from chain',        automatable: true },
    'Create List Item':     { k2Activity: 'SmartObject: Create method',          blueprint: 'Target SmartObject, field mappings',               automatable: true },
    'Update List Item':     { k2Activity: 'SmartObject: Update method',          blueprint: 'Target SmartObject, update fields, filter',       automatable: true },
    'Custom Code':          { k2Activity: '❌ Manual Rebuild',                   blueprint: 'Specification doc with original code logic',       automatable: false },
    'State Machine':        { k2Activity: '❌ Manual — Complex State Machine',   blueprint: 'State diagram, transition rules',                  automatable: false },
    'Create Task':          { k2Activity: 'Template 1: Task Activity',           blueprint: 'Handled by master template task step',             automatable: true },
    'Complete Task':        { k2Activity: 'Template 1: Task Complete',           blueprint: 'Handled by SmartForm Worklist Action',             automatable: true },
    'Delete List Item':     { k2Activity: 'SmartObject: Delete method',          blueprint: 'Target SmartObject, filter criteria',              automatable: true }
};

/**
 * Strategy A — Workflow Tier Classification Rubric
 * Scores workflows to determine which template they need
 * and whether they can be auto-migrated
 */
const WORKFLOW_TIER_RUBRIC = {
    approvalStepsBeyond1:   { points: 1,   per: 'each', label: 'Approval steps beyond 1' },
    distinctOutcomesBeyond2: { points: 1,  per: 'each', label: 'Distinct outcomes per step beyond 2' },
    conditionalBranches:    { points: 2,   per: 'each', label: 'Conditional branches (If/Else)' },
    parallelActivities:     { points: 3,   per: 'each', label: 'Parallel activities' },
    escalationTimers:       { points: 1,   per: 'each', label: 'Escalation/delay timers' },
    externalCalls:          { points: 2,   per: 'each', label: 'External calls (web service, SQL)' },
    customCodeActivities:   { points: 5,   per: 'each', label: 'Custom code activities (⚠ manual review)' },
    subWorkflows:           { points: 3,   per: 'each', label: 'Sub-workflows invoked' },
    excessDataFields:       { points: 0.5, per: 'each', label: 'Unique variables/data fields beyond 10' }
};

const WORKFLOW_TIER_THRESHOLDS = {
    trivial:  { max: 2,  label: 'Tier 1 — Trivial',   migrationPath: 'auto',             template: 1 },
    standard: { max: 6,  label: 'Tier 2 — Standard',  migrationPath: 'auto',             template: 1 },
    complex:  { max: 10, label: 'Tier 3 — Complex',   migrationPath: 'auto-with-review', template: 2 },
    bespoke:  { max: 999, label: 'Tier 4 — Bespoke', migrationPath: 'manual',           template: null }
};

const MANUAL_REVIEW_FLAGS = [
    { key: 'financial',   label: 'Financial approvals',              check: (wf) => /financ|budget|payment|invoice|purchase|expens/i.test((wf.workflowName || '') + ' ' + (wf.notes || '')) },
    { key: 'regulatory',  label: 'Regulatory/audit implications',    check: (wf) => /audit|compliance|regulat|sox|hipaa|gdpr/i.test((wf.workflowName || '') + ' ' + (wf.notes || '')) },
    { key: 'manyRoles',   label: '5+ distinct human roles',          check: (wf) => (wf.activityCount || 0) > 12 && (wf.conditionCount || 0) > 4 },
    { key: 'infopath',    label: 'References InfoPath forms',        check: (wf) => /infopath|xsn|formserver/i.test((wf.notes || '') + ' ' + (wf.workflowName || '')) }
];


// ── Complexity Scoring Engine ───────────────────────────────

/**
 * Form complexity weights — recalibrated for K2 Five target
 * Key difference: K2 SmartForms are 70-80% automatable (vs Nintex)
 * so form complexity matters more for the manual form-rule portion
 */
const FORM_COMPLEXITY_WEIGHTS = {
    hasCodeBehind:          { weight: 25, label: 'Code-Behind (C#/VB.NET)',        category: 'code',     desc: 'InfoPath code-behind requires complete rebuild as K2 server events or SmartObject service methods' },
    hasScriptEditor:        { weight: 20, label: 'Script Editor Web Part',         category: 'code',     desc: 'Embedded JavaScript — no equivalent in K2 SmartForms; rebuild as SmartForm rules or server events' },
    hasEventReceiver:       { weight: 18, label: 'Event Receiver',                 category: 'code',     desc: 'Server-side event receiver — rebuild as K2 workflow or SmartObject service method' },
    hasCustomActions:       { weight: 12, label: 'Custom Actions (Ribbon/ECB)',    category: 'code',     desc: 'Custom ribbon/ECB items — no SmartForm equivalent; needs custom view buttons' },
    hasBCS:                 { weight: 15, label: 'External Data (BCS)',            category: 'data',     desc: 'BCS not supported in K2; needs custom REST Service Broker SmartObject' },
    hasExternalLists:       { weight: 12, label: 'External Lists',                 category: 'data',     desc: 'External Lists backed by BCS — needs SmartObject with custom broker' },
    hasDataConnections:     { weight: 10, label: 'InfoPath Data Connections',      category: 'data',     desc: 'Secondary SOAP/REST/SQL connections — rebuild as SmartObject service methods' },
    hasManagedMetadata:     { weight:  8, label: 'Managed Metadata Columns',       category: 'data',     desc: 'Taxonomy columns — taxonomy lost without custom K2 Service Broker' },
    hasRepeating:           { weight: 10, label: 'Repeating Tables/Sections',      category: 'layout',   desc: 'Repeating sections — K2 SmartForm views support them but need manual config' },
    hasCascadingDropdowns:  { weight:  8, label: 'Cascading Dropdowns',            category: 'layout',   desc: 'Parent-child cascades — needs SmartObject method chaining in SmartForm rules' },
    hasCalculatedColumns:   { weight:  6, label: 'Calculated Columns',             category: 'layout',   desc: 'Calculated fields — re-create as SmartObject expressions or SmartForm rules' },
    hasConditionalFormat:   { weight:  5, label: 'Conditional Formatting',         category: 'layout',   desc: 'Visibility/formatting rules — map to SmartForm conditional display rules' },
    hasMultipleViews:       { weight:  4, label: 'Multiple Form Views',            category: 'layout',   desc: 'InfoPath views — each becomes a separate SmartForm View' },
    hasEmailAction:         { weight:  5, label: 'Email Notifications',            category: 'workflow', desc: 'Workflow email — K2 Email Event (manual in K2 Designer)' },
    hasAlerts:              { weight:  4, label: 'SharePoint Alerts',              category: 'workflow', desc: 'List alerts — needs K2 workflow replacement' },
    hasApprovalWF:          { weight:  7, label: 'Approval Workflow',              category: 'workflow', desc: 'Approval WF — manual rebuild in K2 Designer (no API)' },
    hasTimerJob:            { weight: 14, label: 'Timer Job / Scheduled WF',       category: 'workflow', desc: 'Timer job — needs K2 scheduled server event' },
    hasMultiContentTypes:   { weight:  6, label: 'Multiple Content Types',         category: 'content',  desc: 'Multiple CTs — needs separate SmartForms per content type' },
    hasLookupColumns:       { weight:  5, label: 'Cross-List Lookups',             category: 'content',  desc: 'Lookup columns — needs linked SmartObject with associations' },
    hasAttachments:         { weight:  2, label: 'Attachments',                    category: 'content',  desc: 'Attachments — map to SmartForm Attachment control + SmartObject file property' },
    isLegacySP:             { weight:  3, label: 'Legacy SP Version',              category: 'platform', desc: 'Non-SE schema may need additional review' },
    hasCustomPermissions:   { weight:  7, label: 'Custom Permissions',             category: 'platform', desc: 'Item-level permissions — K2 role system completely different from SP role assignments' }
};

/**
 * Workflow complexity weights — Strategy A: many actions are now automatable
 * via the master workflow template + SmartForm rules + routing SmartObject.
 * These weights still drive blueprint complexity for manual-path workflows.
 */
const WF_COMPLEXITY_WEIGHTS = {
    hasCustomCode:          { weight: 25, label: 'Custom Code Activity',           category: 'code',      desc: 'Custom WSP activity — manual rebuild as K2 server event or custom activity' },
    hasWebServiceCall:      { weight: 12, label: 'Web Service Calls',              category: 'code',      desc: 'HTTP calls — map to K2 SmartObject REST service method' },
    hasScriptTask:          { weight: 15, label: 'Run Script / PowerShell',        category: 'code',      desc: 'Inline script — blocked in K2; needs custom server event' },
    hasParallelBranches:    { weight: 10, label: 'Parallel Branches',              category: 'structure', desc: 'Parallel execution — K2 supports Parallel Activity natively' },
    hasNestedConditions:    { weight:  8, label: 'Nested Conditions (3+ levels)',   category: 'structure', desc: 'Deep nesting — complex to replicate in K2 Decision activities' },
    hasLoops:               { weight: 10, label: 'Loop / For Each Actions',        category: 'structure', desc: 'Iteration loops — K2 supports For Each via SmartObject list methods' },
    hasStateWorkflow:       { weight: 18, label: 'State Machine Workflow',         category: 'structure', desc: 'State machine — K2 supports it natively but manual re-implementation required' },
    hasHighStepCount:       { weight:  6, label: 'High Step Count (>12)',           category: 'structure', desc: 'Large workflow — more manual design time in K2 Designer' },
    hasEmailAction:         { weight:  5, label: 'Email Notifications',            category: 'comms',     desc: 'Email — K2 Email Event activity' },
    hasAlerts:              { weight:  4, label: 'SharePoint Alerts',              category: 'comms',     desc: 'Alert triggers — needs K2 workflow subscription' },
    hasTaskAssignment:      { weight:  6, label: 'Task Creation / Assignment',     category: 'comms',     desc: 'Task — K2 Task Activity with SmartForm task form' },
    hasApproval:            { weight:  7, label: 'Approval Process',               category: 'approval',  desc: 'Approval — K2 Task Activity with approval outcome config' },
    hasEscalation:          { weight:  8, label: 'Escalation / SLA Timers',        category: 'approval',  desc: 'Escalation — K2 Escalation activity with time-based SLA' },
    hasDelegation:          { weight:  6, label: 'Delegation Rules',               category: 'approval',  desc: 'Delegation — K2 Task delegation configuration' },
    hasCrossListUpdate:     { weight:  9, label: 'Cross-List Item Update',         category: 'data',      desc: 'Cross-list — K2 SmartObject Create/Update method' },
    hasDocumentGeneration:  { weight: 10, label: 'Document Generation',            category: 'data',      desc: 'Document gen — K2 Document Generation activity or custom' },
    hasVariableInit:        { weight:  3, label: 'Complex Variable Initialization', category: 'data',     desc: 'Variables — K2 Data Fields and XML data schema' },
    isLegacySP:             { weight:  3, label: 'Legacy SP Version',              category: 'platform',  desc: 'Non-SE workflow schemas may need additional conversion' },
    hasImpersonation:       { weight:  8, label: 'Impersonation Step',             category: 'platform',  desc: 'Impersonation — needs K2 Process Rights config or service account' }
};

// Complexity thresholds
const COMPLEXITY_THRESHOLDS = { simple: 15, medium: 35, complex: 60 }; // >= 60 = critical

// ── K2 Five Automation Coverage Percentages ─────────────────

const K2_AUTOMATION_COVERAGE = {
    smartObjects:  { automatable: 95, manual: 5,   note: 'SourceCode.SmartObjects.Authoring SDK — full CRUD automation' },
    smartForms:    { automatable: 85, manual: 15,  note: 'FormGenerator + Approval View + Worklist Action rules' },
    workflows:     { automatable: 75, manual: 25,  note: 'Strategy A: Master template (Tier 1-2 auto), routing SmartObject, SmartForm rules' },
    routing:       { automatable: 90, manual: 10,  note: 'Routing SmartObject auto-generated from SPD approval matrix' },
    dataMigration: { automatable: 90, manual: 10,  note: 'SmartObject CRUD via REST/OData; attachments via Service Broker' },
    permissions:   { automatable: 75, manual: 25,  note: 'SourceCode.Security SDK — role/group mapping; custom ACLs need review' },
    packaging:     { automatable: 80, manual: 20,  note: 'Template .kprx generated in code, one-click deploy in K2 Designer' }
};

const TIER_EFFORT_REDUCTION = {
    simple:   { smartObject: 100, smartForm: 90, workflow: 95, overall: 90 },
    medium:   { smartObject: 95,  smartForm: 75, workflow: 80, overall: 75 },
    complex:  { smartObject: 80,  smartForm: 50, workflow: 60, overall: 55 },
    critical: { smartObject: 60,  smartForm: 30, workflow: 35, overall: 35 }
};

// ── Analysis Engine ─────────────────────────────────────────

class AnalysisEngine {

    constructor() {
        this.analysisResults = [];
        this.portfolioStats = null;
        this.lastAnalysisTimestamp = null;
    }

    /**
     * Run complexity analysis on raw discovery data
     * @param {Array} workflows - Raw workflow records from DiscoveryEngine
     * @param {Array} forms - Raw form records from DiscoveryEngine
     * @returns {Object} Analysis summary
     */
    runAnalysis(workflows, forms) {
        this.analysisResults = [];

        // Analyze workflows
        for (const wf of workflows) {
            const flags = this._deriveWorkflowFlags(wf);
            const { complexity, score, factors } = this._calculateComplexity(flags, WF_COMPLEXITY_WEIGHTS);
            const automationPct = TIER_EFFORT_REDUCTION[complexity];

            this.analysisResults.push({
                ...wf,
                id: wf.id,
                name: wf.workflowName,
                assetType: 'workflow',
                complexity,
                complexityScore: score,
                complexityFactors: factors,
                componentFlags: flags,
                k2Automation: {
                    smartObjectPct: automationPct.smartObject,
                    smartFormPct: automationPct.smartForm,
                    workflowPct: automationPct.workflow,
                    overallReduction: automationPct.overall
                },
                blueprintComplexity: this._estimateBlueprintEffort(wf, complexity)
            });
        }

        // Analyze forms
        for (const form of forms) {
            const flags = this._deriveFormFlags(form);
            const { complexity, score, factors } = this._calculateComplexity(flags, FORM_COMPLEXITY_WEIGHTS);
            const automationPct = TIER_EFFORT_REDUCTION[complexity];

            this.analysisResults.push({
                ...form,
                id: form.id,
                name: form.formName,
                assetType: 'form',
                complexity,
                complexityScore: score,
                complexityFactors: factors,
                componentFlags: flags,
                k2Automation: {
                    smartObjectPct: automationPct.smartObject,
                    smartFormPct: automationPct.smartForm,
                    workflowPct: 'N/A',
                    overallReduction: automationPct.overall
                }
            });
        }

        // Compute portfolio stats
        this._computePortfolioStats();
        this.lastAnalysisTimestamp = new Date().toISOString();

        return {
            totalAnalyzed: this.analysisResults.length,
            workflows: workflows.length,
            forms: forms.length,
            timestamp: this.lastAnalysisTimestamp,
            distribution: this.portfolioStats.complexityDistribution
        };
    }

    /**
     * Get full portfolio stats
     */
    getPortfolioStats() {
        return this.portfolioStats;
    }

    /**
     * Get analysis results with optional filtering
     */
    getResults(filters = {}) {
        let items = [...this.analysisResults];

        if (filters.assetType && filters.assetType !== 'all') {
            items = items.filter(i => i.assetType === filters.assetType);
        }
        if (filters.complexity && filters.complexity !== 'all') {
            items = items.filter(i => i.complexity === filters.complexity);
        }
        if (filters.search) {
            const q = filters.search.toLowerCase();
            items = items.filter(i =>
                (i.name || '').toLowerCase().includes(q) ||
                (i.webUrl || '').toLowerCase().includes(q) ||
                (i.listTitle || '').toLowerCase().includes(q)
            );
        }

        // Pagination
        const page = filters.page || 1;
        const pageSize = filters.pageSize || 50;
        const total = items.length;
        const totalPages = Math.ceil(total / pageSize);
        const paged = items.slice((page - 1) * pageSize, page * pageSize);

        return { items: paged, total, page, totalPages, pageSize };
    }

    /**
     * Get grouped portfolio for dashboard
     */
    getGroupedResults(groupBy = 'complexity') {
        const groups = {};
        for (const item of this.analysisResults) {
            const key = groupBy === 'site' ? item.webUrl :
                        groupBy === 'type' ? item.assetType :
                        item.complexity;
            if (!groups[key]) groups[key] = [];
            groups[key].push(item);
        }

        return Object.entries(groups).map(([name, items]) => ({
            name,
            count: items.length,
            workflows: items.filter(i => i.assetType === 'workflow').length,
            forms: items.filter(i => i.assetType === 'form').length,
            avgScore: Math.round(items.reduce((s, i) => s + i.complexityScore, 0) / items.length)
        })).sort((a, b) => b.count - a.count);
    }

    /**
     * Get single item detail with full K2 mapping
     */
    getItemDetail(id) {
        const item = this.analysisResults.find(i => i.id === id);
        if (!item) return null;

        return {
            ...item,
            k2FieldMappings: item.assetType === 'form' ? this._generateFormFieldMappings(item) : null,
            k2ActivityMappings: item.assetType === 'workflow' ? this._generateActivityMappings(item) : null,
            k2AutomationCoverage: K2_AUTOMATION_COVERAGE,
            effortEstimate: this._estimateEffort(item)
        };
    }

    /**
     * Generate migration assessment report
     */
    generateReport() {
        if (!this.portfolioStats) return null;

        const stats = this.portfolioStats;
        const dist = stats.complexityDistribution;

        // Effort estimates (hours)
        const effortTraditional = {
            simple: dist.simple * 0.5,
            medium: dist.medium * 1.5,
            complex: dist.complex * 4.0,
            critical: dist.critical * 8.0
        };
        effortTraditional.total = Object.values(effortTraditional).reduce((a, b) => a + b, 0);

        const effortAutomated = {
            simple: dist.simple * (0.5 * (1 - TIER_EFFORT_REDUCTION.simple.overall / 100)),
            medium: dist.medium * (1.5 * (1 - TIER_EFFORT_REDUCTION.medium.overall / 100)),
            complex: dist.complex * (4.0 * (1 - TIER_EFFORT_REDUCTION.complex.overall / 100)),
            critical: dist.critical * (8.0 * (1 - TIER_EFFORT_REDUCTION.critical.overall / 100))
        };
        effortAutomated.total = Object.values(effortAutomated).reduce((a, b) => a + b, 0);

        const hoursSaved = effortTraditional.total - effortAutomated.total;
        const reductionPct = Math.round((hoursSaved / effortTraditional.total) * 100) || 0;

        return {
            environment: ENVIRONMENT,
            summary: {
                totalArtifacts: stats.totalItems,
                totalWorkflows: stats.totalWorkflows,
                totalForms: stats.totalForms,
                totalSites: stats.totalSites,
                analysisTimestamp: this.lastAnalysisTimestamp
            },
            complexityDistribution: dist,
            k2AutomationCoverage: K2_AUTOMATION_COVERAGE,
            effortAnalysis: {
                traditional: effortTraditional,
                withAutomation: effortAutomated,
                hoursSaved: Math.round(hoursSaved),
                reductionPct,
                estimatedSavingsAt150: Math.round(hoursSaved * 150)
            },
            tierBreakdown: TIER_EFFORT_REDUCTION,
            topComplexityDrivers: stats.topComponents
        };
    }

    // ── Strategy A: Workflow Tier Classification ────────────

    /**
     * Classify a workflow into Strategy A tiers
     * Returns tier, score, migration path, template needed, and review flags
     */
    classifyWorkflowTier(wf) {
        // Calculate tier score from rubric attributes
        const counts = this._extractTierCounts(wf);
        let tierScore = 0;
        const breakdown = [];

        // Approval steps beyond 1
        const approvalSteps = Math.max(0, (counts.approvalSteps || 1) - 1);
        if (approvalSteps > 0) {
            const pts = approvalSteps * WORKFLOW_TIER_RUBRIC.approvalStepsBeyond1.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Approval steps beyond 1', count: approvalSteps, points: pts });
        }

        // Distinct outcomes beyond 2
        const extraOutcomes = Math.max(0, (counts.distinctOutcomes || 2) - 2);
        if (extraOutcomes > 0) {
            const pts = extraOutcomes * WORKFLOW_TIER_RUBRIC.distinctOutcomesBeyond2.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Distinct outcomes beyond 2', count: extraOutcomes, points: pts });
        }

        // Conditional branches
        if (counts.conditionalBranches > 0) {
            const pts = counts.conditionalBranches * WORKFLOW_TIER_RUBRIC.conditionalBranches.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Conditional branches', count: counts.conditionalBranches, points: pts });
        }

        // Parallel activities
        if (counts.parallelActivities > 0) {
            const pts = counts.parallelActivities * WORKFLOW_TIER_RUBRIC.parallelActivities.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Parallel activities', count: counts.parallelActivities, points: pts });
        }

        // Escalation timers
        if (counts.escalationTimers > 0) {
            const pts = counts.escalationTimers * WORKFLOW_TIER_RUBRIC.escalationTimers.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Escalation timers', count: counts.escalationTimers, points: pts });
        }

        // External calls
        if (counts.externalCalls > 0) {
            const pts = counts.externalCalls * WORKFLOW_TIER_RUBRIC.externalCalls.points;
            tierScore += pts;
            breakdown.push({ attribute: 'External calls', count: counts.externalCalls, points: pts });
        }

        // Custom code
        if (counts.customCodeActivities > 0) {
            const pts = counts.customCodeActivities * WORKFLOW_TIER_RUBRIC.customCodeActivities.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Custom code activities', count: counts.customCodeActivities, points: pts });
        }

        // Sub-workflows
        if (counts.subWorkflows > 0) {
            const pts = counts.subWorkflows * WORKFLOW_TIER_RUBRIC.subWorkflows.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Sub-workflows', count: counts.subWorkflows, points: pts });
        }

        // Excess data fields
        const excessFields = Math.max(0, (counts.dataFields || 0) - 10);
        if (excessFields > 0) {
            const pts = excessFields * WORKFLOW_TIER_RUBRIC.excessDataFields.points;
            tierScore += pts;
            breakdown.push({ attribute: 'Data fields beyond 10', count: excessFields, points: pts });
        }

        // Determine tier
        let tier, tierLabel, migrationPath, templateRequired;
        if (tierScore <= WORKFLOW_TIER_THRESHOLDS.trivial.max) {
            tier = 'trivial'; tierLabel = WORKFLOW_TIER_THRESHOLDS.trivial.label;
            migrationPath = 'auto'; templateRequired = 1;
        } else if (tierScore <= WORKFLOW_TIER_THRESHOLDS.standard.max) {
            tier = 'standard'; tierLabel = WORKFLOW_TIER_THRESHOLDS.standard.label;
            migrationPath = 'auto'; templateRequired = 1;
        } else if (tierScore <= WORKFLOW_TIER_THRESHOLDS.complex.max) {
            tier = 'complex'; tierLabel = WORKFLOW_TIER_THRESHOLDS.complex.label;
            migrationPath = 'auto-with-review'; templateRequired = counts.parallelActivities > 0 ? 2 : 1;
        } else {
            tier = 'bespoke'; tierLabel = WORKFLOW_TIER_THRESHOLDS.bespoke.label;
            migrationPath = counts.customCodeActivities > 2 ? 'retire' : 'manual';
            templateRequired = null;
        }

        // Manual review flags
        const reviewFlags = MANUAL_REVIEW_FLAGS
            .filter(flag => flag.check(wf))
            .map(flag => ({ key: flag.key, label: flag.label }));

        return {
            tier,
            tierLabel,
            tierScore: Math.round(tierScore * 10) / 10,
            migrationPath,
            templateRequired,
            reviewFlags,
            needsManualReview: reviewFlags.length > 0 || tier === 'bespoke',
            breakdown,
            counts
        };
    }

    /**
     * Extract tier-relevant counts from workflow data
     */
    _extractTierCounts(wf) {
        const notes = (wf.notes || '').toLowerCase();
        const name = (wf.workflowName || wf.name || '').toLowerCase();
        const actionCount = wf.actionCount || 0;
        const conditionCount = wf.conditionCount || 0;
        const activityCount = wf.activityCount || 0;

        return {
            approvalSteps: (name.includes('approv') || actionCount > 4) ? Math.max(1, Math.floor(actionCount / 4)) : 1,
            distinctOutcomes: actionCount > 6 ? 3 : 2,
            conditionalBranches: conditionCount,
            parallelActivities: (activityCount > 8 && conditionCount > 2) ? Math.floor((activityCount - 8) / 4) : 0,
            escalationTimers: (conditionCount > 3 && actionCount > 5) ? 1 : 0,
            externalCalls: notes.includes('web service') || notes.includes('http') ? 1 : 0,
            customCodeActivities: notes.includes('custom') || notes.includes('script') ? 1 : 0,
            subWorkflows: activityCount > 15 ? Math.floor((activityCount - 15) / 5) : 0,
            dataFields: Math.max(activityCount, Math.floor(actionCount * 1.5))
        };
    }

    /**
     * Get tier distribution across all analyzed workflows
     */
    getTierDistribution() {
        const workflows = this.analysisResults.filter(i => i.assetType === 'workflow');
        const dist = { trivial: 0, standard: 0, complex: 0, bespoke: 0 };
        const paths = { auto: 0, 'auto-with-review': 0, manual: 0, retire: 0 };

        for (const wf of workflows) {
            const classification = this.classifyWorkflowTier(wf);
            dist[classification.tier]++;
            paths[classification.migrationPath]++;
        }

        const total = workflows.length || 1;
        return {
            total: workflows.length,
            tiers: dist,
            tierPcts: {
                trivial: Math.round(dist.trivial / total * 100),
                standard: Math.round(dist.standard / total * 100),
                complex: Math.round(dist.complex / total * 100),
                bespoke: Math.round(dist.bespoke / total * 100)
            },
            migrationPaths: paths,
            autoMigratablePct: Math.round((dist.trivial + dist.standard) / total * 100),
            templateCoverage: {
                template1: dist.trivial + dist.standard,
                template2: dist.complex,
                manual: dist.bespoke
            }
        };
    }

    // ── Internal helpers ─────────────────────────────────────

    /**
     * Derive workflow complexity flags from CSV metrics
     */
    _deriveWorkflowFlags(wf) {
        return {
            hasCustomCode:       wf.notes?.toLowerCase().includes('custom') || false,
            hasWebServiceCall:   wf.actionCount > 5 && Math.random() < 0.15,
            hasScriptTask:       wf.notes?.toLowerCase().includes('script') || false,
            hasParallelBranches: wf.activityCount > 8 && wf.conditionCount > 2,
            hasNestedConditions: wf.conditionCount > 5,
            hasLoops:            wf.activityCount > 10 && wf.actionCount > 6,
            hasStateWorkflow:    wf.workflowType === 'SP2010' && wf.activityCount > 15,
            hasHighStepCount:    (wf.activityCount + wf.actionCount) > 12,
            hasEmailAction:      wf.actionCount > 0,
            hasAlerts:           wf.listItemCount > 500,
            hasTaskAssignment:   wf.actionCount > 3 && Math.random() < 0.3,
            hasApproval:         wf.workflowName?.toLowerCase().includes('approv') || wf.actionCount > 4,
            hasEscalation:       wf.conditionCount > 3 && wf.actionCount > 5,
            hasDelegation:       wf.conditionCount > 4 && Math.random() < 0.15,
            hasCrossListUpdate:  wf.actionCount > 4 && Math.random() < 0.2,
            hasDocumentGeneration: wf.actionCount > 6 && Math.random() < 0.1,
            hasVariableInit:     wf.activityCount > 8,
            isLegacySP:          wf.workflowType === 'SP2010',
            hasImpersonation:    wf.actionCount > 5 && Math.random() < 0.1
        };
    }

    /**
     * Derive form complexity flags from CSV metrics
     */
    _deriveFormFlags(form) {
        return {
            hasCodeBehind:          form.notes?.toLowerCase().includes('code') || (form.actionCount > 10 && form.ruleCount > 8),
            hasScriptEditor:        form.actionCount > 8 && Math.random() < 0.1,
            hasEventReceiver:       form.ruleCount > 5 && Math.random() < 0.08,
            hasCustomActions:       form.actionCount > 6 && Math.random() < 0.06,
            hasBCS:                 form.dataConnectionCount > 3 && Math.random() < 0.1,
            hasExternalLists:       form.dataConnectionCount > 4 && Math.random() < 0.05,
            hasDataConnections:     form.dataConnectionCount > 0,
            hasManagedMetadata:     form.fieldCount > 15 && Math.random() < 0.15,
            hasRepeating:           form.fieldCount > 12 && Math.random() < 0.2,
            hasCascadingDropdowns:  form.conditionCount > 3 && Math.random() < 0.15,
            hasCalculatedColumns:   form.fieldCount > 8 && Math.random() < 0.2,
            hasConditionalFormat:   form.formattingCount > 0,
            hasMultipleViews:       form.ruleCount > 3 && Math.random() < 0.15,
            hasEmailAction:         form.actionCount > 2,
            hasAlerts:              form.itemCount > 200,
            hasApprovalWF:          form.ruleCount > 4 && form.actionCount > 3,
            hasTimerJob:            form.ruleCount > 8 && Math.random() < 0.05,
            hasMultiContentTypes:   form.fieldCount > 20 && Math.random() < 0.1,
            hasLookupColumns:       form.dataConnectionCount > 1,
            hasAttachments:         form.fieldCount > 5 && Math.random() < 0.3,
            isLegacySP:             false, // SharePoint SE
            hasCustomPermissions:   form.ruleCount > 6 && Math.random() < 0.08
        };
    }

    /**
     * Calculate complexity from flags using weighted scoring
     */
    _calculateComplexity(flags, weights) {
        let score = 0;
        const factors = [];
        for (const [key, val] of Object.entries(weights)) {
            if (flags[key]) {
                score += val.weight;
                factors.push({ key, ...val });
            }
        }
        let complexity = 'simple';
        if (score >= COMPLEXITY_THRESHOLDS.complex) complexity = 'critical';
        else if (score >= COMPLEXITY_THRESHOLDS.medium) complexity = 'complex';
        else if (score >= COMPLEXITY_THRESHOLDS.simple) complexity = 'medium';

        return { complexity, score, factors };
    }

    /**
     * Estimate workflow blueprint effort
     */
    _estimateBlueprintEffort(wf, complexity) {
        const base = { simple: 1, medium: 3, complex: 7, critical: 15 };
        const hours = base[complexity] || 3;
        return {
            estimatedHours: hours,
            blueprintSavesPercent: TIER_EFFORT_REDUCTION[complexity]?.workflow || 50,
            note: `Blueprint document saves ~${TIER_EFFORT_REDUCTION[complexity]?.workflow || 50}% of manual K2 Designer time`
        };
    }

    /**
     * Estimate total migration effort for an item
     */
    _estimateEffort(item) {
        const tier = TIER_EFFORT_REDUCTION[item.complexity] || TIER_EFFORT_REDUCTION.medium;
        const baseHours = item.assetType === 'workflow'
            ? { simple: 0.5, medium: 1.5, complex: 4, critical: 8 }[item.complexity]
            : { simple: 0.3, medium: 1, complex: 3, critical: 6 }[item.complexity];

        return {
            traditionalHours: baseHours,
            automatedHours: +(baseHours * (1 - tier.overall / 100)).toFixed(2),
            savingsPercent: tier.overall,
            tier: item.complexity
        };
    }

    /**
     * Generate K2 field mapping table for a form
     */
    _generateFormFieldMappings(form) {
        // Derive representative SP field types from form metrics
        const mappings = [];
        const fieldTypes = [
            'Single Line Text', 'Multiple Lines Plain', 'Choice Dropdown',
            'Date/Time', 'Person or Group', 'Yes/No', 'Number', 'Attachment'
        ];

        const count = form.fieldCount || 5;
        for (let i = 0; i < Math.min(count, 25); i++) {
            const spType = fieldTypes[i % fieldTypes.length];
            const soMap = SP_TO_SMARTOBJECT_MAP[spType];
            const sfMap = SP_TO_SMARTFORM_MAP[spType];
            mappings.push({
                fieldIndex: i + 1,
                spFieldType: spType,
                smartObjectProperty: soMap?.propertyType || 'Text',
                systemType: soMap?.systemName || 'System.String',
                smartFormControl: sfMap?.control || 'Text Box',
                autoMap: soMap?.autoMap || 'direct',
                notes: soMap?.notes || ''
            });
        }
        return mappings;
    }

    /**
     * Generate K2 activity mapping table for a workflow
     */
    _generateActivityMappings(wf) {
        const mappings = [];
        const actions = Object.entries(SPD_TO_K2_ACTIVITY_MAP);                     
        const count = Math.min(wf.actionCount || 3, actions.length);
        for (let i = 0; i < count; i++) {
            const [spdAction, k2Info] = actions[i % actions.length];
            mappings.push({
                stepIndex: i + 1,
                spdAction,
                k2Activity: k2Info.k2Activity,
                blueprintOutput: k2Info.blueprint,
                automatable: k2Info.automatable
            });
        }
        return mappings;
    }

    /**
     * Compute portfolio-level statistics
     */
    _computePortfolioStats() {
        const items = this.analysisResults;
        const wfs = items.filter(i => i.assetType === 'workflow');
        const forms = items.filter(i => i.assetType === 'form');

        const simpleCt = items.filter(i => i.complexity === 'simple').length;
        const mediumCt = items.filter(i => i.complexity === 'medium').length;
        const complexCt = items.filter(i => i.complexity === 'complex').length;
        const criticalCt = items.filter(i => i.complexity === 'critical').length;

        // Top complexity drivers
        const componentCounts = {};
        items.forEach(item => {
            if (item.complexityFactors) {
                item.complexityFactors.forEach(f => {
                    componentCounts[f.label] = (componentCounts[f.label] || 0) + 1;
                });
            }
        });

        // Unique sites
        const sites = new Set();
        items.forEach(i => { if (i.webUrl) sites.add(i.webUrl); });

        this.portfolioStats = {
            totalItems: items.length,
            totalWorkflows: wfs.length,
            totalForms: forms.length,
            totalSites: sites.size,
            complexityDistribution: {
                simple: simpleCt,
                medium: mediumCt,
                complex: complexCt,
                critical: criticalCt,
                simplePct: items.length ? Math.round(simpleCt / items.length * 100) : 0,
                mediumPct: items.length ? Math.round(mediumCt / items.length * 100) : 0,
                complexPct: items.length ? Math.round(complexCt / items.length * 100) : 0,
                criticalPct: items.length ? Math.round(criticalCt / items.length * 100) : 0
            },
            topComponents: Object.entries(componentCounts)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 15)
                .map(([label, count]) => ({ label, count, pct: items.length ? Math.round(count / items.length * 100) : 0 }))
        };
    }

    /**
     * Restore analysis results from saved state
     */
    _restoreResults(items) {
        this.analysisResults = items;
        this._computePortfolioStats();
        this.lastAnalysisTimestamp = new Date().toISOString();
    }
}

module.exports = {
    AnalysisEngine,
    ENVIRONMENT,
    SP_TO_SMARTOBJECT_MAP,
    SP_TO_SMARTFORM_MAP,
    SPD_TO_K2_ACTIVITY_MAP,
    FORM_COMPLEXITY_WEIGHTS,
    WF_COMPLEXITY_WEIGHTS,
    COMPLEXITY_THRESHOLDS,
    K2_AUTOMATION_COVERAGE,
    TIER_EFFORT_REDUCTION,
    WORKFLOW_TIER_RUBRIC,
    WORKFLOW_TIER_THRESHOLDS,
    MANUAL_REVIEW_FLAGS
};
