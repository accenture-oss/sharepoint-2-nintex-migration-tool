// ============================================================
// SPD → K2 Five Migration Pipeline — KPRX Workflow Emitter
// Generates K2 Process XML (.kprx) from workflow blueprint data
//
// Ported from colleague's Python emitter (kprx.py) to Node.js.
// Produces valid K2 process XML that can be assembled into a
// deployable .kspx package.
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// ============================================================

const crypto = require('crypto');

// ── K2 Event Type Mapping ──────────────────────────────────
// Maps workflow IR kind → K2 process-XML element name
const K2_EVENT_TYPE = {
    'start':                'StartEvent',
    'end':                  'EndEvent',
    'createTask':           'ClientEvent',
    'assignTask':           'ClientEvent',
    'completeTask':         'ClientEvent',
    'sendEmail':            'ServerEvent',
    'logToHistoryList':     'ServerEvent',
    'updateListItem':       'ServerEvent',
    'createListItem':       'ServerEvent',
    'deleteListItem':       'ServerEvent',
    'lookupListItem':       'ServerEvent',
    'callWebService':       'IPCEvent',
    'callWorkflow':         'IPCEvent',
    'setVariable':          'ServerEvent',
    'delay':                'DelayEvent',
    'ifElse':               'Decision',
    'parallel':             'Parallel',
    'sequence':             'Sequence',
    'stage':                'Stage',
    'transition':           'Transition',
    'approval':             'ClientEvent',
    'custom':               'CustomActivity',
    'while':                'Loop',
    // SPD action map (for blueprint steps)
    'Send an Email':        'ServerEvent',
    'Set Workflow Variable': 'ServerEvent',
    'Update List Item':     'ServerEvent',
    'Create List Item':     'ServerEvent',
    'Delete List Item':     'ServerEvent',
    'Assign a Task':        'ClientEvent',
    'Start Approval Process': 'ClientEvent',
    'Log to History List':  'ServerEvent',
    'Pause for Duration':   'DelayEvent',
    'Pause Until Date':     'DelayEvent',
    'Set Content Approval Status': 'ServerEvent',
    'Check In Item':        'ServerEvent',
    'Check Out Item':       'ServerEvent',
    'Copy List Item':       'ServerEvent',
    'Wait for Field Change': 'ServerEvent',
    'Do Calculation':       'ServerEvent',
    'Set Field in Current Item': 'ServerEvent',
    'Send Document to Repository': 'ServerEvent',
    'Collect Data from a User': 'ClientEvent'
};

// ── K2 Variable Type Mapping ───────────────────────────────
const K2_VAR_TYPE = {
    'String':   'Text',
    'Text':     'Text',
    'Int32':    'Number',
    'int64':    'Number',
    'Integer':  'Number',
    'Number':   'Number',
    'Decimal':  'Decimal',
    'Double':   'Decimal',
    'float':    'Decimal',
    'Boolean':  'YesNo',
    'bool':     'YesNo',
    'DateTime': 'DateTime',
    'date':     'DateTime',
    'Guid':     'Guid',
    'Object':   'Text'
};

/**
 * Generate a deterministic GUID from namespace + input values.
 * Ensures re-runs produce byte-identical artifacts.
 */
function deterministicGuid(namespace, ...parts) {
    const seed = [namespace, ...parts].join('::');
    const hash = crypto.createHash('md5').update(seed).digest('hex');
    // Format as GUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    return [
        hash.slice(0, 8),
        hash.slice(8, 12),
        hash.slice(12, 16),
        hash.slice(16, 20),
        hash.slice(20, 32)
    ].join('-');
}

/**
 * Sanitize a name for use as a K2 process/activity name.
 * Replaces non-alphanumeric characters with underscores.
 */
function safeName(name) {
    if (!name) return 'Process';
    let n = name.replace(/[^A-Za-z0-9_]/g, '_').replace(/_+/g, '_').replace(/^_|_$/g, '');
    if (n && /^\d/.test(n)) n = '_' + n;
    return n || 'Process';
}

/**
 * Map variable type string to K2 type
 */
function mapVarType(t) {
    const key = (t || 'String').split(':').pop();
    return K2_VAR_TYPE[key] || 'Text';
}

/**
 * Escape XML special characters
 */
function escXml(str) {
    if (!str) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&apos;');
}

/**
 * Generate a KPRX (K2 Process XML) document from a workflow definition.
 *
 * @param {Object} workflowDef - Workflow definition object
 *   {
 *     id: string,              // Unique ID for deterministic GUIDs
 *     name: string,            // Display name of the workflow
 *     description: string,     // Optional description
 *     engine: string,          // 'K2' (default)
 *     band: string,            // 'green'|'yellow'|'red' (default: 'green')
 *     variables: Array<{name, type, direction, defaultValue}>,
 *     associations: Array<{name, scope, listName, listUrl, ...}>,
 *     activities: Array<{id, name, kind, properties, conditions, children}>,
 *     bandReasons: string[]    // Optional quarantine reasons
 *   }
 * @param {Object} options - Optional generation options
 *   {
 *     strictBand: boolean      // If true, refuse to emit RED-band workflows
 *   }
 * @returns {string} Complete KPRX XML string
 */
function generateKprx(workflowDef, options = {}) {
    const wd = workflowDef;
    const strictBand = options.strictBand || false;

    // Refuse RED-band workflows in strict mode
    if (strictBand && wd.band === 'red') {
        throw new Error(
            `Workflow "${wd.name}" is RED-banded — refusing to emit .kprx. ` +
            `Reasons: ${(wd.bandReasons || []).join('; ')}`
        );
    }

    const procName = safeName(wd.name);
    const procId = deterministicGuid('k2-process', wd.id || wd.name, procName);
    const workflowId = wd.id || procId;

    // ── Build XML ──────────────────────────────────────────

    let xml = `<?xml version="1.0" encoding="UTF-8"?>\n`;
    xml += `<Process Guid="${procId}" Name="${escXml(procName)}" DisplayName="${escXml(wd.name)}" `;
    xml += `Category="Workflow/Generated" SystemName="${escXml(procName)}" `;
    xml += `Version="1.0.0.0" Engine="${escXml(wd.engine || 'K2')}" Band="${escXml(wd.band || 'green')}">\n`;

    // ── Process Metadata ───────────────────────────────────
    xml += `  <Metadata>\n`;
    xml += `    <SourceFileName>${escXml(wd.sourceFile || wd.name)}</SourceFileName>\n`;
    xml += `    <WorkflowId>${escXml(workflowId)}</WorkflowId>\n`;
    xml += `    <ActivityCount>${(wd.activities || []).length}</ActivityCount>\n`;
    xml += `    <Description>${escXml(wd.description || '')}</Description>\n`;
    xml += `  </Metadata>\n`;

    // ── Variables = ProcessFields ──────────────────────────
    xml += `  <ProcessFields>\n`;
    const variables = wd.variables || wd.dataFields || [];
    for (const v of variables) {
        const varGuid = deterministicGuid('k2-var', procId, v.name);
        xml += `    <ProcessField Guid="${varGuid}" Name="${escXml(v.name)}" `;
        xml += `DisplayName="${escXml(v.displayName || v.name)}" `;
        xml += `Type="${mapVarType(v.type)}" `;
        xml += `Direction="${escXml(v.direction || 'InOut')}" `;
        xml += `DefaultValue="${escXml(v.defaultValue || v.initialValue || '')}"/>\n`;
    }
    xml += `  </ProcessFields>\n`;

    // ── Associations (SharePoint list bindings) ────────────
    if (wd.associations && wd.associations.length > 0) {
        xml += `  <WorkflowAssociations>\n`;
        for (const a of wd.associations) {
            xml += `    <Association Name="${escXml(a.name)}" `;
            xml += `Scope="${escXml(a.scope || 'List')}" `;
            xml += `List="${escXml(a.listName || '')}" `;
            xml += `ListUrl="${escXml(a.listUrl || '')}" `;
            xml += `AutoStartCreate="${a.autoStartCreate !== false ? 'true' : 'false'}" `;
            xml += `AutoStartChange="${a.autoStartChange === true ? 'true' : 'false'}" `;
            xml += `AllowManual="${a.allowManual !== false ? 'true' : 'false'}"/>\n`;
        }
        xml += `  </WorkflowAssociations>\n`;
    }

    // ── Activities & Lines ─────────────────────────────────
    const activities = flattenActivities(wd.activities || wd.steps || []);
    xml += `  <Activities>\n`;

    let prevId = null;
    const lineEntries = [];

    for (let idx = 0; idx < activities.length; idx++) {
        const act = activities[idx];
        const actId = deterministicGuid('k2-event', procId, act.id || act.name || String(idx), String(idx));
        const actName = safeName(act.name) || `Act${idx}`;
        const actDisplayName = act.displayName || act.name || act.spdAction || `Activity ${idx}`;
        const actType = K2_EVENT_TYPE[act.kind || act.type || act.spdAction || ''] || 'ServerEvent';

        xml += `    <Activity Guid="${actId}" Name="${escXml(actName)}" `;
        xml += `DisplayName="${escXml(actDisplayName)}" `;
        xml += `Type="${actType}" Order="${idx}">\n`;

        // Properties
        if (act.properties && Object.keys(act.properties).length > 0) {
            xml += `      <Properties>\n`;
            for (const [k, v] of Object.entries(act.properties)) {
                xml += `        <Property Name="${escXml(k)}">${escXml(String(v))}</Property>\n`;
            }
            xml += `      </Properties>\n`;
        }

        // Outcomes (for task/client events)
        if (act.outcomes && act.outcomes.length > 0) {
            xml += `      <Outcomes>\n`;
            for (const outcome of act.outcomes) {
                xml += `        <Outcome Name="${escXml(outcome)}"/>\n`;
            }
            xml += `      </Outcomes>\n`;
        }

        // Conditions (branching)
        if (act.conditions && act.conditions.length > 0) {
            xml += `      <Conditions>\n`;
            for (const c of act.conditions) {
                xml += `        <Condition Source="${escXml(c.source || c.expressionSource || '')}" `;
                xml += `Translated="${escXml(c.translated || c.expressionTranslated || '')}" `;
                xml += `TruthyNext="${escXml(c.truthyBranch || c.truthyNext || '')}" `;
                xml += `FalsyNext="${escXml(c.falsyBranch || c.falsyNext || '')}"/>\n`;
            }
            xml += `      </Conditions>\n`;
        }

        xml += `    </Activity>\n`;

        // Sequential transition line
        if (prevId !== null) {
            const lineGuid = deterministicGuid('k2-line', procId, prevId, actId);
            lineEntries.push(`    <Line Guid="${lineGuid}" FromGuid="${prevId}" ToGuid="${actId}"/>`);
        }

        prevId = actId;
    }

    xml += `  </Activities>\n`;

    // ── Lines (transition connections) ─────────────────────
    xml += `  <Lines>\n`;
    xml += lineEntries.join('\n') + '\n';

    // Also add explicit connections if provided
    if (wd.connections && wd.connections.length > 0) {
        for (const conn of wd.connections) {
            const connGuid = deterministicGuid('k2-conn', procId, conn.from || '', conn.to || '');
            xml += `    <Line Guid="${connGuid}" FromGuid="${escXml(conn.from)}" ToGuid="${escXml(conn.to)}" Label="${escXml(conn.label || '')}"/>\n`;
        }
    }
    xml += `  </Lines>\n`;

    // ── Advisories (band reasons) ──────────────────────────
    if (wd.bandReasons && wd.bandReasons.length > 0) {
        xml += `  <Advisories>\n`;
        for (const r of wd.bandReasons) {
            xml += `    <Reason>${escXml(r)}</Reason>\n`;
        }
        xml += `  </Advisories>\n`;
    }

    xml += `</Process>\n`;
    return xml;
}

/**
 * Flatten nested activity hierarchies into a sequential list.
 * Recursively processes children of container activities (parallel, sequence, stage).
 */
function flattenActivities(activities) {
    const out = [];
    for (const a of activities) {
        out.push(a);
        if (a.children && a.children.length > 0) {
            out.push(...flattenActivities(a.children));
        }
    }
    return out;
}

/**
 * Generate a workflow IR (Intermediate Representation) from a blueprint definition.
 * This bridges the gap between our blueprint format and the KPRX emitter.
 *
 * @param {Object} blueprint - A workflow blueprint from workflowBlueprintGenerator
 * @param {Object} options - Optional (smartObjectName, listTitle, webUrl)
 * @returns {Object} WorkflowIR suitable for generateKprx()
 */
function blueprintToWorkflowIR(blueprint, options = {}) {
    const bp = blueprint;
    const workflowName = bp.workflowName || bp.name || 'Unnamed_Workflow';
    const workflowId = bp.id || workflowName;

    const ir = {
        id: workflowId,
        name: workflowName,
        description: `Migrated from SPD ${bp.workflowType || 'workflow'}. Source: ${bp.listTitle || 'N/A'} at ${bp.webUrl || 'N/A'}`,
        engine: 'K2',
        band: 'green',
        sourceFile: bp.sourceFile || bp.workflowName,
        variables: [],
        associations: [],
        activities: [],
        bandReasons: []
    };

    // Standard data fields
    ir.variables = [
        { name: 'ItemID', type: 'Number', direction: 'InOut' },
        { name: 'Title', type: 'Text', direction: 'InOut' },
        { name: 'Status', type: 'Text', direction: 'InOut', defaultValue: 'Pending' },
        { name: 'Requester', type: 'Text', direction: 'InOut' },
        { name: 'ApproverComments', type: 'Text', direction: 'InOut' },
        { name: 'Timestamp', type: 'DateTime', direction: 'InOut' }
    ];

    // Association
    if (options.listTitle || bp.listTitle) {
        ir.associations.push({
            name: options.listTitle || bp.listTitle,
            scope: 'List',
            listName: options.listTitle || bp.listTitle,
            listUrl: options.webUrl || bp.webUrl || '',
            autoStartCreate: true,
            autoStartChange: false,
            allowManual: true
        });
    }

    // Convert blueprint steps to activities
    const steps = bp.steps || [];
    for (let idx = 0; idx < steps.length; idx++) {
        const step = steps[idx];

        // Skip setup and QA steps — they aren't real K2 activities
        if (step.category === 'Setup' || step.category === 'QA') continue;

        const isTask = ['Client Events', 'client', 'approval'].some(t =>
            (step.category || '').toLowerCase().includes(t.toLowerCase()) ||
            (step.k2Activity || '').toLowerCase().includes('task') ||
            (step.k2Activity || '').toLowerCase().includes('client event')
        );

        const activity = {
            id: `step_${step.stepNumber || idx}`,
            name: safeName(step.spdAction || step.k2Activity || `Step_${idx}`),
            displayName: step.spdAction || step.k2Activity || `Step ${idx}`,
            kind: step.spdAction || 'custom',
            type: isTask ? 'task' : 'system',
            properties: {},
            outcomes: [],
            conditions: []
        };

        // Add outcomes for task activities
        if (isTask) {
            if ((step.k2Activity || '').toLowerCase().includes('approval')) {
                activity.outcomes = ['Approved', 'Rejected'];
            } else {
                activity.outcomes = ['Completed'];
            }
        }

        // Add configuration as properties
        if (step.configuration && step.configuration.length > 0) {
            step.configuration.forEach((cfg, i) => {
                activity.properties[`config_${i}`] = cfg;
            });
        }

        ir.activities.push(activity);
    }

    return ir;
}

module.exports = {
    generateKprx,
    blueprintToWorkflowIR,
    deterministicGuid,
    safeName,
    K2_EVENT_TYPE,
    K2_VAR_TYPE
};
