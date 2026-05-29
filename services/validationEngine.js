// ============================================================
// SPD → K2 Five Migration Pipeline — Validation & Cutover Engine
// Phase 7: Cross-phase validation, readiness checks, packaging
// Phase 8: Cutover readiness dashboard, rollback plan
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// ============================================================

const { v4: uuidv4 } = require('uuid');

// ── Validation Rule Definitions ─────────────────────────────

const VALIDATION_RULES = {
    // Phase 1-2 checks
    'DISC-001': { phase: 1, severity: 'critical', label: 'Discovery data imported',
        check: (ctx) => ctx.inventory && ctx.inventory.totalArtifacts > 0,
        fix: 'Upload workflow and InfoPath CSV files in the Discovery tab' },

    'DISC-002': { phase: 2, severity: 'critical', label: 'Analysis completed',
        check: (ctx) => ctx.analysisResults && ctx.analysisResults.length > 0,
        fix: 'Run analysis from the Discovery tab' },

    'DISC-003': { phase: 2, severity: 'warning', label: 'No critical-complexity workflows',
        check: (ctx) => !ctx.analysisResults?.some(r => r.complexity === 'critical' && r.assetType === 'workflow'),
        fix: 'Critical workflows require extended manual effort — plan additional K2 Designer time' },

    // Phase 3 checks
    'SO-001': { phase: 3, severity: 'critical', label: 'SmartObjects generated',
        check: (ctx) => ctx.smartObjects && ctx.smartObjects.length > 0,
        fix: 'Generate SmartObjects from the SmartObjects tab' },

    'SO-002': { phase: 3, severity: 'warning', label: 'All SmartObjects have properties',
        check: (ctx) => ctx.smartObjects?.every(so => so.propertyCount > 0),
        fix: 'Review SmartObjects with zero properties — may indicate mapping failures' },

    'SO-003': { phase: 3, severity: 'info', label: 'No blocked fields in SmartObjects',
        check: (ctx) => !ctx.smartObjects?.some(so => so.hasBlockedFields),
        fix: 'Blocked fields require custom Service Broker development' },

    // Phase 4 checks
    'SF-001': { phase: 4, severity: 'critical', label: 'SmartForms generated',
        check: (ctx) => ctx.smartForms && ctx.smartForms.length > 0,
        fix: 'Generate SmartForms from the SmartForms tab' },

    'SF-002': { phase: 4, severity: 'warning', label: 'All SmartForms have views',
        check: (ctx) => ctx.smartForms?.every(sf => sf.viewCount >= 3),
        fix: 'Each SmartForm should have at least 3 views (List, Item, Edit)' },

    'SF-003': { phase: 4, severity: 'warning', label: 'No manual config items pending',
        check: (ctx) => !ctx.smartForms?.some(sf => sf.manualConfigCount > 0),
        fix: 'SmartForms with manual config items need K2 Designer attention' },

    // Phase 5 checks
    'BP-001': { phase: 5, severity: 'critical', label: 'Workflow blueprints generated',
        check: (ctx) => ctx.blueprints && ctx.blueprints.length > 0,
        fix: 'Generate blueprints from the Blueprints tab' },

    'BP-002': { phase: 5, severity: 'warning', label: 'All blueprints have defined steps',
        check: (ctx) => ctx.blueprints?.every(bp => bp.stepCount > 0),
        fix: 'Review blueprints with zero steps' },

    'BP-003': { phase: 5, severity: 'info', label: 'All blueprints completed',
        check: (ctx) => ctx.blueprints?.every(bp => bp.status === 'completed'),
        fix: 'Update blueprint status as K2 Designer work is completed' },

    // Cross-phase checks
    'XREF-001': { phase: 7, severity: 'critical', label: 'SmartObjects cover all discovered lists',
        check: (ctx) => {
            if (!ctx.analysisResults || !ctx.smartObjects) return false;
            const formLists = new Set(ctx.analysisResults.filter(r => r.assetType === 'form').map(r => r.listTitle));
            return formLists.size === 0 || ctx.smartObjects.length >= formLists.size;
        },
        fix: 'Ensure every SP list with forms has a corresponding SmartObject' },

    'XREF-002': { phase: 7, severity: 'warning', label: 'SmartForms match SmartObject count',
        check: (ctx) => ctx.smartForms?.length >= ctx.smartObjects?.length,
        fix: 'Each SmartObject should have a corresponding SmartForm' },

    'XREF-003': { phase: 7, severity: 'warning', label: 'Blueprints cover all workflows',
        check: (ctx) => {
            const wfCount = ctx.analysisResults?.filter(r => r.assetType === 'workflow').length || 0;
            return ctx.blueprints?.length >= wfCount;
        },
        fix: 'Every discovered workflow should have a migration blueprint' },

    // Environment checks
    'ENV-001': { phase: 8, severity: 'critical', label: 'K2 server connection configured',
        check: (ctx) => ctx.k2Connection && ctx.k2Connection.config?.serverUrl,
        fix: 'Configure the K2 server URL in the SmartObjects tab' },

    'ENV-002': { phase: 8, severity: 'info', label: 'K2 connection tested successfully',
        check: (ctx) => ctx.k2Connection && ctx.k2Connection.isConnected,
        fix: 'Test the K2 server connection before cutover' }
};

// Cutover checklist
const CUTOVER_CHECKLIST = [
    { id: 'CUT-001', category: 'Pre-Cutover', item: 'SharePoint farm backup completed', critical: true },
    { id: 'CUT-002', category: 'Pre-Cutover', item: 'K2_PROD database backup completed', critical: true },
    { id: 'CUT-003', category: 'Pre-Cutover', item: 'K2 server snapshot/checkpoint created', critical: true },
    { id: 'CUT-004', category: 'Pre-Cutover', item: 'Stakeholder notification sent (maintenance window)', critical: true },
    { id: 'CUT-005', category: 'Pre-Cutover', item: 'Change management ticket approved', critical: true },

    { id: 'CUT-010', category: 'SmartObjects', item: 'Deploy all SmartObjects to K2 production', critical: true },
    { id: 'CUT-011', category: 'SmartObjects', item: 'Verify SmartObject CRUD operations against SP lists', critical: true },
    { id: 'CUT-012', category: 'SmartObjects', item: 'Validate field type mappings (dates, numbers, lookups)', critical: false },

    { id: 'CUT-020', category: 'SmartForms', item: 'Deploy all SmartForms to K2 production', critical: true },
    { id: 'CUT-021', category: 'SmartForms', item: 'Verify List/Item/Edit views load correctly', critical: true },
    { id: 'CUT-022', category: 'SmartForms', item: 'Test form validation rules (required fields, format checks)', critical: false },
    { id: 'CUT-023', category: 'SmartForms', item: 'Configure manual controls (Person Picker, Lookups, Attachments)', critical: true },

    { id: 'CUT-030', category: 'Workflows', item: 'Build all workflow processes in K2 Designer (per blueprints)', critical: true },
    { id: 'CUT-031', category: 'Workflows', item: 'Test each workflow end-to-end in K2 test environment', critical: true },
    { id: 'CUT-032', category: 'Workflows', item: 'Verify email notifications fire correctly', critical: false },
    { id: 'CUT-033', category: 'Workflows', item: 'Test approval/rejection/escalation paths', critical: true },
    { id: 'CUT-034', category: 'Workflows', item: 'Validate decision logic matches original SPD behavior', critical: true },

    { id: 'CUT-040', category: 'Integration', item: 'Verify SP List Service Broker connectivity', critical: true },
    { id: 'CUT-041', category: 'Integration', item: 'Test K2 SSO/authentication with SharePoint', critical: true },
    { id: 'CUT-042', category: 'Integration', item: 'Validate K2 security labels and permissions', critical: true },

    { id: 'CUT-050', category: 'Post-Cutover', item: 'Disable legacy SPD workflows in SharePoint', critical: true },
    { id: 'CUT-051', category: 'Post-Cutover', item: 'Redirect users to K2 SmartForms', critical: true },
    { id: 'CUT-052', category: 'Post-Cutover', item: 'Monitor K2 process instances for 24h', critical: true },
    { id: 'CUT-053', category: 'Post-Cutover', item: 'Confirm rollback plan is ready (keep SPD workflows intact)', critical: true },
    { id: 'CUT-054', category: 'Post-Cutover', item: 'Stakeholder sign-off received', critical: true }
];


class ValidationEngine {

    constructor() {
        this.lastValidation = null;
        this.validationResults = [];
        this.cutoverChecklist = CUTOVER_CHECKLIST.map(item => ({
            ...item,
            checked: false,
            checkedAt: null,
            checkedBy: null
        }));
        this.readinessScore = 0;
    }

    /**
     * Run all validation checks across phases
     * @param {Object} context - References to all phase services
     * @returns {Object} Validation report
     */
    runValidation(context) {
        this.validationResults = [];

        for (const [ruleId, rule] of Object.entries(VALIDATION_RULES)) {
            let passed = false;
            let error = null;

            try {
                passed = rule.check(context);
            } catch (err) {
                passed = false;
                error = err.message;
            }

            this.validationResults.push({
                ruleId,
                phase: rule.phase,
                severity: rule.severity,
                label: rule.label,
                passed,
                fix: passed ? null : rule.fix,
                error
            });
        }

        // Calculate readiness score
        const total = this.validationResults.length;
        const passedCount = this.validationResults.filter(r => r.passed).length;
        const criticalFailed = this.validationResults.filter(r => !r.passed && r.severity === 'critical').length;

        this.readinessScore = criticalFailed > 0
            ? Math.min(49, Math.round((passedCount / total) * 100))
            : Math.round((passedCount / total) * 100);

        this.lastValidation = new Date().toISOString();

        return this.getReport();
    }

    /**
     * Get validation report
     */
    getReport() {
        const byPhase = {};
        for (const result of this.validationResults) {
            const phase = `Phase ${result.phase}`;
            if (!byPhase[phase]) byPhase[phase] = [];
            byPhase[phase].push(result);
        }

        const bySeverity = {
            critical: this.validationResults.filter(r => r.severity === 'critical'),
            warning: this.validationResults.filter(r => r.severity === 'warning'),
            info: this.validationResults.filter(r => r.severity === 'info')
        };

        return {
            timestamp: this.lastValidation,
            readinessScore: this.readinessScore,
            readinessLevel: this.readinessScore >= 90 ? 'ready' :
                           this.readinessScore >= 70 ? 'partial' :
                           this.readinessScore >= 50 ? 'at-risk' : 'blocked',
            total: this.validationResults.length,
            passed: this.validationResults.filter(r => r.passed).length,
            failed: this.validationResults.filter(r => !r.passed).length,
            criticalBlocking: bySeverity.critical.filter(r => !r.passed).length,
            results: this.validationResults,
            byPhase,
            bySeverity
        };
    }

    /**
     * Get cutover checklist
     */
    getCutoverChecklist() {
        const categories = {};
        for (const item of this.cutoverChecklist) {
            if (!categories[item.category]) categories[item.category] = [];
            categories[item.category].push(item);
        }

        const totalChecked = this.cutoverChecklist.filter(c => c.checked).length;
        const criticalTotal = this.cutoverChecklist.filter(c => c.critical).length;
        const criticalChecked = this.cutoverChecklist.filter(c => c.critical && c.checked).length;

        return {
            items: this.cutoverChecklist,
            categories,
            stats: {
                total: this.cutoverChecklist.length,
                checked: totalChecked,
                remaining: this.cutoverChecklist.length - totalChecked,
                criticalTotal,
                criticalChecked,
                criticalRemaining: criticalTotal - criticalChecked,
                completionPct: Math.round((totalChecked / this.cutoverChecklist.length) * 100),
                goNoGo: criticalChecked === criticalTotal ? 'GO' : 'NO-GO'
            }
        };
    }

    /**
     * Toggle cutover checklist item
     */
    toggleChecklistItem(id, checked, checkedBy = 'Migration Engineer') {
        const item = this.cutoverChecklist.find(c => c.id === id);
        if (!item) return false;
        item.checked = checked;
        item.checkedAt = checked ? new Date().toISOString() : null;
        item.checkedBy = checked ? checkedBy : null;
        return true;
    }

    /**
     * Generate rollback plan
     */
    getRollbackPlan() {
        return {
            title: 'K2 Five Migration Rollback Plan',
            lastUpdated: new Date().toISOString(),
            triggerConditions: [
                'Critical SmartObject CRUD operations failing against SharePoint lists',
                'K2 workflows not triggering or hanging in error state',
                'SmartForm views rendering incorrectly or losing data',
                'Authentication/SSO failures between K2 and SharePoint',
                'Performance degradation exceeding 200% of baseline response times'
            ],
            steps: [
                {
                    order: 1,
                    action: 'STOP — Halt all new K2 process instances',
                    detail: 'K2 Management Console → Server → Stop all running process instances',
                    estimatedMinutes: 5
                },
                {
                    order: 2,
                    action: 'VERIFY — Confirm SharePoint data integrity',
                    detail: 'Since data lives in SharePoint lists (not K2 SQL), verify list data is unchanged. No data loss should occur because K2 reads/writes directly to SP.',
                    estimatedMinutes: 15
                },
                {
                    order: 3,
                    action: 'RE-ENABLE — Reactivate legacy SPD workflows',
                    detail: 'SharePoint Central Admin → Site Features → Re-enable SPD workflow associations on affected lists. SPD workflows were preserved (not deleted) during migration.',
                    estimatedMinutes: 30
                },
                {
                    order: 4,
                    action: 'REDIRECT — Point users back to SharePoint forms',
                    detail: 'Update any URL redirects or bookmarks pointing to K2 SmartForms. Revert navigation links in SharePoint sites.',
                    estimatedMinutes: 15
                },
                {
                    order: 5,
                    action: 'CLEANUP — Remove K2 artifacts (optional)',
                    detail: 'K2 Management Console → Delete deployed SmartObjects, SmartForms, and Workflow definitions. This is optional — K2 artifacts can remain dormant.',
                    estimatedMinutes: 30
                },
                {
                    order: 6,
                    action: 'COMMUNICATE — Notify stakeholders',
                    detail: 'Send rollback notification with root cause summary and revised timeline.',
                    estimatedMinutes: 10
                }
            ],
            dataProtection: {
                title: 'Data Protection Assurance',
                points: [
                    'SharePoint list data is NEVER modified by the migration pipeline — it only reads metadata',
                    'K2 SmartObjects use SharePoint List Service Broker (read/write to SP, no separate copy)',
                    'Legacy SPD workflows are DISABLED, not DELETED — can be re-enabled instantly',
                    'K2_PROD database contains only K2 configuration, not business data',
                    'Full rollback estimated time: ~1.5 hours'
                ]
            },
            totalEstimatedMinutes: 105
        };
    }

    /**
     * Get migration summary for exec reporting
     */
    getMigrationSummary(context) {
        return {
            timestamp: new Date().toISOString(),
            environment: {
                source: 'SharePoint SE 16.0.19725.20076',
                target: 'K2 Five 5.8 FP26 (5.0009.1026.0)',
                integration: 'K2 on SharePoint Server (SP List Service Broker)',
                database: 'K2_PROD via 75387P_LN01 (AG: 75387P-AG01)'
            },
            phases: {
                discovery: { status: context.inventory ? 'complete' : 'pending', artifacts: context.inventory?.totalArtifacts || 0 },
                analysis: { status: context.analysisResults?.length > 0 ? 'complete' : 'pending', analyzed: context.analysisResults?.length || 0 },
                smartObjects: { status: context.smartObjects?.length > 0 ? 'complete' : 'pending', generated: context.smartObjects?.length || 0 },
                smartForms: { status: context.smartForms?.length > 0 ? 'complete' : 'pending', generated: context.smartForms?.length || 0 },
                blueprints: { status: context.blueprints?.length > 0 ? 'complete' : 'pending', generated: context.blueprints?.length || 0 },
                dataMigration: { status: 'skipped', reason: 'K2 uses SP List Service Broker — data stays in SharePoint' },
                validation: { status: this.lastValidation ? 'complete' : 'pending', readinessScore: this.readinessScore },
                cutover: { status: this.getCutoverChecklist().stats.goNoGo === 'GO' ? 'ready' : 'pending' }
            },
            readiness: {
                score: this.readinessScore,
                level: this.readinessScore >= 90 ? 'READY' : this.readinessScore >= 70 ? 'PARTIAL' : 'BLOCKED',
                goNoGo: this.getCutoverChecklist().stats.goNoGo
            }
        };
    }
}

module.exports = { ValidationEngine };
