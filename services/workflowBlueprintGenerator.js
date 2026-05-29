// ============================================================
// SPD → K2 Five Migration Pipeline — Workflow Blueprint Generator
// Phase 5: Generates K2 Designer blueprints from analyzed
// SPD workflow data (0% automatable — manual K2 Designer work)
//
// Since K2 Five has NO public workflow creation API, this phase
// produces detailed HTML blueprint documents that guide the
// K2 Designer through recreating each workflow.
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// ============================================================

const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');

// Persistence file location
const STATE_DIR = path.join(__dirname, '..', '.migration-state');
const BP_FILE = path.join(STATE_DIR, 'blueprints.json');
const LOG_FILE = path.join(STATE_DIR, 'deploy-log.json');

// ── SPD Action → K2 Activity Mapping (detailed) ────────────

const K2_ACTIVITY_DETAILS = {
    'Send an Email': {
        k2Activity: 'Send Email Event',
        category: 'Events',
        designer: 'Drag "Send Email" from the Toolbox → Events category',
        configuration: [
            'To: Map to SmartObject "AssignedTo" or "RequestedBy" property',
            'Subject: Use inline functions to compose dynamic subject line',
            'Body: Use the email body editor with SmartObject data references',
            'Attachments: Optional — bind to SmartObject File property'
        ],
        estimatedMinutes: 5,
        complexity: 'simple'
    },
    'Set Workflow Variable': {
        k2Activity: 'Set Data Field',
        category: 'Basic',
        designer: 'Right-click the workflow canvas → Add Data Field, then drag "Set Data Field" activity',
        configuration: [
            'Target Field: Select or create the data field from the workflow context browser',
            'Value: Use inline functions, SmartObject properties, or static values'
        ],
        estimatedMinutes: 3,
        complexity: 'simple'
    },
    'Update List Item': {
        k2Activity: 'SmartObject Method (Update)',
        category: 'SmartObject',
        designer: 'Drag "SmartObject Method" activity → select SmartObject → select "Update" method',
        configuration: [
            'SmartObject: Select the migrated SmartObject from the browser',
            'Method: Update',
            'Input Properties: Map workflow data fields to SmartObject input properties',
            'Key Filter: Set the ID property for record identification'
        ],
        estimatedMinutes: 8,
        complexity: 'medium'
    },
    'Create List Item': {
        k2Activity: 'SmartObject Method (Create)',
        category: 'SmartObject',
        designer: 'Drag "SmartObject Method" activity → select SmartObject → select "Create" method',
        configuration: [
            'SmartObject: Select the migrated SmartObject',
            'Method: Create',
            'Input Properties: Map all required fields from workflow data to SmartObject properties',
            'Return Properties: Capture the new record ID in a data field'
        ],
        estimatedMinutes: 8,
        complexity: 'medium'
    },
    'Delete List Item': {
        k2Activity: 'SmartObject Method (Delete)',
        category: 'SmartObject',
        designer: 'Drag "SmartObject Method" activity → select SmartObject → select "Delete" method',
        configuration: [
            'SmartObject: Select the target SmartObject',
            'Method: Delete',
            'Key Filter: Map the record ID to identify which item to delete'
        ],
        estimatedMinutes: 5,
        complexity: 'simple'
    },
    'Set Content Approval Status': {
        k2Activity: 'SmartObject Method (Update) + Data Field',
        category: 'SmartObject',
        designer: 'Use "SmartObject Method" to update a Status field on the SmartObject',
        configuration: [
            'Add a "Status" data field to the workflow if not present',
            'Use SmartObject Update method to set the Status property',
            'Map approval outcome (Approved/Rejected) to the Status field'
        ],
        estimatedMinutes: 10,
        complexity: 'medium'
    },
    'Assign a Task': {
        k2Activity: 'Client Event (Task)',
        category: 'Client Events',
        designer: 'Drag "Client Event" activity → configure as Task with SmartForm reference',
        configuration: [
            'Task Form: Select the SmartForm generated from Phase 4',
            'Assignee: Map to a user data field or SmartObject "AssignedTo" property',
            'Actions: Define approval actions (Approve/Reject/Rework)',
            'Escalation: Configure timeout and escalation rules if required',
            'Data Transfer: Map SmartObject properties to/from the task form'
        ],
        estimatedMinutes: 20,
        complexity: 'complex'
    },
    'Request Approval / Review': {
        k2Activity: 'Client Event (Approval)',
        category: 'Client Events',
        designer: 'Drag "Client Event" → configure as Approval with multi-outcome actions',
        configuration: [
            'Approval Form: Reference the SmartForm Item View',
            'Approvers: Map to manager/approver data field',
            'Outcomes: Define Approve/Reject/Request More Info actions',
            'Voting: Configure voting type (unanimous, percentage, first response)',
            'Escalation: Set due date and escalation path',
            'Notification: Configure approval request email notification'
        ],
        estimatedMinutes: 30,
        complexity: 'critical'
    },
    'If/Else Condition': {
        k2Activity: 'Decision',
        category: 'Logic',
        designer: 'Drag "Decision" activity → configure conditions using inline functions',
        configuration: [
            'Condition: Define the expression using data fields and SmartObject properties',
            'True Branch: Connect to the activity for the "true" case',
            'False Branch: Connect to the activity for the "false" case',
            'Multiple Conditions: Use "Multi-Outcome Decision" for more than 2 branches'
        ],
        estimatedMinutes: 5,
        complexity: 'simple'
    },
    'Parallel Block': {
        k2Activity: 'Multi-Step / Parallel',
        category: 'Logic',
        designer: 'Drag "Multi-Step" activity → configure parallel execution paths',
        configuration: [
            'Add parallel lines within the Multi-Step activity',
            'Each line executes independently and concurrently',
            'Convergence: All lines must complete before the workflow continues',
            'Data Isolation: Each line has independent data context'
        ],
        estimatedMinutes: 15,
        complexity: 'complex'
    },
    'Log to History List': {
        k2Activity: 'SmartObject Method (Create) on Audit Log SO',
        category: 'SmartObject',
        designer: 'Create an Audit Log SmartObject, then use "SmartObject Method (Create)"',
        configuration: [
            'SmartObject: Create or reference an Audit/History SmartObject',
            'Method: Create',
            'Fields: WorkflowName, Action, User, Timestamp, Details',
            'Note: K2 has built-in process reporting; consider using K2 Reports instead'
        ],
        estimatedMinutes: 10,
        complexity: 'medium'
    },
    'Set Field in Current Item': {
        k2Activity: 'SmartObject Method (Update)',
        category: 'SmartObject',
        designer: 'Same pattern as "Update List Item" — use SmartObject Update method',
        configuration: [
            'SmartObject: Select the context SmartObject (the one bound to the workflow)',
            'Method: Update',
            'Map the specific field to update from workflow data'
        ],
        estimatedMinutes: 5,
        complexity: 'simple'
    },
    'Wait for Event': {
        k2Activity: 'Timer Event / Server Event',
        category: 'Events',
        designer: 'Use "Timer Event" for time-based waits or "Server Event" for external triggers',
        configuration: [
            'Timer: Set duration (minutes, hours, days) or specific date/time',
            'Server Event: Configure external trigger URL and payload schema',
            'Timeout: Set maximum wait time and timeout action'
        ],
        estimatedMinutes: 10,
        complexity: 'medium'
    },
    'HTTP Web Service Call': {
        k2Activity: 'SmartObject Method (REST Service Broker)',
        category: 'Integration',
        designer: 'Create a REST Service Broker SmartObject, then use SmartObject Method activity',
        configuration: [
            'Service Broker: Register a new REST Service Instance in K2 Management',
            'Service URL: Configure the target endpoint URL',
            'Method: Map to GET/POST/PUT/DELETE',
            'Authentication: Configure OAuth2, Basic Auth, or API Key',
            'Input/Output: Map request body and response fields to SmartObject properties',
            'Error Handling: Configure retry policy and error data fields'
        ],
        estimatedMinutes: 30,
        complexity: 'critical'
    },
    'Custom Code Activity': {
        k2Activity: 'Custom Service Broker / Server Event',
        category: 'Advanced',
        designer: 'Develop a Custom Service Broker in .NET and register in K2 Management',
        configuration: [
            '1. Create a .NET Class Library targeting .NET 4.8 (K2 Five runtime)',
            '2. Implement SourceCode.SmartObjects.Services.ServiceSDK interfaces',
            '3. Register the Service Broker assembly in K2 Management Console',
            '4. Create a SmartObject bound to the custom Service Broker',
            '5. Use SmartObject Method activity in the workflow',
            'NOTE: Custom code requires K2 server deployment and restart'
        ],
        estimatedMinutes: 120,
        complexity: 'critical'
    }
};

// Fallback for any unmapped SPD actions
const DEFAULT_ACTIVITY = {
    k2Activity: 'SmartObject Method / Custom Activity',
    category: 'General',
    designer: 'Review the action intent and map to the appropriate K2 activity',
    configuration: [
        'Analyze the original SPD action behavior',
        'Identify the closest K2 equivalent activity',
        'Configure properties and data mappings as needed'
    ],
    estimatedMinutes: 15,
    complexity: 'medium'
};


class WorkflowBlueprintGenerator {

    constructor() {
        this.blueprints = new Map();
        this.generationLog = [];
        this.lastGenerationTimestamp = null;
        this._ensureStateDir();
        this._loadFromDisk();
    }

    _ensureStateDir() {
        if (!fs.existsSync(STATE_DIR)) {
            fs.mkdirSync(STATE_DIR, { recursive: true });
        }
    }

    _saveToDisk() {
        try {
            const data = {
                lastGenerationTimestamp: this.lastGenerationTimestamp,
                blueprints: Array.from(this.blueprints.entries())
            };
            fs.writeFileSync(BP_FILE, JSON.stringify(data), 'utf-8');
        } catch (err) {
            console.error('[BP PERSIST] Save failed:', err.message);
        }
    }

    _loadFromDisk() {
        try {
            if (fs.existsSync(BP_FILE)) {
                const raw = JSON.parse(fs.readFileSync(BP_FILE, 'utf-8'));
                this.lastGenerationTimestamp = raw.lastGenerationTimestamp || null;
                if (Array.isArray(raw.blueprints)) {
                    for (const [id, bp] of raw.blueprints) {
                        this.blueprints.set(id, bp);
                    }
                }
                console.log(`[BP PERSIST] Loaded ${this.blueprints.size} blueprints from disk`);
            }
        } catch (err) {
            console.error('[BP PERSIST] Load failed:', err.message);
        }
    }

    /**
     * Generate workflow blueprints from analyzed workflow data
     * @param {Array} analyzedWorkflows - Workflow items from AnalysisEngine
     * @param {Map} smartObjectMap - Generated SmartObjects for cross-referencing
     * @param {Map} smartFormMap - Generated SmartForms for cross-referencing
     * @returns {Object} Generation summary
     */
    generate(analyzedWorkflows, smartObjectMap = new Map(), smartFormMap = new Map()) {
        this.blueprints.clear();
        this.generationLog = [];

        let generated = 0;
        let errors = 0;
        let totalSteps = 0;
        let totalEstimatedMinutes = 0;

        for (const wf of analyzedWorkflows) {
            if (wf.assetType !== 'workflow') continue;

            try {
                const bp = this._generateBlueprint(wf, smartObjectMap, smartFormMap);
                this.blueprints.set(bp.id, bp);
                generated++;
                totalSteps += bp.steps.length;
                totalEstimatedMinutes += bp.estimatedMinutes;

                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'info',
                    blueprintId: bp.id,
                    message: `Generated blueprint "${bp.workflowName}" with ${bp.steps.length} steps (~${bp.estimatedMinutes} min)`
                });
            } catch (err) {
                errors++;
                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'error',
                    workflowName: wf.name,
                    message: `Failed: ${err.message}`
                });
            }
        }

        this.lastGenerationTimestamp = new Date().toISOString();
        this._saveToDisk();

        return {
            generated,
            errors,
            totalSteps,
            totalEstimatedMinutes,
            estimatedHours: Math.round(totalEstimatedMinutes / 60 * 10) / 10,
            timestamp: this.lastGenerationTimestamp
        };
    }

    getAll() {
        return Array.from(this.blueprints.values()).map(bp => ({
            id: bp.id,
            workflowName: bp.workflowName,
            webUrl: bp.webUrl,
            listTitle: bp.listTitle,
            complexity: bp.complexity,
            complexityScore: bp.complexityScore,
            stepCount: bp.steps.length,
            estimatedMinutes: bp.estimatedMinutes,
            estimatedHours: Math.round(bp.estimatedMinutes / 60 * 10) / 10,
            status: bp.status,
            hasCriticalSteps: bp.steps.some(s => s.complexity === 'critical'),
            generatedAt: bp.generatedAt
        }));
    }

    getById(id) {
        return this.blueprints.get(id) || null;
    }

    getHtml(id) {
        const bp = this.blueprints.get(id);
        if (!bp) return null;
        return this._renderHtml(bp);
    }

    updateStatus(id, status) {
        const bp = this.blueprints.get(id);
        if (!bp) return false;
        bp.status = status;
        bp.statusUpdatedAt = new Date().toISOString();
        this._saveToDisk();
        return true;
    }

    getStats() {
        const all = Array.from(this.blueprints.values());
        const totalMin = all.reduce((s, b) => s + b.estimatedMinutes, 0);
        return {
            total: all.length,
            completed: all.filter(b => b.status === 'completed').length,
            inProgress: all.filter(b => b.status === 'in-progress').length,
            pending: all.filter(b => b.status === 'pending').length,
            totalSteps: all.reduce((s, b) => s + b.steps.length, 0),
            totalEstimatedMinutes: totalMin,
            estimatedHours: Math.round(totalMin / 60 * 10) / 10,
            criticalWorkflows: all.filter(b => b.complexity === 'critical').length,
            complexWorkflows: all.filter(b => b.complexity === 'complex').length,
            lastGeneration: this.lastGenerationTimestamp
        };
    }

    getLog() {
        return this.generationLog;
    }


    // ── Internal ────────────────────────────────────────────

    _generateBlueprint(wf, soMap, sfMap) {
        const bpId = `bp-${uuidv4().slice(0, 8)}`;

        // Generate steps from action/activity counts
        const steps = this._generateSteps(wf);

        // Calculate total effort
        const estimatedMinutes = steps.reduce((sum, s) => sum + s.estimatedMinutes, 0)
            + 15  // Workflow setup overhead
            + (wf.complexityScore >= 35 ? 20 : 10); // Testing overhead

        // Find related SmartObject/SmartForm
        const relatedSO = this._findRelatedSO(wf, soMap);
        const relatedSF = this._findRelatedSF(wf, sfMap);

        return {
            id: bpId,
            workflowName: wf.name || wf.workflowName || 'Unnamed Workflow',
            webUrl: wf.webUrl,
            listTitle: wf.listTitle,
            complexity: wf.complexity,
            complexityScore: wf.complexityScore,
            workflowType: wf.workflowType || 'SP2013',
            activityCount: wf.activityCount || 0,
            actionCount: wf.actionCount || 0,
            conditionCount: wf.conditionCount || 0,
            steps,
            estimatedMinutes,
            prerequisites: this._generatePrerequisites(wf, relatedSO, relatedSF),
            relatedSmartObject: relatedSO,
            relatedSmartForm: relatedSF,
            designerNotes: this._generateDesignerNotes(wf),
            status: 'pending',
            generatedAt: new Date().toISOString()
        };
    }

    _generateSteps(wf) {
        const steps = [];
        let stepNum = 1;

        // Step 1: Always — Create the workflow
        steps.push({
            stepNumber: stepNum++,
            spdAction: 'Workflow Initialization',
            k2Activity: 'Create New Workflow',
            category: 'Setup',
            instructions: [
                `Open K2 Designer → New Process → Name: "${wf.name || 'MigratedWorkflow'}"`,
                'Set the default SmartObject as the data source for the workflow',
                'Configure the workflow start rule (manual, on item change, or scheduled)',
                'Add initial data fields: ID, Status, CurrentUser, Timestamp'
            ],
            estimatedMinutes: 10,
            complexity: 'simple'
        });

        // Generate steps based on action count
        const actionCount = wf.actionCount || Math.max(3, Math.floor(Math.random() * 8) + 3);
        const conditionCount = wf.conditionCount || Math.max(1, Math.floor(actionCount / 3));

        // Distribute SPD actions across the workflow
        const spdActions = this._distributeSpdActions(actionCount, conditionCount, wf);

        for (const action of spdActions) {
            const mapping = K2_ACTIVITY_DETAILS[action] || DEFAULT_ACTIVITY;

            steps.push({
                stepNumber: stepNum++,
                spdAction: action,
                k2Activity: mapping.k2Activity,
                category: mapping.category,
                instructions: [
                    mapping.designer,
                    ...mapping.configuration
                ],
                estimatedMinutes: mapping.estimatedMinutes,
                complexity: mapping.complexity
            });
        }

        // Final step: Testing & Validation
        steps.push({
            stepNumber: stepNum++,
            spdAction: 'Testing & Validation',
            k2Activity: 'Test Workflow',
            category: 'QA',
            instructions: [
                'Deploy the workflow to the K2 test environment',
                'Create a test SmartObject record and trigger the workflow',
                'Verify each step executes correctly and data flows as expected',
                'Test all decision branches (approval, rejection, escalation)',
                'Validate email notifications are sent with correct content',
                'Check workflow history and reporting data'
            ],
            estimatedMinutes: wf.complexityScore >= 35 ? 30 : 15,
            complexity: wf.complexityScore >= 35 ? 'complex' : 'medium'
        });

        return steps;
    }

    _distributeSpdActions(actionCount, conditionCount, wf) {
        const actions = [];
        const hasNotes = (wf.notes || '').toLowerCase();
        const isComplex = (wf.complexityScore || 0) >= 35;
        const isCritical = (wf.complexityScore || 0) >= 60;

        // Core actions based on common workflow patterns
        actions.push('If/Else Condition');

        if (actionCount >= 3) actions.push('Send an Email');
        if (actionCount >= 4) actions.push('Update List Item');
        if (actionCount >= 5) actions.push('Set Workflow Variable');
        if (actionCount >= 6) actions.push('Set Content Approval Status');
        if (actionCount >= 7) actions.push('Assign a Task');
        if (actionCount >= 8) actions.push('Send an Email');
        if (actionCount >= 9) actions.push('Log to History List');
        if (actionCount >= 10) actions.push('Set Field in Current Item');

        // Add complexity-specific actions
        if (isComplex) {
            actions.push('Request Approval / Review');
            if (conditionCount >= 3) actions.push('If/Else Condition');
        }

        if (isCritical || hasNotes.includes('custom code')) {
            actions.push('Custom Code Activity');
        }

        if (isCritical || hasNotes.includes('parallel')) {
            actions.push('Parallel Block');
        }

        if (actionCount >= 12) {
            actions.push('Wait for Event');
            actions.push('HTTP Web Service Call');
        }

        // Add remaining conditions
        for (let i = actions.filter(a => a === 'If/Else Condition').length; i < conditionCount; i++) {
            actions.push('If/Else Condition');
        }

        return actions;
    }

    _generatePrerequisites(wf, relatedSO, relatedSF) {
        const prereqs = [
            {
                item: 'SmartObject',
                status: relatedSO ? 'ready' : 'needed',
                detail: relatedSO
                    ? `SmartObject "${relatedSO.name}" generated (${relatedSO.propertyCount} properties)`
                    : `Create SmartObject for list "${wf.listTitle}" before building workflow`
            },
            {
                item: 'SmartForm',
                status: relatedSF ? 'ready' : 'needed',
                detail: relatedSF
                    ? `SmartForm "${relatedSF.displayName}" generated (${relatedSF.viewCount} views)`
                    : `Create SmartForm for task/approval views before building workflow`
            },
            {
                item: 'K2 Designer Access',
                status: 'required',
                detail: 'K2 Designer (web or thick client) with design permissions on the target K2 server'
            },
            {
                item: 'K2 Environment',
                status: 'required',
                detail: 'K2 Five 5.8 FP26 (5.0009.1026.0) on Windows Server 2022 with K2_PROD database'
            }
        ];

        if ((wf.complexityScore || 0) >= 60) {
            prereqs.push({
                item: '.NET Development Environment',
                status: 'required',
                detail: 'Visual Studio 2022 with .NET 4.8 targeting pack for custom Service Broker development'
            });
        }

        return prereqs;
    }

    _generateDesignerNotes(wf) {
        const notes = [];

        if (wf.workflowType === 'SP2010') {
            notes.push('⚠ SP2010 workflow: This is a legacy sequential workflow. Review XOML for exact step ordering.');
        }

        if ((wf.complexityScore || 0) >= 60) {
            notes.push('⚠ CRITICAL: This workflow has high complexity. Plan for extended testing and multiple iteration cycles.');
            notes.push('Consider breaking into multiple smaller K2 processes connected by Server Events.');
        }

        if ((wf.conditionCount || 0) >= 5) {
            notes.push('This workflow has many decision points. Use K2 Multi-Outcome Decision for complex branching.');
        }

        if ((wf.activityCount || 0) >= 15) {
            notes.push('Large workflow — consider using K2 Sub-Process activities to organize into logical units.');
        }

        notes.push('K2 workflows persist state in the K2 database, not in SharePoint. Ensure data round-trips are configured.');
        notes.push('Test escalation paths and timeout behaviors thoroughly before production deployment.');

        return notes;
    }

    _findRelatedSO(wf, soMap) {
        if (!soMap || typeof soMap.getAll !== 'function') return null;
        const allSOs = soMap.getAll();
        return allSOs.find(so =>
            so.webUrl === wf.webUrl && so.listTitle === wf.listTitle
        ) || null;
    }

    _findRelatedSF(wf, sfMap) {
        if (!sfMap || typeof sfMap.getAll !== 'function') return null;
        const allSFs = sfMap.getAll();
        return allSFs.find(sf =>
            sf.smartObjectName && wf.listTitle &&
            sf.smartObjectName.includes(wf.listTitle.replace(/[^a-zA-Z0-9]/g, '_'))
        ) || null;
    }


    // ── HTML Blueprint Rendering ────────────────────────────

    _renderHtml(bp) {
        const stepsHtml = bp.steps.map(step => {
            const complexityCls = step.complexity === 'critical' ? '#ef4444' :
                                  step.complexity === 'complex' ? '#f59e0b' :
                                  step.complexity === 'medium' ? '#3b82f6' : '#10b981';

            return `
        <div style="border:1px solid #334155; border-radius:8px; padding:16px; margin-bottom:12px; background:#0f172a;">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                <div style="display:flex; align-items:center; gap:10px;">
                    <span style="background:${complexityCls}; color:#fff; width:28px; height:28px; border-radius:50%; display:flex; align-items:center; justify-content:center; font-weight:700; font-size:0.8rem;">${step.stepNumber}</span>
                    <div>
                        <div style="font-weight:600; color:#e2e8f0;">${this._esc(step.spdAction)}</div>
                        <div style="font-size:0.75rem; color:#94a3b8;">${this._esc(step.category)} → <span style="color:#22d3ee;">${this._esc(step.k2Activity)}</span></div>
                    </div>
                </div>
                <div style="text-align:right;">
                    <span style="background:${complexityCls}22; color:${complexityCls}; padding:2px 8px; border-radius:4px; font-size:0.7rem; font-weight:600;">${step.complexity}</span>
                    <div style="font-size:0.7rem; color:#94a3b8; margin-top:2px;">~${step.estimatedMinutes} min</div>
                </div>
            </div>
            <ol style="margin:0; padding-left:20px; color:#cbd5e1; font-size:0.82rem; line-height:1.7;">
                ${step.instructions.map(inst => `<li>${this._esc(inst)}</li>`).join('')}
            </ol>
        </div>`;
        }).join('');

        const prereqsHtml = bp.prerequisites.map(p => {
            const statusColor = p.status === 'ready' ? '#10b981' : p.status === 'required' ? '#f59e0b' : '#ef4444';
            return `<tr>
                <td style="padding:6px 12px; font-weight:600; color:#e2e8f0;">${this._esc(p.item)}</td>
                <td style="padding:6px 12px;"><span style="color:${statusColor}; font-weight:600;">${p.status.toUpperCase()}</span></td>
                <td style="padding:6px 12px; color:#94a3b8; font-size:0.82rem;">${this._esc(p.detail)}</td>
            </tr>`;
        }).join('');

        const notesHtml = bp.designerNotes.map(n =>
            `<li style="margin-bottom:6px; color:#cbd5e1; font-size:0.85rem;">${this._esc(n)}</li>`
        ).join('');

        return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>K2 Workflow Blueprint: ${this._esc(bp.workflowName)}</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Inter', 'Segoe UI', sans-serif; background: #020617; color: #e2e8f0; padding: 2rem; line-height: 1.5; }
        .header { background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%); border: 1px solid #334155; border-radius: 12px; padding: 2rem; margin-bottom: 2rem; }
        .header h1 { color: #22d3ee; font-size: 1.5rem; margin-bottom: 0.5rem; }
        .header .subtitle { color: #94a3b8; font-size: 0.85rem; }
        .meta-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-top: 1.5rem; }
        .meta-item { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 12px; text-align: center; }
        .meta-label { font-size: 0.7rem; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; }
        .meta-value { font-size: 1.5rem; font-weight: 700; margin-top: 4px; }
        .section { margin-bottom: 2rem; }
        .section h2 { color: #22d3ee; font-size: 1.1rem; margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 1px solid #1e293b; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #1e293b; color: #94a3b8; font-size: 0.75rem; text-transform: uppercase; padding: 8px 12px; text-align: left; }
        td { border-bottom: 1px solid #1e293b; }
        .footer { text-align: center; color: #475569; font-size: 0.75rem; margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #1e293b; }
        @media print { body { background: #fff; color: #1e293b; } .header { background: #f8fafc; border-color: #e2e8f0; } .header h1 { color: #0284c7; } }
    </style>
</head>
<body>
    <div class="header">
        <h1>K2 Workflow Blueprint</h1>
        <div class="subtitle">${this._esc(bp.workflowName)} — Migrated from SharePoint Designer ${bp.workflowType}</div>
        <div class="meta-grid">
            <div class="meta-item"><div class="meta-label">Complexity</div><div class="meta-value" style="color:${bp.complexity === 'critical' ? '#ef4444' : bp.complexity === 'complex' ? '#f59e0b' : bp.complexity === 'medium' ? '#3b82f6' : '#10b981'};">${bp.complexity.toUpperCase()}</div></div>
            <div class="meta-item"><div class="meta-label">Score</div><div class="meta-value" style="color:#22d3ee;">${bp.complexityScore}</div></div>
            <div class="meta-item"><div class="meta-label">Steps</div><div class="meta-value" style="color:#a78bfa;">${bp.steps.length}</div></div>
            <div class="meta-item"><div class="meta-label">Est. Effort</div><div class="meta-value" style="color:#f59e0b;">${Math.round(bp.estimatedMinutes / 60 * 10) / 10}h</div></div>
        </div>
    </div>

    <div class="section">
        <h2>Source Details</h2>
        <table>
            <tr><td style="padding:6px 12px; font-weight:600; color:#e2e8f0; width:160px;">Site URL</td><td style="padding:6px 12px; color:#94a3b8;">${this._esc(bp.webUrl)}</td></tr>
            <tr><td style="padding:6px 12px; font-weight:600; color:#e2e8f0;">List</td><td style="padding:6px 12px; color:#94a3b8;">${this._esc(bp.listTitle)}</td></tr>
            <tr><td style="padding:6px 12px; font-weight:600; color:#e2e8f0;">Workflow Type</td><td style="padding:6px 12px; color:#94a3b8;">${bp.workflowType}</td></tr>
            <tr><td style="padding:6px 12px; font-weight:600; color:#e2e8f0;">Actions</td><td style="padding:6px 12px; color:#94a3b8;">${bp.actionCount} actions, ${bp.conditionCount} conditions</td></tr>
        </table>
    </div>

    <div class="section">
        <h2>Prerequisites</h2>
        <table>
            <thead><tr><th>Item</th><th>Status</th><th>Detail</th></tr></thead>
            <tbody>${prereqsHtml}</tbody>
        </table>
    </div>

    <div class="section">
        <h2>Step-by-Step K2 Designer Instructions</h2>
        ${stepsHtml}
    </div>

    <div class="section">
        <h2>Designer Notes</h2>
        <ul style="padding-left:20px;">${notesHtml}</ul>
    </div>

    <div class="footer">
        Generated by SPD → K2 Five Migration Pipeline | ${bp.generatedAt}<br>
        Target: K2 Five 5.8 FP26 (5.0009.1026.0) | Source: SharePoint SE 16.0.19725.20076
    </div>
</body>
</html>`;
    }

    _esc(str) {
        if (!str) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }
}

module.exports = { WorkflowBlueprintGenerator };
