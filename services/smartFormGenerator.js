// ============================================================
// SPD → K2 Five Migration Pipeline — SmartForm Generator
// Phase 4: Generates K2 SmartForm view definitions from
// SmartObject property definitions
//
// Strategy A Enhancement: Generates an Approval View with
// Worklist Action rules (Approve/Reject/Reassign) that signal
// the master workflow template.
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// API: SourceCode.Forms.Authoring
// ============================================================

const { v4: uuidv4 } = require('uuid');

// ── Control Type Mapping ────────────────────────────────────

const CONTROL_MAP = {
    'Text':       { control: 'TextBox',      controlTypeId: 'com.k2.smartforms.controls.textbox', editable: true },
    'Memo':       { control: 'TextArea',     controlTypeId: 'com.k2.smartforms.controls.textarea', editable: true },
    'Number':     { control: 'TextBox',      controlTypeId: 'com.k2.smartforms.controls.textbox', editable: true, format: 'numeric' },
    'DateTime':   { control: 'DatePicker',   controlTypeId: 'com.k2.smartforms.controls.datepicker', editable: true },
    'YesNo':      { control: 'CheckBox',     controlTypeId: 'com.k2.smartforms.controls.checkbox', editable: true },
    'File':       { control: 'Attachment',    controlTypeId: 'com.k2.smartforms.controls.attachment', editable: true },
    'Autonumber': { control: 'Label',        controlTypeId: 'com.k2.smartforms.controls.label', editable: false }
};

// View types and their SmartObject method bindings
const VIEW_TYPES = {
    list: {
        name: 'ListView',
        displayName: 'List View',
        type: 'list',
        method: 'GetList',
        description: 'Displays all records in a data grid with sorting and filtering'
    },
    item: {
        name: 'ItemView',
        displayName: 'Item View',
        type: 'item',
        method: 'Read',
        description: 'Read-only display of a single record'
    },
    edit: {
        name: 'EditView',
        displayName: 'Edit View',
        type: 'edit',
        method: 'Read',
        description: 'Editable form for creating and updating records'
    },
    approval: {
        name: 'ApprovalView',
        displayName: 'Approval View',
        type: 'approval',
        method: 'Read',
        description: 'Strategy A: Approval form with Approve/Reject/Reassign buttons that signal the K2 workflow via Worklist Action'
    }
};

// Strategy A: Approval View rule templates — these signal the master workflow template
const APPROVAL_RULE_TEMPLATES = [
    {
        name: 'OnViewInitialize',
        event: 'ViewInitialize',
        description: 'Load record data and fetch current routing info from WorkflowRouting SmartObject',
        conditions: [],
        actions: [
            { type: 'ExecuteMethod', method: 'Read', transferData: 'returnProperties' },
            { type: 'ExecuteMethod', smartObject: 'WorkflowRouting', method: 'GetNextApprover',
              input: { ProcessName: '[WorkflowName]', StepName: '[CurrentStep]' },
              transferData: 'returnProperties' }
        ]
    },
    {
        name: 'OnApproveClick',
        event: 'ButtonClick',
        triggerControl: 'btnApprove',
        description: 'Approve the request: update SmartObject status + signal K2 Worklist with Approve action',
        conditions: [],
        actions: [
            { type: 'ExecuteMethod', method: 'Update', input: { Status: 'Approved' }, transferData: 'inputOnly' },
            { type: 'WorklistAction', action: 'Approve', comment: '[ApproverComments]',
              description: 'Calls Worklist SmartObject Action method to signal the workflow' }
        ]
    },
    {
        name: 'OnRejectClick',
        event: 'ButtonClick',
        triggerControl: 'btnReject',
        description: 'Reject the request: validate comments required, update status, signal K2 Worklist',
        conditions: [{ type: 'ValidateRequired', fields: ['ApproverComments'] }],
        actions: [
            { type: 'ExecuteMethod', method: 'Update', input: { Status: 'Rejected' }, transferData: 'inputOnly' },
            { type: 'WorklistAction', action: 'Reject', comment: '[ApproverComments]',
              description: 'Calls Worklist SmartObject Action method with Reject outcome' }
        ]
    },
    {
        name: 'OnReassignClick',
        event: 'ButtonClick',
        triggerControl: 'btnReassign',
        description: 'Reassign the task to another approver via Worklist SmartObject',
        conditions: [{ type: 'ValidateRequired', fields: ['ReassignTo'] }],
        actions: [
            { type: 'WorklistAction', action: 'Reassign', target: '[ReassignTo]',
              description: 'Calls Worklist SmartObject Redirect method to reassign the task' }
        ]
    },
    {
        name: 'OnBackClick',
        event: 'ButtonClick',
        triggerControl: 'btnBackToList',
        description: 'Return to list view without action',
        conditions: [],
        actions: [{ type: 'NavigateToView', targetView: 'ListView', passId: false }]
    }
];

// Strategy A: Workflow-start rule template — injected into Edit view when binding is configured
const WORKFLOW_START_RULE = {
    name: 'OnSubmitStartWorkflow',
    event: 'ButtonClick',
    triggerControl: 'btnSubmit',
    description: 'Strategy A: Start the bound K2 workflow template after saving the record. Passes ProcessKey + DataSmartObject reference so the workflow knows what data triggered it and what routing pattern to follow.',
    conditions: [{ type: 'ValidateRequired' }],
    actions: [
        { type: 'ExecuteMethod', method: 'Create', transferData: 'inputOnly',
          description: 'Save the form data first' },
        { type: 'StartWorkflow', workflowTemplate: '__TEMPLATE_NAME__',
          dataFields: {
              ProcessKey: '__PROCESS_KEY__',
              DataSmartObject: '__DATA_SO__',
              DataItemID: '[ID]',
              Originator: '[K2:CurrentUser]',
              FormName: '__FORM_NAME__',
              Site: '__SITE__'
          },
          description: 'Start the K2 workflow template with routing parameters' },
        { type: 'NavigateToView', targetView: 'ItemView', passId: true }
    ]
};

// Standard rule templates for SmartForm views
const RULE_TEMPLATES = {
    list: [
        {
            name: 'OnViewInitialize',
            event: 'ViewInitialize',
            description: 'Load all records when the list view initializes',
            conditions: [],
            actions: [{ type: 'ExecuteMethod', method: 'GetList', transferData: 'returnProperties' }]
        },
        {
            name: 'OnRowDoubleClick',
            event: 'ListItemDoubleClick',
            description: 'Navigate to item view on row double-click',
            conditions: [],
            actions: [{ type: 'NavigateToView', targetView: 'ItemView', passId: true }]
        },
        {
            name: 'OnAddButtonClick',
            event: 'ButtonClick',
            triggerControl: 'btnAdd',
            description: 'Navigate to edit view for new record',
            conditions: [],
            actions: [{ type: 'NavigateToView', targetView: 'EditView', passId: false }]
        }
    ],
    item: [
        {
            name: 'OnViewInitialize',
            event: 'ViewInitialize',
            description: 'Load record data when the item view initializes',
            conditions: [],
            actions: [{ type: 'ExecuteMethod', method: 'Read', transferData: 'returnProperties' }]
        },
        {
            name: 'OnEditButtonClick',
            event: 'ButtonClick',
            triggerControl: 'btnEdit',
            description: 'Navigate to edit view',
            conditions: [],
            actions: [{ type: 'NavigateToView', targetView: 'EditView', passId: true }]
        },
        {
            name: 'OnDeleteButtonClick',
            event: 'ButtonClick',
            triggerControl: 'btnDelete',
            description: 'Delete the current record after confirmation',
            conditions: [{ type: 'UserConfirm', message: 'Are you sure you want to delete this record?' }],
            actions: [
                { type: 'ExecuteMethod', method: 'Delete', transferData: 'inputOnly' },
                { type: 'NavigateToView', targetView: 'ListView', passId: false }
            ]
        },
        {
            name: 'OnBackButtonClick',
            event: 'ButtonClick',
            triggerControl: 'btnBack',
            description: 'Return to list view',
            conditions: [],
            actions: [{ type: 'NavigateToView', targetView: 'ListView', passId: false }]
        }
    ],
    edit: [
        {
            name: 'OnViewInitialize',
            event: 'ViewInitialize',
            description: 'Load record data for editing (if editing existing record)',
            conditions: [{ type: 'Expression', expression: 'ID > 0' }],
            actions: [{ type: 'ExecuteMethod', method: 'Read', transferData: 'returnProperties' }]
        },
        {
            name: 'OnSaveButtonClick',
            event: 'ButtonClick',
            triggerControl: 'btnSave',
            description: 'Validate and save the record (Create or Update, without starting workflow)',
            conditions: [{ type: 'ValidateRequired' }],
            actions: [
                { type: 'ConditionalMethod', condition: 'ID == 0', methodIfTrue: 'Create', methodIfFalse: 'Update' },
                { type: 'NavigateToView', targetView: 'ItemView', passId: true }
            ]
        },
        {
            name: 'OnCancelButtonClick',
            event: 'ButtonClick',
            triggerControl: 'btnCancel',
            description: 'Cancel editing and return to previous view',
            conditions: [],
            actions: [{ type: 'NavigateToView', targetView: 'ListView', passId: false }]
        }
    ]
};

// SharePoint 2013 Broker method name mapping
// SmartBox uses: Create, Save (Update), Delete, Load (Read), GetList
// SP Broker uses: CreateListItem, UpdateListItem, DeleteListItem, GetListItemByID, GetListItems
const SP_BROKER_METHOD_MAP = {
    'GetList': 'GetListItems',
    'Read': 'GetListItemByID',
    'Load': 'GetListItemByID',
    'Create': 'CreateListItem',
    'Update': 'UpdateListItem',
    'Save': 'UpdateListItem',
    'Delete': 'DeleteListItem'
};

// Validation rule patterns based on property types
const VALIDATION_PATTERNS = {
    'Text':     { maxLength: 255, pattern: null },
    'Memo':     { maxLength: 4000, pattern: null },
    'Number':   { maxLength: null, pattern: '^-?[0-9]+(\\.[0-9]{1,4})?$' },
    'DateTime': { maxLength: null, pattern: null },
    'YesNo':    { maxLength: null, pattern: null }
};


class SmartFormGenerator {

    constructor() {
        this.smartForms = new Map();    // id → SmartForm definition
        this.generationLog = [];
        this.lastGenerationTimestamp = null;
    }

    /**
     * Generate SmartForm definitions from SmartObject definitions
     * One SmartForm (with 3-4 views) per SmartObject
     * Strategy A: If tierClassifications are provided, generates an Approval View
     * for workflows classified as auto-migratable (Tier 1-2)
     *
     * @param {Map|Array} smartObjects - SmartObject definitions from generator
     * @param {Object} options - { tierClassifications: Map<soName, classification> }
     * @returns {Object} Generation summary
     */
    generate(smartObjects, options = {}) {
        this.smartForms.clear();
        this.generationLog = [];

        const soArray = Array.isArray(smartObjects) ? smartObjects : Array.from(smartObjects.values());
        const tierMap = options.tierClassifications || new Map();
        const brokerType = options.brokerType || 'SmartBox';
        this._currentBrokerType = brokerType;  // Used by _generateView for method naming

        let generated = 0;
        let errors = 0;
        let totalViews = 0;
        let totalControls = 0;
        let totalRules = 0;
        let approvalViewCount = 0;

        for (const so of soArray) {
            try {
                // Use per-SO broker type if set (discovered SOs have brokerType='SharePoint')
                // Otherwise fall back to the global option
                this._currentBrokerType = so.brokerType || brokerType;

                // Check if this SO has a workflow that needs an approval view
                const classification = tierMap.get(so.name) || tierMap.get(so.listTitle) || null;
                const includeApproval = classification &&
                    (classification.migrationPath === 'auto' || classification.migrationPath === 'auto-with-review');

                const sf = this._generateSmartForm(so, includeApproval, classification);
                this.smartForms.set(sf.id, sf);
                generated++;
                totalViews += sf.views.length;
                totalControls += sf.views.reduce((sum, v) => sum + v.controls.length, 0);
                totalRules += sf.views.reduce((sum, v) => sum + v.rules.length, 0);
                if (includeApproval) approvalViewCount++;

                const approvalTag = includeApproval ? ` [+ Approval View: ${classification.tierLabel}]` : '';
                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'info',
                    smartFormId: sf.id,
                    message: `Generated SmartForm "${sf.name}" with ${sf.views.length} views, ${sf.views.reduce((s, v) => s + v.controls.length, 0)} controls, ${sf.views.reduce((s, v) => s + v.rules.length, 0)} rules${approvalTag}`
                });
            } catch (err) {
                errors++;
                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'error',
                    smartObjectName: so.name,
                    message: `Failed to generate SmartForm: ${err.message}`
                });
            }
        }

        this.lastGenerationTimestamp = new Date().toISOString();

        return {
            generated,
            errors,
            totalViews,
            totalControls,
            totalRules,
            approvalViewCount,
            timestamp: this.lastGenerationTimestamp
        };
    }

    /**
     * Get all SmartForms (summary)
     */
    getAll() {
        return Array.from(this.smartForms.values()).map(sf => ({
            id: sf.id,
            name: sf.name,
            displayName: sf.displayName,
            smartObjectName: sf.smartObjectName,
            smartObjectId: sf.smartObjectId,
            viewCount: sf.views.length,
            controlCount: sf.views.reduce((s, v) => s + v.controls.length, 0),
            ruleCount: sf.views.reduce((s, v) => s + v.rules.length, 0),
            validationCount: sf.views.reduce((s, v) => s + v.validations.length, 0),
            complexity: sf.complexity,
            deploymentStatus: sf.deploymentStatus,
            manualConfigRequired: sf.manualConfigItems.length > 0,
            manualConfigCount: sf.manualConfigItems.length,
            generatedAt: sf.generatedAt
        }));
    }

    /**
     * Get SmartForm by ID (full detail)
     */
    getById(id) {
        return this.smartForms.get(id) || null;
    }

    /**
     * Get SmartForm XML definition
     */
    getXml(id) {
        const sf = this.smartForms.get(id);
        if (!sf) return null;
        return this._generateFormXml(sf);
    }

    /**
     * Update deployment status
     */
    updateDeploymentStatus(id, status, details = {}) {
        const sf = this.smartForms.get(id);
        if (!sf) return false;
        sf.deploymentStatus = status;
        sf.deploymentDetails = { ...sf.deploymentDetails, ...details, lastUpdated: new Date().toISOString() };
        return true;
    }

    /**
     * Strategy A: Bind a workflow template to an existing SmartForm (lazy binding)
     * Called by Workflows tab bind endpoint. Injects StartWorkflow rule + Submit button
     * into the Edit view and regenerates the form XML.
     *
     * @param {string} smartObjectName - Name of the SmartObject (to find the SmartForm)
     * @param {Object} binding - { templateName, processKey, formName, site }
     * @returns {Object} { success, xml, smartForm, message }
     */
    bindWorkflow(smartObjectName, binding) {
        // Find the SmartForm for this SO
        const sf = Array.from(this.smartForms.values())
            .find(f => f.smartObjectName === smartObjectName);

        if (!sf) {
            return { success: false, message: `SmartForm not found for SmartObject "${smartObjectName}". Generate SmartForms first.` };
        }

        const editView = sf.views.find(v => v.type === 'edit');
        if (!editView) {
            return { success: false, message: `Edit view not found in SmartForm "${sf.name}".` };
        }

        // Remove any existing workflow-start rules (idempotent rebind)
        editView.rules = editView.rules.filter(r => r.name !== 'OnSubmitStartWorkflow');
        editView.controls = editView.controls.filter(c => c.name !== 'btnSubmit');

        // Add Submit button
        const lastRow = editView.controls.reduce((max, c) => Math.max(max, (c.position?.row || 0)), 0) + 1;
        editView.controls.push(this._createButton('btnSubmit', '📤 Submit for Approval', 'primary', { row: lastRow, col: 0, colSpan: 4 }));

        // Add StartWorkflow rule
        const processKey = binding.processKey || smartObjectName.replace(/[^a-zA-Z0-9_]/g, '_');
        const startRule = {
            id: `rule-${uuidv4().slice(0, 6)}`,
            name: 'OnSubmitStartWorkflow',
            event: 'ButtonClick',
            triggerControl: 'btnSubmit',
            description: `Strategy A: Save + Start ${binding.templateName} with ProcessKey=${processKey}`,
            viewName: 'EditView',
            conditions: [{ type: 'ValidateRequired' }],
            actions: [
                { type: 'ExecuteMethod', method: 'Create', transferData: 'inputOnly' },
                { type: 'StartWorkflow', workflowTemplate: binding.templateName,
                  dataFields: {
                      ProcessKey: processKey,
                      DataSmartObject: smartObjectName,
                      DataItemID: '[ID]',
                      Originator: '[K2:CurrentUser]',
                      FormName: binding.formName || sf.displayName,
                      Site: binding.site || ''
                  }
                },
                { type: 'NavigateToView', targetView: 'ItemView', passId: true }
            ],
            smartObjectMethod: 'Create',
            workflowTemplate: binding.templateName
        };
        editView.rules.push(startRule);

        // Mark the form as bound
        sf.workflowBinding = {
            templateName: binding.templateName,
            processKey: processKey,
            boundAt: new Date().toISOString()
        };

        // Regenerate XML with the new rule
        const xml = this._generateFormXml(sf);

        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: `Bound workflow "${binding.templateName}" to SmartForm "${sf.name}" (ProcessKey: ${processKey})`
        });

        return {
            success: true,
            xml,
            smartForm: sf,
            message: `SmartForm "${sf.name}" now has Submit → Start ${binding.templateName} rule with ProcessKey=${processKey}`
        };
    }

    /**
     * Get stats summary
     */
    getStats() {
        const all = Array.from(this.smartForms.values());
        return {
            total: all.length,
            deployed: all.filter(s => s.deploymentStatus === 'deployed').length,
            pending: all.filter(s => s.deploymentStatus === 'pending').length,
            failed: all.filter(s => s.deploymentStatus === 'failed').length,
            totalViews: all.reduce((s, f) => s + f.views.length, 0),
            totalControls: all.reduce((s, f) => s + f.views.reduce((vs, v) => vs + v.controls.length, 0), 0),
            totalRules: all.reduce((s, f) => s + f.views.reduce((vs, v) => vs + v.rules.length, 0), 0),
            totalValidations: all.reduce((s, f) => s + f.views.reduce((vs, v) => vs + v.validations.length, 0), 0),
            manualConfigItems: all.reduce((s, f) => s + f.manualConfigItems.length, 0),
            lastGeneration: this.lastGenerationTimestamp
        };
    }

    /**
     * Get generation log
     */
    getLog() {
        return this.generationLog;
    }


    // ── Internal: Generation Logic ──────────────────────────

    /**
     * Generate a complete SmartForm for a SmartObject
     * @param {Object} so - SmartObject definition
     * @param {boolean} includeApproval - Whether to generate an Approval View (Strategy A)
     * @param {Object} tierClassification - Tier classification from analysis engine
     * @param {Object} workflowBinding - Optional: { templateName, processKey, site } for lazy binding
     */
    _generateSmartForm(so, includeApproval = false, tierClassification = null, workflowBinding = null) {
        const sfGuid = uuidv4();
        const sfName = `${so.name}_Form`;
        const brokerType = this._currentBrokerType || 'SmartBox';

        // Generate standard views (list, item, edit)
        const views = [];
        const manualConfigItems = [];

        for (const [viewKey, viewTemplate] of Object.entries(VIEW_TYPES)) {
            // Skip approval view here — handled separately below
            if (viewKey === 'approval') continue;
            const view = this._generateView(viewKey, viewTemplate, so, manualConfigItems);
            views.push(view);
        }

        // Strategy A: Generate Approval View if this SO has an auto-migratable workflow
        if (includeApproval) {
            const approvalView = this._generateApprovalView(so, tierClassification);
            views.push(approvalView);

            this.generationLog.push({
                timestamp: new Date().toISOString(),
                level: 'info',
                message: `  → Added Approval View for "${so.name}" (${tierClassification?.tierLabel || 'auto-migrate'})`
            });
        }

        // Strategy A: Inject workflow-start rule into Edit view (lazy binding from Workflows tab)
        if (workflowBinding && workflowBinding.templateName) {
            const editView = views.find(v => v.type === 'edit');
            if (editView) {
                // Add a Submit button (separate from Save — Save just saves, Submit saves + starts workflow)
                const lastRow = editView.controls.reduce((max, c) => Math.max(max, (c.position?.row || 0)), 0) + 1;
                editView.controls.push(this._createButton('btnSubmit', '📤 Submit for Approval', 'primary', { row: lastRow, col: 0, colSpan: 4 }));

                // Create parametrized workflow-start rule
                const processKey = workflowBinding.processKey || so.name.replace(/[^a-zA-Z0-9_]/g, '_');
                const startRule = {
                    id: `rule-${uuidv4().slice(0, 6)}`,
                    name: 'OnSubmitStartWorkflow',
                    event: 'ButtonClick',
                    triggerControl: 'btnSubmit',
                    description: `Strategy A: Save + Start ${workflowBinding.templateName} with ProcessKey=${processKey}`,
                    viewName: 'EditView',
                    conditions: [{ type: 'ValidateRequired' }],
                    actions: [
                        { type: 'ExecuteMethod', method: 'Create', transferData: 'inputOnly',
                          description: 'Save the form data first' },
                        { type: 'StartWorkflow', workflowTemplate: workflowBinding.templateName,
                          dataFields: {
                              ProcessKey: processKey,
                              DataSmartObject: so.name,
                              DataItemID: '[ID]',
                              Originator: '[K2:CurrentUser]',
                              FormName: workflowBinding.formName || so.displayName,
                              Site: workflowBinding.site || ''
                          },
                          description: `Start ${workflowBinding.templateName} with routing parameters` },
                        { type: 'NavigateToView', targetView: 'ItemView', passId: true }
                    ],
                    smartObjectMethod: 'Create',
                    workflowTemplate: workflowBinding.templateName
                };
                editView.rules.push(startRule);

                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'info',
                    message: `  → Bound workflow "${workflowBinding.templateName}" to Edit view (ProcessKey: ${processKey})`
                });
            }
        }

        // Detect manual config needs
        so.properties.forEach(prop => {
            if (prop.autoMap === 'config') {
                manualConfigItems.push({
                    type: 'control_config',
                    property: prop.name,
                    reason: `${prop.spFieldType} requires manual SmartForm rule configuration`,
                    view: 'EditView',
                    suggestion: this._getConfigSuggestion(prop)
                });
            }
            if (prop.autoMap === 'blocked') {
                manualConfigItems.push({
                    type: 'blocked_field',
                    property: prop.name,
                    reason: `${prop.spFieldType} has no direct SmartForm control mapping`,
                    view: 'All Views',
                    suggestion: 'Implement custom REST data source or remove from form'
                });
            }
        });

        return {
            id: `sf-${sfGuid.slice(0, 8)}`,
            guid: sfGuid,
            name: sfName,
            displayName: `${so.displayName} Form`,
            smartObjectId: so.id,
            smartObjectName: so.name,
            smartObjectDisplayName: so.displayName,
            complexity: so.complexity,
            brokerType,
            views,
            manualConfigItems,
            deploymentStatus: 'pending',
            deploymentDetails: {},
            generatedAt: new Date().toISOString(),
            metadata: {
                sourceSmartObject: so.guid,
                sourceLegacyList: so.listTitle,
                sourceLegacySite: so.webUrl,
                targetPlatform: 'K2 Five 5.8 FP26',
                brokerType
            }
        };
    }

    /**
     * Generate a single view (List, Item, or Edit)
     */
    _generateView(viewKey, viewTemplate, so, manualConfigItems) {
        const viewGuid = uuidv4();
        const controls = [];
        const validations = [];

        // Determine which properties to include in this view
        const visibleProperties = so.properties.filter(p => {
            // System audit fields hidden on edit, shown on item
            if (['CreatedBy', 'CreatedDate', 'ModifiedBy', 'ModifiedDate'].includes(p.name)) {
                return viewKey !== 'edit';
            }
            return true;
        });

        if (viewKey === 'list') {
            // List view: DataGrid control with column definitions
            const gridColumns = visibleProperties.slice(0, 10).map((prop, idx) => ({
                name: prop.name,
                displayName: prop.displayName,
                width: this._getColumnWidth(prop),
                sortable: true,
                filterable: idx < 5,
                visible: true,
                format: this._getDisplayFormat(prop)
            }));

            controls.push({
                id: `ctrl-grid-${viewGuid.slice(0, 6)}`,
                name: 'DataGrid',
                displayName: 'Records Grid',
                controlType: 'DataGrid',
                controlTypeId: 'com.k2.smartforms.controls.datagrid',
                dataField: null,
                columns: gridColumns,
                editable: false,
                position: { row: 1, col: 1, colSpan: 12 }
            });

            // Toolbar buttons
            controls.push(this._createButton('btnAdd', 'Add New', 'primary', { row: 0, col: 1, colSpan: 2 }));
            controls.push(this._createButton('btnRefresh', 'Refresh', 'outline', { row: 0, col: 3, colSpan: 2 }));

        } else {
            // Item/Edit views: individual controls per property
            let row = 0;

            visibleProperties.forEach(prop => {
                const controlMapping = CONTROL_MAP[prop.k2Type] || CONTROL_MAP['Text'];
                const isEditable = viewKey === 'edit' && controlMapping.editable && !prop.isReadOnly;

                controls.push({
                    id: `ctrl-${prop.name.toLowerCase()}-${viewGuid.slice(0, 4)}`,
                    name: prop.name,
                    displayName: prop.displayName,
                    controlType: isEditable ? controlMapping.control : 'Label',
                    controlTypeId: isEditable ? controlMapping.controlTypeId : 'com.k2.smartforms.controls.label',
                    dataField: prop.name,
                    editable: isEditable,
                    required: prop.isRequired,
                    format: controlMapping.format || null,
                    position: { row, col: 1, colSpan: 6 }
                });

                // Add label for the control
                controls.push({
                    id: `lbl-${prop.name.toLowerCase()}-${viewGuid.slice(0, 4)}`,
                    name: `lbl_${prop.name}`,
                    displayName: prop.displayName,
                    controlType: 'Label',
                    controlTypeId: 'com.k2.smartforms.controls.label',
                    dataField: null,
                    isLabel: true,
                    text: prop.displayName + (prop.isRequired ? ' *' : ''),
                    position: { row, col: 0, colSpan: 2 }
                });

                // Generate validation for editable required fields
                if (isEditable && prop.isRequired) {
                    validations.push({
                        controlName: prop.name,
                        type: 'required',
                        message: `${prop.displayName} is required`,
                        expression: `${prop.name} != null && ${prop.name} != ""`
                    });
                }

                // Generate format validation for specific types
                const valPattern = VALIDATION_PATTERNS[prop.k2Type];
                if (isEditable && valPattern) {
                    if (valPattern.maxLength) {
                        validations.push({
                            controlName: prop.name,
                            type: 'maxLength',
                            value: valPattern.maxLength,
                            message: `${prop.displayName} must be ${valPattern.maxLength} characters or less`
                        });
                    }
                    if (valPattern.pattern) {
                        validations.push({
                            controlName: prop.name,
                            type: 'format',
                            pattern: valPattern.pattern,
                            message: `${prop.displayName} has an invalid format`
                        });
                    }
                }

                row++;
            });

            // Add action buttons based on view type
            if (viewKey === 'item') {
                controls.push(this._createButton('btnEdit', 'Edit', 'primary', { row, col: 0, colSpan: 2 }));
                controls.push(this._createButton('btnDelete', 'Delete', 'danger', { row, col: 2, colSpan: 2 }));
                controls.push(this._createButton('btnBack', 'Back to List', 'outline', { row, col: 4, colSpan: 2 }));
            } else if (viewKey === 'edit') {
                controls.push(this._createButton('btnSave', 'Save', 'success', { row, col: 0, colSpan: 2 }));
                controls.push(this._createButton('btnCancel', 'Cancel', 'outline', { row, col: 2, colSpan: 2 }));
            }
        }

        // Generate rules from templates, mapping method names for SP Broker
        const brokerType = this._currentBrokerType || 'SmartBox';
        const rules = (RULE_TEMPLATES[viewKey] || []).map(template => {
            // Deep clone template to avoid mutating the constant
            const cloned = JSON.parse(JSON.stringify(template));

            // Map method names if using SharePoint 2013 Broker
            if (brokerType === 'SharePoint') {
                cloned.actions = cloned.actions.map(action => {
                    if (action.method && SP_BROKER_METHOD_MAP[action.method]) {
                        action.method = SP_BROKER_METHOD_MAP[action.method];
                    }
                    if (action.methodIfTrue && SP_BROKER_METHOD_MAP[action.methodIfTrue]) {
                        action.methodIfTrue = SP_BROKER_METHOD_MAP[action.methodIfTrue];
                    }
                    if (action.methodIfFalse && SP_BROKER_METHOD_MAP[action.methodIfFalse]) {
                        action.methodIfFalse = SP_BROKER_METHOD_MAP[action.methodIfFalse];
                    }
                    return action;
                });
            }

            return {
                id: `rule-${uuidv4().slice(0, 6)}`,
                ...cloned,
                viewName: viewTemplate.name,
                smartObjectMethod: cloned.actions.find(a => a.method)?.method || null
            };
        });

        return {
            id: `view-${viewGuid.slice(0, 8)}`,
            guid: viewGuid,
            name: viewTemplate.name,
            displayName: viewTemplate.displayName,
            type: viewTemplate.type,
            description: viewTemplate.description,
            boundMethod: viewTemplate.method,
            controls,
            rules,
            validations,
            layout: {
                columns: 12,
                rows: controls.reduce((max, c) => Math.max(max, (c.position?.row || 0) + 1), 0),
                theme: 'K2_Default',
                responsive: true
            }
        };
    }


    // ── Strategy A: Approval View Generation ────────────────

    /**
     * Generate the Approval View for Strategy A workflows
     * This view integrates with the K2 Worklist SmartObject to
     * signal the master workflow template
     */
    _generateApprovalView(so, tierClassification) {
        const viewGuid = uuidv4();
        const controls = [];
        const validations = [];
        let row = 0;

        // Section: Request Details (read-only display)
        controls.push({
            id: `ctrl-section-details-${viewGuid.slice(0, 4)}`,
            name: 'SectionHeader_Details',
            displayName: 'Request Details',
            controlType: 'Label',
            controlTypeId: 'com.k2.smartforms.controls.label',
            dataField: null,
            isLabel: true,
            isSectionHeader: true,
            text: 'Request Details',
            style: 'section-header',
            position: { row: row++, col: 0, colSpan: 12 }
        });

        // Display key properties as read-only labels
        const displayProperties = so.properties.filter(p =>
            !['CreatedBy', 'CreatedDate', 'ModifiedBy', 'ModifiedDate'].includes(p.name) &&
            p.name !== 'ID'
        ).slice(0, 8); // Show top 8 fields

        for (const prop of displayProperties) {
            controls.push({
                id: `lbl-${prop.name.toLowerCase()}-appr-${viewGuid.slice(0, 4)}`,
                name: `lbl_${prop.name}`,
                displayName: prop.displayName,
                controlType: 'Label',
                controlTypeId: 'com.k2.smartforms.controls.label',
                dataField: null,
                isLabel: true,
                text: prop.displayName,
                position: { row, col: 0, colSpan: 3 }
            });

            controls.push({
                id: `ctrl-${prop.name.toLowerCase()}-appr-${viewGuid.slice(0, 4)}`,
                name: prop.name,
                displayName: prop.displayName,
                controlType: 'Label', // Read-only in approval view
                controlTypeId: 'com.k2.smartforms.controls.label',
                boundProperty: prop.name,
                dataField: prop.name,
                dataType: prop.k2Type,
                editable: false,
                position: { row, col: 3, colSpan: 9 }
            });
            row++;
        }

        // Section: Workflow Status
        controls.push({
            id: `ctrl-section-status-${viewGuid.slice(0, 4)}`,
            name: 'SectionHeader_Status',
            displayName: 'Workflow Status',
            controlType: 'Label',
            controlTypeId: 'com.k2.smartforms.controls.label',
            dataField: null,
            isLabel: true,
            isSectionHeader: true,
            text: 'Workflow Status',
            style: 'section-header',
            position: { row: row++, col: 0, colSpan: 12 }
        });

        // Status display
        controls.push({
            id: `ctrl-status-display-${viewGuid.slice(0, 4)}`,
            name: 'StatusDisplay',
            displayName: 'Current Status',
            controlType: 'Label',
            controlTypeId: 'com.k2.smartforms.controls.label',
            dataField: 'Status',
            boundProperty: 'Status',
            editable: false,
            style: 'status-badge',
            position: { row, col: 0, colSpan: 4 }
        });

        // Current approver display
        controls.push({
            id: `ctrl-approver-display-${viewGuid.slice(0, 4)}`,
            name: 'CurrentApproverDisplay',
            displayName: 'Current Approver',
            controlType: 'Label',
            controlTypeId: 'com.k2.smartforms.controls.label',
            dataField: 'CurrentApprover',
            boundProperty: 'CurrentApprover',
            editable: false,
            position: { row: row++, col: 4, colSpan: 8 }
        });

        // Section: Approver Action
        controls.push({
            id: `ctrl-section-action-${viewGuid.slice(0, 4)}`,
            name: 'SectionHeader_Action',
            displayName: 'Your Decision',
            controlType: 'Label',
            controlTypeId: 'com.k2.smartforms.controls.label',
            dataField: null,
            isLabel: true,
            isSectionHeader: true,
            text: 'Your Decision',
            style: 'section-header',
            position: { row: row++, col: 0, colSpan: 12 }
        });

        // Comments textarea
        controls.push({
            id: `ctrl-comments-${viewGuid.slice(0, 4)}`,
            name: 'ApproverComments',
            displayName: 'Comments',
            controlType: 'TextArea',
            controlTypeId: 'com.k2.smartforms.controls.textarea',
            dataField: 'ApproverComments',
            boundProperty: 'ApproverComments',
            dataType: 'Memo',
            editable: true,
            required: false, // Required only on reject (enforced by rule)
            placeholder: 'Enter your comments (required for rejection)',
            position: { row: row++, col: 0, colSpan: 12 }
        });

        // Reassign target (hidden by default, shown when Reassign clicked)
        controls.push({
            id: `ctrl-reassign-${viewGuid.slice(0, 4)}`,
            name: 'ReassignTo',
            displayName: 'Reassign To',
            controlType: 'TextBox',
            controlTypeId: 'com.k2.smartforms.controls.textbox',
            dataField: 'ReassignTo',
            boundProperty: 'ReassignTo',
            dataType: 'Text',
            editable: true,
            required: false,
            placeholder: 'DOMAIN\\Username',
            visible: false,
            position: { row: row++, col: 0, colSpan: 6 }
        });

        // Action buttons
        controls.push(this._createButton('btnApprove', '✓ Approve', 'success', { row, col: 0, colSpan: 3 }));
        controls.push(this._createButton('btnReject', '✗ Reject', 'danger', { row, col: 3, colSpan: 3 }));
        controls.push(this._createButton('btnReassign', '↻ Reassign', 'outline', { row, col: 6, colSpan: 3 }));
        controls.push(this._createButton('btnBackToList', '← Back', 'outline', { row, col: 9, colSpan: 3 }));

        // Validation: Comments required on reject
        validations.push({
            controlName: 'ApproverComments',
            type: 'conditionalRequired',
            condition: 'OnReject',
            message: 'Comments are required when rejecting a request'
        });

        // Generate rules from approval templates
        const rules = APPROVAL_RULE_TEMPLATES.map(template => ({
            id: `rule-${uuidv4().slice(0, 6)}`,
            ...template,
            viewName: 'ApprovalView',
            smartObjectMethod: template.actions.find(a => a.method)?.method || null,
            worklistAction: template.actions.find(a => a.type === 'WorklistAction')?.action || null
        }));

        return {
            id: `view-${viewGuid.slice(0, 8)}`,
            guid: viewGuid,
            name: 'ApprovalView',
            displayName: 'Approval View',
            type: 'approval',
            description: VIEW_TYPES.approval.description,
            boundMethod: 'Read',
            controls,
            rules,
            validations,
            strategyA: {
                tierClassification: tierClassification?.tierLabel || null,
                migrationPath: tierClassification?.migrationPath || null,
                templateRequired: tierClassification?.templateRequired || 1,
                worklistIntegration: true
            },
            layout: {
                columns: 12,
                rows: row + 1,
                theme: 'K2_Default',
                responsive: true
            }
        };
    }


    // ── Internal: XML Generation ────────────────────────────

    /**
     * Generate K2 SmartForm XML definition
     */
    _generateFormXml(sf) {
        const viewsXml = sf.views.map(view => {
            const controlsXml = view.controls
                .filter(c => !c.isLabel)
                .map(c => {
                    if (c.controlType === 'DataGrid') {
                        const colsXml = (c.columns || []).map(col =>
                            `          <Column Name="${this._xmlEsc(col.name)}" DisplayName="${this._xmlEsc(col.displayName)}" Width="${col.width}" Sortable="${col.sortable}" Filterable="${col.filterable}"/>`
                        ).join('\n');
                        return `        <Control Type="DataGrid" Name="${this._xmlEsc(c.name)}" ID="${c.id}">\n          <Columns>\n${colsXml}\n          </Columns>\n        </Control>`;
                    }

                    const attrs = [
                        `Type="${this._xmlEsc(c.controlType)}"`,
                        `Name="${this._xmlEsc(c.name)}"`,
                        `ID="${c.id}"`,
                        c.dataField ? `DataField="${this._xmlEsc(c.dataField)}"` : '',
                        `Editable="${c.editable}"`,
                        c.required ? `Required="true"` : '',
                        c.format ? `Format="${this._xmlEsc(c.format)}"` : ''
                    ].filter(Boolean).join(' ');

                    return `        <Control ${attrs}/>`;
                }).join('\n');

            const rulesXml = view.rules.map(rule => {
                const actionsXml = rule.actions.map(a => {
                    if (a.type === 'ExecuteMethod') {
                        const soTarget = a.smartObject || sf.smartObjectName;
                        const inputXml = a.input
                            ? ` Input="${this._xmlEsc(JSON.stringify(a.input))}"`
                            : '';
                        return `            <Action Type="ExecuteMethod" SmartObject="${this._xmlEsc(soTarget)}" Method="${this._xmlEsc(a.method)}" TransferData="${a.transferData || 'all'}"${inputXml}/>`;
                    }
                    if (a.type === 'NavigateToView') {
                        return `            <Action Type="NavigateToView" TargetView="${this._xmlEsc(a.targetView)}" PassID="${a.passId}"/>`;
                    }
                    if (a.type === 'ConditionalMethod') {
                        return `            <Action Type="ConditionalMethod" Condition="${this._xmlEsc(a.condition)}" MethodIfTrue="${this._xmlEsc(a.methodIfTrue)}" MethodIfFalse="${this._xmlEsc(a.methodIfFalse)}"/>`;
                    }
                    if (a.type === 'WorklistAction') {
                        return `            <Action Type="WorklistAction" Action="${this._xmlEsc(a.action)}"${a.comment ? ` Comment="${this._xmlEsc(a.comment)}"` : ''}${a.target ? ` Target="${this._xmlEsc(a.target)}"` : ''}/>
            <!-- Strategy A: Signals the master workflow template via K2 Worklist SmartObject -->`;
                    }
                    if (a.type === 'StartWorkflow') {
                        const dfXml = a.dataFields
                            ? Object.entries(a.dataFields).map(([k, v]) =>
                                `              <DataField Name="${this._xmlEsc(k)}" Value="${this._xmlEsc(v)}"/>`
                              ).join('\n')
                            : '';
                        return `            <Action Type="StartWorkflow" Template="${this._xmlEsc(a.workflowTemplate)}">
              <!-- Strategy A: Start workflow with routing parameters -->
${dfXml}
            </Action>`;
                    }
                    return `            <Action Type="${this._xmlEsc(a.type)}"/>`;
                }).join('\n');

                const conditionsXml = rule.conditions.map(c => {
                    if (c.type === 'UserConfirm') {
                        return `            <Condition Type="UserConfirmation" Message="${this._xmlEsc(c.message)}"/>`;
                    }
                    if (c.type === 'Expression') {
                        return `            <Condition Type="Expression" Value="${this._xmlEsc(c.expression)}"/>`;
                    }
                    if (c.type === 'ValidateRequired') {
                        return `            <Condition Type="ValidateControls" Scope="Required"/>`;
                    }
                    return '';
                }).filter(Boolean).join('\n');

                return `        <Rule Name="${this._xmlEsc(rule.name)}" ID="${rule.id}">
          <Description>${this._xmlEsc(rule.description)}</Description>
          <Events><Event Type="${this._xmlEsc(rule.event)}"${rule.triggerControl ? ` Control="${this._xmlEsc(rule.triggerControl)}"` : ''}/></Events>
${conditionsXml ? `          <Conditions>\n${conditionsXml}\n          </Conditions>` : '          <Conditions/>'}
          <Actions>
${actionsXml}
          </Actions>
        </Rule>`;
            }).join('\n');

            const validationsXml = view.validations.map(v =>
                `        <Validation Control="${this._xmlEsc(v.controlName)}" Type="${this._xmlEsc(v.type)}" Message="${this._xmlEsc(v.message)}"${v.value ? ` Value="${v.value}"` : ''}${v.pattern ? ` Pattern="${this._xmlEsc(v.pattern)}"` : ''}/>`
            ).join('\n');

            return `    <View Name="${this._xmlEsc(view.name)}" ID="${view.id}" Type="${view.type}"
          BoundMethod="${this._xmlEsc(view.boundMethod)}" Theme="${view.layout.theme}"
          Columns="${view.layout.columns}" Responsive="${view.layout.responsive}">
      <Description>${this._xmlEsc(view.description)}</Description>
      <Controls>
${controlsXml}
      </Controls>
      <Rules>
${rulesXml}
      </Rules>
      <Validations>
${validationsXml}
      </Validations>
    </View>`;
        }).join('\n\n');

        return `<?xml version="1.0" encoding="utf-8"?>
<!--
  K2 SmartForm Definition
  Generated by: SPD → K2 Five Migration Pipeline (Phase 4)
  SmartObject: ${this._xmlEsc(sf.smartObjectName)} (${sf.metadata.sourceSmartObject})
  Source: ${this._xmlEsc(sf.metadata.sourceLegacySite)} → ${this._xmlEsc(sf.metadata.sourceLegacyList)}
  Target: K2 Five 5.8 FP26 (5.0009.1026.0)
  Generated: ${sf.generatedAt}
-->
<SourceCode.Forms xmlns="http://schemas.k2.com/smartforms/definition" version="1.0">
  <Form Name="${this._xmlEsc(sf.name)}" GUID="{${sf.guid}}"
        SmartObject="${this._xmlEsc(sf.smartObjectName)}"
        DisplayName="${this._xmlEsc(sf.displayName)}">

    <Metadata>
      <Source Platform="SharePoint SE 16.0.19725.20076"/>
      <Target Platform="K2 Five 5.8 FP26" Build="5.0009.1026.0"/>
      <Migration Batch="${this._xmlEsc(sf.metadata.sourceSmartObject)}"/>
    </Metadata>

    <Views>
${viewsXml}
    </Views>

  </Form>
</SourceCode.Forms>`;
    }


    // ── Internal: Helpers ───────────────────────────────────

    _createButton(name, label, style, position) {
        return {
            id: `ctrl-${name}-${uuidv4().slice(0, 4)}`,
            name,
            displayName: label,
            controlType: 'Button',
            controlTypeId: 'com.k2.smartforms.controls.button',
            dataField: null,
            editable: false,
            text: label,
            style,
            position
        };
    }

    _getColumnWidth(prop) {
        switch (prop.k2Type) {
            case 'Autonumber': return 60;
            case 'YesNo':     return 80;
            case 'DateTime':  return 140;
            case 'Number':    return 100;
            case 'Memo':      return 250;
            default:          return 180;
        }
    }

    _getDisplayFormat(prop) {
        switch (prop.k2Type) {
            case 'DateTime': return 'yyyy-MM-dd HH:mm';
            case 'Number':   return '#,##0.00';
            default:         return null;
        }
    }

    _getConfigSuggestion(prop) {
        switch (prop.spFieldType) {
            case 'Person or Group':
                return 'Configure K2 User Picker control and bind to K2 security provider';
            case 'Lookup':
                return 'Create separate SmartObject for lookup source and bind via cascading dropdown rule';
            case 'Calculated':
                return 'Implement as SmartForm Expression or computed SmartObject property';
            case 'Managed Metadata':
                return 'Map to cascading dropdown with taxonomy data source or free-text with validation';
            case 'Attachment':
                return 'Configure K2 Attachment control with file type restrictions and size limits';
            default:
                return 'Review and configure manually in K2 SmartForm Designer';
        }
    }

    _xmlEsc(str) {
        if (!str) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&apos;');
    }

    /**
     * Restore state from persisted JSON
     */
    _restoreFromState(sfArray) {
        this.smartForms.clear();
        for (const sf of sfArray) {
            this.smartForms.set(sf.id, sf);
        }
        this.lastGenerationTimestamp = sfArray[0]?.generatedAt || null;
        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: `Restored ${sfArray.length} SmartForms from saved state`
        });
    }
}

module.exports = { SmartFormGenerator };
