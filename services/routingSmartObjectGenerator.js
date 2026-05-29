// ============================================================
// SPD → K2 Five Migration Pipeline — Routing SmartObject Generator
// Strategy A: Generates a single, generic WorkflowRouting SmartObject
// that drives the master workflow template's approval chain logic.
//
// This SmartObject is deployed ONCE and stores routing data
// for ALL migrated workflows. Methods like GetNextApprover and
// ShouldEscalate are called by SmartForm rules at runtime.
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// ============================================================

const { v4: uuidv4 } = require('uuid');

// ── Routing SmartObject Schema ──────────────────────────────

const ROUTING_SO_SCHEMA = {
    name: 'WorkflowRouting',
    displayName: 'Workflow Routing',
    description: 'Generic routing configuration for all migrated SPD workflows. Drives the master workflow template approval chain.',
    serviceBroker: 'SQL Server Service Broker',
    properties: [
        { name: 'ID',                 displayName: 'ID',                  k2Type: 'Autonumber', soType: 'System.Int32',    sqlType: 'INT IDENTITY(1,1)', isKey: true,  isRequired: true,  isReadOnly: true },
        { name: 'ProcessName',        displayName: 'Process Name',        k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)',     isKey: false, isRequired: true,  isReadOnly: false },
        { name: 'StepName',           displayName: 'Step Name',           k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)',     isKey: false, isRequired: true,  isReadOnly: false },
        { name: 'StepOrder',          displayName: 'Step Order',          k2Type: 'Number',     soType: 'System.Int32',    sqlType: 'INT',               isKey: false, isRequired: true,  isReadOnly: false },
        { name: 'ApproverField',      displayName: 'Approver',            k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(500)',     isKey: false, isRequired: true,  isReadOnly: false },
        { name: 'ApproverType',       displayName: 'Approver Type',       k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(50)',      isKey: false, isRequired: true,  isReadOnly: false },
        { name: 'EscalationMinutes',  displayName: 'Escalation (min)',    k2Type: 'Number',     soType: 'System.Int32',    sqlType: 'INT',               isKey: false, isRequired: false, isReadOnly: false },
        { name: 'EscalationTarget',   displayName: 'Escalation Target',   k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(500)',     isKey: false, isRequired: false, isReadOnly: false },
        { name: 'IsActive',           displayName: 'Is Active',           k2Type: 'YesNo',      soType: 'System.Boolean',  sqlType: 'BIT',               isKey: false, isRequired: false, isReadOnly: false },
        { name: 'Condition',          displayName: 'Condition',           k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(1000)',    isKey: false, isRequired: false, isReadOnly: false },
        { name: 'NotifyRecipients',   displayName: 'Notify Recipients',   k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(1000)',    isKey: false, isRequired: false, isReadOnly: false },
        { name: 'OutcomeOnApprove',   displayName: 'Outcome on Approve',  k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(50)',      isKey: false, isRequired: false, isReadOnly: false },
        { name: 'OutcomeOnReject',    displayName: 'Outcome on Reject',   k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(50)',      isKey: false, isRequired: false, isReadOnly: false },
        { name: 'CreatedDate',        displayName: 'Created Date',        k2Type: 'DateTime',   soType: 'System.DateTime', sqlType: 'DATETIME2(7)',      isKey: false, isRequired: false, isReadOnly: true },
        { name: 'ModifiedDate',       displayName: 'Modified Date',       k2Type: 'DateTime',   soType: 'System.DateTime', sqlType: 'DATETIME2(7)',      isKey: false, isRequired: false, isReadOnly: true }
    ],
    methods: [
        {
            name: 'GetNextApprover',
            displayName: 'Get Next Approver',
            type: 'read',
            description: 'Returns the next approver in the chain given a process name and current step',
            inputProperties: ['ProcessName', 'StepName'],
            requiredProperties: ['ProcessName'],
            returnProperties: ['ID', 'ProcessName', 'StepName', 'StepOrder', 'ApproverField', 'ApproverType', 'EscalationMinutes', 'EscalationTarget', 'Condition']
        },
        {
            name: 'GetRoutingChain',
            displayName: 'Get Routing Chain',
            type: 'list',
            description: 'Returns the full approval chain for a given process, ordered by StepOrder',
            inputProperties: ['ProcessName'],
            requiredProperties: ['ProcessName'],
            returnProperties: ['ID', 'ProcessName', 'StepName', 'StepOrder', 'ApproverField', 'ApproverType', 'EscalationMinutes', 'IsActive', 'Condition']
        },
        {
            name: 'ShouldEscalate',
            displayName: 'Should Escalate',
            type: 'read',
            description: 'Returns escalation target if elapsed time exceeds configured threshold',
            inputProperties: ['ProcessName', 'StepName'],
            requiredProperties: ['ProcessName', 'StepName'],
            returnProperties: ['EscalationMinutes', 'EscalationTarget', 'IsActive']
        },
        {
            name: 'GetNotificationRecipients',
            displayName: 'Get Notification Recipients',
            type: 'list',
            description: 'Returns notification targets for a given process step',
            inputProperties: ['ProcessName', 'StepName'],
            requiredProperties: ['ProcessName'],
            returnProperties: ['StepName', 'NotifyRecipients', 'OutcomeOnApprove', 'OutcomeOnReject']
        },
        {
            name: 'Create',
            displayName: 'Create',
            type: 'create',
            description: 'Create a new routing rule',
            inputProperties: ['ProcessName', 'StepName', 'StepOrder', 'ApproverField', 'ApproverType', 'EscalationMinutes', 'EscalationTarget', 'IsActive', 'Condition', 'NotifyRecipients', 'OutcomeOnApprove', 'OutcomeOnReject'],
            requiredProperties: ['ProcessName', 'StepName', 'StepOrder', 'ApproverField', 'ApproverType'],
            returnProperties: ['ID']
        },
        {
            name: 'Update',
            displayName: 'Update',
            type: 'update',
            description: 'Update an existing routing rule',
            inputProperties: ['ID', 'ProcessName', 'StepName', 'StepOrder', 'ApproverField', 'ApproverType', 'EscalationMinutes', 'EscalationTarget', 'IsActive', 'Condition', 'NotifyRecipients', 'OutcomeOnApprove', 'OutcomeOnReject'],
            requiredProperties: ['ID'],
            returnProperties: []
        },
        {
            name: 'Delete',
            displayName: 'Delete',
            type: 'delete',
            description: 'Delete a routing rule',
            inputProperties: ['ID'],
            requiredProperties: ['ID'],
            returnProperties: []
        },
        {
            name: 'GetList',
            displayName: 'Get List',
            type: 'list',
            description: 'Get all routing rules (optionally filtered)',
            inputProperties: ['ProcessName', 'IsActive'],
            requiredProperties: [],
            returnProperties: ['ID', 'ProcessName', 'StepName', 'StepOrder', 'ApproverField', 'ApproverType', 'EscalationMinutes', 'EscalationTarget', 'IsActive', 'Condition', 'NotifyRecipients', 'OutcomeOnApprove', 'OutcomeOnReject', 'CreatedDate', 'ModifiedDate']
        }
    ]
};


class RoutingSmartObjectGenerator {

    constructor() {
        this.routingData = new Map();  // processName → routing records
        this.generationLog = [];
        this.routingSODefinition = null;
    }

    /**
     * Generate the WorkflowRouting SmartObject definition
     * This is always the same — one generic SO for all workflows
     */
    generateRoutingSO() {
        const soGuid = uuidv4();

        this.routingSODefinition = {
            id: `so-routing-${soGuid.slice(0, 8)}`,
            guid: soGuid,
            ...ROUTING_SO_SCHEMA,
            backingTable: 'K2_Migration.dbo.WorkflowRouting',
            serviceInstance: 'K2_PROD_WorkflowRouting',
            deploymentStatus: 'pending',
            generatedAt: new Date().toISOString(),
            metadata: {
                sourceSystem: 'Strategy A — Routing Configuration',
                targetSystem: 'K2 Five 5.8 FP26',
                purpose: 'Generic routing SmartObject for all migrated workflows'
            }
        };

        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: `Generated WorkflowRouting SmartObject with ${ROUTING_SO_SCHEMA.properties.length} properties, ${ROUTING_SO_SCHEMA.methods.length} methods`
        });

        return this.routingSODefinition;
    }

    /**
     * Generate routing data (seed records) from an analyzed workflow
     * Parses the workflow's actions/conditions to build an approval chain
     * @param {Object} wf - Analyzed workflow item
     * @param {Object} tierClassification - Result from analysisEngine.classifyWorkflowTier()
     * @returns {Array} Routing records for this workflow
     */
    generateRoutingData(wf, tierClassification) {
        const processName = (wf.name || wf.workflowName || '').replace(/[^a-zA-Z0-9_]/g, '_');
        const records = [];

        if (!processName) return records;

        // Determine approval chain based on tier and workflow attributes
        const approvalSteps = tierClassification?.counts?.approvalSteps || 1;
        const hasEscalation = tierClassification?.counts?.escalationTimers > 0;
        const actionCount = wf.actionCount || 0;
        const name = (wf.workflowName || wf.name || '').toLowerCase();

        // Build routing chain
        for (let i = 0; i < approvalSteps; i++) {
            const stepOrder = i + 1;
            const isLastStep = i === approvalSteps - 1;

            let stepName, approverField, approverType;

            if (approvalSteps === 1) {
                // Single-step approval
                stepName = 'ManagerApproval';
                approverField = name.includes('leave') || name.includes('request')
                    ? 'K2:DOMAIN\\Manager'
                    : 'K2:DOMAIN\\Approver';
                approverType = 'manager';
            } else if (i === 0) {
                // First step — immediate manager
                stepName = 'ManagerApproval';
                approverField = 'K2:DOMAIN\\Manager';
                approverType = 'manager';
            } else if (i === 1) {
                // Second step — director
                stepName = 'DirectorApproval';
                approverField = 'K2:DOMAIN\\Director';
                approverType = 'role';
            } else {
                // Further steps — VP / escalation chain
                stepName = `Level${stepOrder}Approval`;
                approverField = `K2:DOMAIN\\Level${stepOrder}Approver`;
                approverType = 'role';
            }

            records.push({
                processName,
                stepName,
                stepOrder,
                approverField,
                approverType,
                escalationMinutes: hasEscalation ? (stepOrder === 1 ? 4320 : 2880) : 0, // 3 days first, 2 days after
                escalationTarget: hasEscalation ? `K2:DOMAIN\\Level${stepOrder + 1}Approver` : '',
                isActive: true,
                condition: '',
                notifyRecipients: `K2:DOMAIN\\Requester`,
                outcomeOnApprove: isLastStep ? 'Complete' : `Step${stepOrder + 1}`,
                outcomeOnReject: 'Rejected'
            });
        }

        // Store the routing data
        this.routingData.set(processName, records);

        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: `Generated ${records.length} routing records for "${processName}" (${tierClassification?.tierLabel || 'unknown tier'})`
        });

        return records;
    }

    /**
     * Generate routing data for ALL analyzed workflows
     * @param {Array} workflows - Analyzed workflow items
     * @param {Object} analysisEngine - AnalysisEngine instance for tier classification
     * @returns {Object} Generation summary
     */
    generateAllRoutingData(workflows, analysisEngine) {
        this.routingData.clear();
        let generated = 0;
        let skipped = 0;

        for (const wf of workflows) {
            if (wf.assetType !== 'workflow') continue;

            const classification = analysisEngine.classifyWorkflowTier(wf);

            // Only generate routing for auto-migratable workflows
            if (classification.migrationPath === 'auto' || classification.migrationPath === 'auto-with-review') {
                this.generateRoutingData(wf, classification);
                generated++;
            } else {
                skipped++;
                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'info',
                    message: `Skipped routing for "${wf.name || wf.workflowName}" (${classification.migrationPath})`
                });
            }
        }

        return {
            generated,
            skipped,
            totalRecords: Array.from(this.routingData.values()).reduce((s, r) => s + r.length, 0),
            timestamp: new Date().toISOString()
        };
    }

    /**
     * Get the routing SmartObject definition
     */
    getRoutingSO() {
        if (!this.routingSODefinition) this.generateRoutingSO();
        return this.routingSODefinition;
    }

    /**
     * Get routing data for a specific process
     */
    getRoutingData(processName) {
        return this.routingData.get(processName) || [];
    }

    /**
     * Get all routing data
     */
    getAllRoutingData() {
        const all = [];
        for (const [processName, records] of this.routingData.entries()) {
            all.push({ processName, records, recordCount: records.length });
        }
        return all;
    }

    /**
     * Get SODX XML for the WorkflowRouting SmartObject
     */
    getXml() {
        const so = this.getRoutingSO();

        const xmlProps = so.properties.map(p => {
            const attrs = [
                `name="${this._xmlEsc(p.name)}"`,
                `type="${this._xmlEsc(p.k2Type)}"`,
                `so_type="${this._xmlEsc(p.soType)}"`
            ];
            if (p.isKey) attrs.push('iskey="true"');
            if (p.isRequired) attrs.push('required="true"');
            if (p.isReadOnly) attrs.push('readonly="true"');

            return `      <property ${attrs.join(' ')}>
        <metadata><display name="${this._xmlEsc(p.displayName)}"/></metadata>
      </property>`;
        }).join('\n');

        const xmlMethods = so.methods.map(m => {
            const inputXml = m.inputProperties.map(name =>
                `          <property name="${this._xmlEsc(name)}"${m.requiredProperties.includes(name) ? ' required="true"' : ''}/>`
            ).join('\n');

            const returnXml = m.returnProperties.map(name =>
                `          <property name="${this._xmlEsc(name)}"/>`
            ).join('\n');

            return `      <method name="${this._xmlEsc(m.name)}" type="${m.type}">
        <metadata>
          <display name="${this._xmlEsc(m.displayName)}"/>
          <description>${this._xmlEsc(m.description)}</description>
        </metadata>
        <inputproperties>
${inputXml}
        </inputproperties>
        <returnproperties>
${returnXml}
        </returnproperties>
      </method>`;
        }).join('\n');

        return `<?xml version="1.0" encoding="utf-8"?>
<!--
  K2 SmartObject Definition (SODX)
  Strategy A: WorkflowRouting — Generic routing SmartObject
  Generated by: SPD → K2 Five Migration Pipeline
  Target: K2 Five 5.8 FP26 (5.0009.1026.0)
  Generated: ${so.generatedAt}
-->
<smartobjectroot xmlns="http://schemas.k2.com/smartobject/model" version="1.0">
  <smartobject name="${this._xmlEsc(so.name)}" guid="{${so.guid}}" version="0"
               metadata="Strategy A: Routing configuration for all migrated workflows">

    <metadata>
      <display name="${this._xmlEsc(so.displayName)}"/>
      <description>${this._xmlEsc(so.description)}</description>
    </metadata>

    <serviceinstance name="${this._xmlEsc(so.serviceInstance)}"
                     servicebroker="${this._xmlEsc(so.serviceBroker)}"
                     connectionstring="Data Source=75387P_LN01;Initial Catalog=K2_PROD;Integrated Security=SSPI"/>

    <properties>
${xmlProps}
    </properties>

    <methods>
${xmlMethods}
    </methods>

  </smartobject>
</smartobjectroot>`;
    }

    /**
     * Get SQL DDL for the WorkflowRouting backing table
     */
    getSql() {
        const so = this.getRoutingSO();
        const columns = so.properties.map(p => {
            let colDef = `    [${p.name}] ${p.sqlType}`;
            if (p.isKey) colDef += ' PRIMARY KEY';
            if (p.isRequired && !p.isKey) colDef += ' NOT NULL';
            if (!p.isRequired && !p.isKey) colDef += ' NULL';
            return colDef;
        }).join(',\n');

        // Generate INSERT statements for seed data
        const inserts = [];
        for (const [processName, records] of this.routingData.entries()) {
            for (const r of records) {
                inserts.push(`INSERT INTO [K2_Migration].[WorkflowRouting] (ProcessName, StepName, StepOrder, ApproverField, ApproverType, EscalationMinutes, EscalationTarget, IsActive, [Condition], NotifyRecipients, OutcomeOnApprove, OutcomeOnReject)
VALUES ('${this._sqlEsc(r.processName)}', '${this._sqlEsc(r.stepName)}', ${r.stepOrder}, '${this._sqlEsc(r.approverField)}', '${this._sqlEsc(r.approverType)}', ${r.escalationMinutes}, '${this._sqlEsc(r.escalationTarget)}', ${r.isActive ? 1 : 0}, '${this._sqlEsc(r.condition)}', '${this._sqlEsc(r.notifyRecipients)}', '${this._sqlEsc(r.outcomeOnApprove)}', '${this._sqlEsc(r.outcomeOnReject)}');`);
            }
        }

        return `-- ============================================================
-- K2 WorkflowRouting — Backing Table + Seed Data
-- Strategy A: Generic routing for all migrated workflows
-- Target: K2_PROD (75387P_LN01 / 75387P-AG01)
-- ============================================================

USE [K2_PROD];
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'K2_Migration')
    EXEC('CREATE SCHEMA [K2_Migration]');
GO

IF OBJECT_ID('K2_Migration.WorkflowRouting', 'U') IS NOT NULL
    DROP TABLE [K2_Migration].[WorkflowRouting];
GO

CREATE TABLE [K2_Migration].[WorkflowRouting] (
${columns}
);
GO

-- Indexes for routing lookups
CREATE NONCLUSTERED INDEX [IX_WorkflowRouting_Process]
    ON [K2_Migration].[WorkflowRouting] ([ProcessName], [StepOrder])
    WHERE [IsActive] = 1;
GO

CREATE NONCLUSTERED INDEX [IX_WorkflowRouting_ProcessStep]
    ON [K2_Migration].[WorkflowRouting] ([ProcessName], [StepName])
    WHERE [IsActive] = 1;
GO

-- Seed data
${inserts.length > 0 ? inserts.join('\n') : '-- No routing data generated yet. Run analysis + routing generation first.'}
GO

PRINT 'WorkflowRouting table created with ${inserts.length} seed records.';
GO
`;
    }

    /**
     * Get generation log
     */
    getLog() {
        return this.generationLog;
    }

    /**
     * Get stats summary
     */
    getStats() {
        return {
            routingSOGenerated: !!this.routingSODefinition,
            totalProcesses: this.routingData.size,
            totalRecords: Array.from(this.routingData.values()).reduce((s, r) => s + r.length, 0),
            deploymentStatus: this.routingSODefinition?.deploymentStatus || 'not-generated'
        };
    }

    // ── Utilities ───────────────────────────────────────────

    _xmlEsc(str) {
        if (!str) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&apos;');
    }

    _sqlEsc(str) {
        if (!str) return '';
        return String(str).replace(/'/g, "''");
    }
}

module.exports = { RoutingSmartObjectGenerator, ROUTING_SO_SCHEMA };
