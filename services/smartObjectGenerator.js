// ============================================================
// SPD → K2 Five Migration Pipeline — SmartObject Generator
// Phase 3: Generates K2 SmartObject SODX definitions from
// analyzed SharePoint list/form inventory
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// API: SourceCode.SmartObjects.Authoring (via deployment bridge)
// ============================================================

const { v4: uuidv4 } = require('uuid');

// ── K2 SmartObject Property Type Map ────────────────────────

const K2_PROPERTY_TYPES = {
    'Single Line Text':     { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' },
    'Multiple Lines Plain': { k2Type: 'Memo',       soType: 'System.String',   sqlType: 'NVARCHAR(MAX)' },
    'Multiple Lines Rich':  { k2Type: 'Memo',       soType: 'System.String',   sqlType: 'NVARCHAR(MAX)' },
    'Choice Dropdown':      { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' },
    'Choice Radio':         { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' },
    'MultiChoice':          { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(500)' },
    'Number':               { k2Type: 'Number',     soType: 'System.Decimal',  sqlType: 'DECIMAL(18,4)' },
    'Currency':             { k2Type: 'Number',     soType: 'System.Decimal',  sqlType: 'DECIMAL(18,2)' },
    'Date/Time':            { k2Type: 'DateTime',   soType: 'System.DateTime', sqlType: 'DATETIME2(7)' },
    'Yes/No':               { k2Type: 'YesNo',      soType: 'System.Boolean',  sqlType: 'BIT' },
    'Person or Group':      { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' },
    'Lookup':               { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' },
    'Calculated':           { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(500)' },
    'Managed Metadata':     { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' },
    'Hyperlink':            { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(500)' },
    'Attachment':           { k2Type: 'File',       soType: 'System.Byte[]',   sqlType: 'VARBINARY(MAX)' },
    'External Data BCS':    { k2Type: 'Text',       soType: 'System.String',   sqlType: 'NVARCHAR(255)' }
};

// SP field type distribution templates based on form complexity
const FIELD_TYPE_DISTRIBUTIONS = {
    simple: [
        'Single Line Text', 'Single Line Text', 'Choice Dropdown',
        'Date/Time', 'Yes/No', 'Number', 'Single Line Text', 'Attachment'
    ],
    medium: [
        'Single Line Text', 'Single Line Text', 'Multiple Lines Plain',
        'Choice Dropdown', 'Choice Radio', 'Date/Time', 'Date/Time',
        'Person or Group', 'Number', 'Currency', 'Yes/No',
        'Lookup', 'Single Line Text', 'Attachment', 'Multiple Lines Rich'
    ],
    complex: [
        'Single Line Text', 'Single Line Text', 'Single Line Text',
        'Multiple Lines Plain', 'Multiple Lines Rich', 'Choice Dropdown',
        'Choice Dropdown', 'Choice Radio', 'MultiChoice', 'Date/Time',
        'Date/Time', 'Date/Time', 'Person or Group', 'Person or Group',
        'Number', 'Number', 'Currency', 'Yes/No', 'Yes/No',
        'Lookup', 'Lookup', 'Calculated', 'Managed Metadata',
        'Hyperlink', 'Attachment', 'Single Line Text'
    ],
    critical: [
        'Single Line Text', 'Single Line Text', 'Single Line Text',
        'Single Line Text', 'Multiple Lines Plain', 'Multiple Lines Plain',
        'Multiple Lines Rich', 'Choice Dropdown', 'Choice Dropdown',
        'Choice Dropdown', 'Choice Radio', 'MultiChoice', 'MultiChoice',
        'Date/Time', 'Date/Time', 'Date/Time', 'Date/Time',
        'Person or Group', 'Person or Group', 'Person or Group',
        'Number', 'Number', 'Number', 'Currency', 'Currency',
        'Yes/No', 'Yes/No', 'Yes/No',
        'Lookup', 'Lookup', 'Lookup', 'Calculated', 'Calculated',
        'Managed Metadata', 'Managed Metadata', 'Hyperlink',
        'External Data BCS', 'Attachment', 'Attachment'
    ]
};

// Common field name generators by type
const FIELD_NAME_TEMPLATES = {
    'Single Line Text':     ['Title', 'Name', 'Subject', 'Reference', 'Code', 'Label', 'Summary', 'Category'],
    'Multiple Lines Plain': ['Description', 'Notes', 'Comments', 'Details', 'Instructions'],
    'Multiple Lines Rich':  ['RichDescription', 'Body', 'Content', 'FormattedNotes'],
    'Choice Dropdown':      ['Status', 'Priority', 'Department', 'Type', 'Region', 'Level'],
    'Choice Radio':         ['ApprovalOutcome', 'Classification', 'Rating'],
    'MultiChoice':          ['Tags', 'SelectedOptions', 'ApplicableRegions'],
    'Number':               ['Quantity', 'Amount', 'Count', 'Score', 'Rank'],
    'Currency':             ['TotalCost', 'Budget', 'EstimatedValue', 'ActualCost'],
    'Date/Time':            ['RequestDate', 'DueDate', 'CompletedDate', 'EffectiveDate', 'ExpiryDate'],
    'Yes/No':               ['IsActive', 'IsApproved', 'RequiresReview', 'IsUrgent', 'IsCompleted'],
    'Person or Group':      ['RequestedBy', 'AssignedTo', 'ApprovedBy', 'Manager'],
    'Lookup':               ['RelatedItem', 'ParentRecord', 'LinkedDepartment'],
    'Calculated':           ['DaysRemaining', 'FullName', 'TotalWithTax'],
    'Managed Metadata':     ['BusinessUnit', 'DocumentType', 'TaxonomyTag'],
    'Hyperlink':            ['ReferenceLink', 'DocumentUrl', 'ExternalLink'],
    'Attachment':           ['PrimaryAttachment', 'SupportingDoc'],
    'External Data BCS':    ['ExternalRef', 'LegacySystemId']
};


// SP TypeAsString → our K2_PROPERTY_TYPES key mapping
const SP_TYPE_LOOKUP = {
    'Text':            'Single Line Text',
    'Note':            'Multiple Lines Plain',
    'Choice':          'Choice Dropdown',
    'MultiChoice':     'MultiChoice',
    'Number':          'Number',
    'Currency':        'Currency',
    'DateTime':        'Date/Time',
    'Boolean':         'Yes/No',
    'User':            'Person or Group',
    'UserMulti':       'Person or Group',
    'Lookup':          'Lookup',
    'LookupMulti':     'Lookup',
    'Calculated':      'Calculated',
    'URL':             'Hyperlink',
    'Attachments':     'Attachment',
    'TaxonomyFieldType':       'Managed Metadata',
    'TaxonomyFieldTypeMulti':  'Managed Metadata',
    'ContentTypeId':   'Single Line Text',
    'Counter':         'Number',
    'Integer':         'Number',
    'Guid':            'Single Line Text'
};


class SmartObjectGenerator {

    constructor() {
        this.smartObjects = new Map();  // id → SmartObject definition
        this.generationLog = [];
        this.lastGenerationTimestamp = null;
        this.realSchema = null;  // from Export-SPListSchema.ps1
    }

    /**
     * Set real SP list schema from PowerShell export
     */
    setRealSchema(schema) {
        this.realSchema = schema;
        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: `Real SP schema loaded: ${schema.listCount} lists, ${schema.totalFields} fields from ${schema.siteUrl}`
        });
    }

    /**
     * Generate SmartObject definitions from analyzed inventory
     * Groups by unique list (WebUrl + ListTitle) and generates one SO per list
     * @param {Array} analysisResults - Results from AnalysisEngine
     * @returns {Object} Generation summary
     */
    generate(analysisResults) {
        this.smartObjects.clear();
        this.generationLog = [];

        // Group analysis results by unique list
        const listGroups = this._groupByList(analysisResults);

        let generated = 0;
        let errors = 0;

        for (const [listKey, items] of listGroups.entries()) {
            try {
                const so = this._generateSmartObject(listKey, items);
                this.smartObjects.set(so.id, so);
                generated++;
                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'info',
                    smartObjectId: so.id,
                    message: `Generated SmartObject "${so.name}" with ${so.properties.length} properties and ${so.methods.length} methods`
                });
            } catch (err) {
                errors++;
                this.generationLog.push({
                    timestamp: new Date().toISOString(),
                    level: 'error',
                    listKey,
                    message: `Failed to generate: ${err.message}`
                });
            }
        }

        this.lastGenerationTimestamp = new Date().toISOString();

        return {
            generated,
            errors,
            totalLists: listGroups.size,
            totalProperties: Array.from(this.smartObjects.values()).reduce((sum, so) => sum + so.properties.length, 0),
            totalMethods: Array.from(this.smartObjects.values()).reduce((sum, so) => sum + so.methods.length, 0),
            timestamp: this.lastGenerationTimestamp
        };
    }

    /**
     * Get all generated SmartObjects
     */
    getAll() {
        return Array.from(this.smartObjects.values()).map(so => ({
            id: so.id,
            name: so.name,
            displayName: so.displayName,
            listTitle: so.listTitle,
            webUrl: so.webUrl,
            propertyCount: so.properties.length,
            methodCount: so.methods.length,
            complexity: so.complexity,
            deploymentStatus: so.deploymentStatus,
            hasBlockedFields: so.properties.some(p => p.autoMap === 'blocked'),
            serviceBroker: so.serviceBroker,
            generatedAt: so.generatedAt
        }));
    }

    /**
     * Get single SmartObject detail with full definition
     */
    getById(id) {
        return this.smartObjects.get(id) || null;
    }

    /**
     * Get SmartObject SODX XML definition
     */
    getXml(id) {
        const so = this.smartObjects.get(id);
        if (!so) return null;
        return this._generateSODX(so);
    }

    /**
     * Get SQL DDL for the backing table
     */
    getSql(id) {
        const so = this.smartObjects.get(id);
        if (!so) return null;
        return this._generateSQL(so);
    }

    /**
     * Update deployment status
     */
    updateDeploymentStatus(id, status, details = {}) {
        const so = this.smartObjects.get(id);
        if (!so) return false;

        so.deploymentStatus = status;
        so.deploymentDetails = {
            ...so.deploymentDetails,
            ...details,
            lastUpdated: new Date().toISOString()
        };

        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: status === 'failed' ? 'error' : 'info',
            smartObjectId: id,
            message: `Deployment status → ${status}${details.error ? ': ' + details.error : ''}`
        });

        return true;
    }

    /**
     * Get generation log
     */
    getLog() {
        return this.generationLog;
    }

    /**
     * Get generation stats summary
     */
    getStats() {
        const all = Array.from(this.smartObjects.values());
        const deployed = all.filter(s => s.deploymentStatus === 'deployed').length;
        const pending = all.filter(s => s.deploymentStatus === 'pending').length;
        const failed = all.filter(s => s.deploymentStatus === 'failed').length;
        const deploying = all.filter(s => s.deploymentStatus === 'deploying').length;

        return {
            total: all.length,
            deployed,
            pending,
            failed,
            deploying,
            totalProperties: all.reduce((s, o) => s + o.properties.length, 0),
            totalMethods: all.reduce((s, o) => s + o.methods.length, 0),
            blockedFields: all.reduce((s, o) => s + o.properties.filter(p => p.autoMap === 'blocked').length, 0),
            lastGeneration: this.lastGenerationTimestamp
        };
    }


    // ── Internal: Generation Logic ──────────────────────────

    /**
     * Group analysis results by unique list
     * Each unique (WebUrl, ListTitle) becomes one SmartObject
     */
    _groupByList(results) {
        const groups = new Map();
        for (const item of results) {
            const key = `${item.webUrl}|||${item.listTitle}`;
            if (!groups.has(key)) groups.set(key, []);
            groups.get(key).push(item);
        }
        return groups;
    }

    /**
     * Generate a SmartObject definition for a given list group
     */
    _generateSmartObject(listKey, items) {
        const [webUrl, listTitle] = listKey.split('|||');
        const soName = this._sanitizeName(listTitle);
        const soGuid = uuidv4();

        // Determine complexity from highest-complexity item in the group
        const complexityOrder = { simple: 0, medium: 1, complex: 2, critical: 3 };
        const maxComplexity = items.reduce((max, item) => {
            return (complexityOrder[item.complexity] || 0) > (complexityOrder[max] || 0)
                ? item.complexity : max;
        }, 'simple');

        // Generate properties from form field analysis
        const properties = this._generateProperties(items, maxComplexity);

        // Generate standard CRUD methods
        const methods = this._generateMethods(properties);

        return {
            id: `so-${soGuid.slice(0, 8)}`,
            guid: soGuid,
            name: soName,
            displayName: listTitle,
            listTitle,
            webUrl,
            complexity: maxComplexity,
            sourceItems: items.map(i => ({ id: i.id, name: i.name, type: i.assetType })),
            properties,
            methods,
            serviceBroker: 'SQL Server Service Broker',
            serviceInstance: `K2_PROD_${soName}`,
            backingTable: `K2_Migration.dbo.${soName}`,
            deploymentStatus: 'pending',
            deploymentDetails: {},
            generatedAt: new Date().toISOString(),
            metadata: {
                sourceSystem: 'SharePoint SE 16.0.19725.20076',
                targetSystem: 'K2 Five 5.8 FP26',
                migrationBatch: `batch-${Date.now()}`
            }
        };
    }

    /**
     * Generate properties for a SmartObject based on form data
     */
    _generateProperties(items, complexity) {
        // Try real schema first
        const listTitle = items[0]?.listTitle;
        if (this.realSchema && listTitle) {
            const realList = this.realSchema.lists.find(l =>
                l.listTitle === listTitle || l.listTitle.toLowerCase() === listTitle.toLowerCase()
            );
            if (realList && realList.fields && realList.fields.length > 0) {
                return this._generatePropertiesFromRealSchema(realList);
            }
        }

        // Fallback to inferred generation
        return this._generatePropertiesInferred(items, complexity);
    }

    /**
     * Generate properties from REAL SP list schema (PowerShell export)
     */
    _generatePropertiesFromRealSchema(listData) {
        const properties = [];
        const usedNames = new Set();

        // ID property
        properties.push({
            name: 'ID', displayName: 'ID', k2Type: 'Autonumber', soType: 'System.Int32',
            sqlType: 'INT IDENTITY(1,1)', spFieldType: 'ID', autoMap: 'direct',
            isKey: true, isRequired: true, isReadOnly: true,
            notes: 'Primary key', source: 'real'
        });
        usedNames.add('ID');

        for (const field of listData.fields) {
            const fieldName = this._sanitizeName(field.name || field.displayName);
            if (usedNames.has(fieldName) || !fieldName) continue;
            usedNames.add(fieldName);

            // Map real SP type to K2 type
            const spTypeKey = SP_TYPE_LOOKUP[field.typeAsString] || SP_TYPE_LOOKUP[field.spFieldType] || 'Single Line Text';
            const typeMapping = K2_PROPERTY_TYPES[spTypeKey] || K2_PROPERTY_TYPES['Single Line Text'];

            const isBlockedType = spTypeKey === 'External Data BCS';
            properties.push({
                name: fieldName,
                displayName: field.displayName || this._formatDisplayName(fieldName),
                k2Type: typeMapping.k2Type,
                soType: typeMapping.soType,
                sqlType: typeMapping.sqlType,
                spFieldType: field.spFieldType || field.typeAsString || spTypeKey,
                autoMap: isBlockedType ? 'blocked' : (
                    ['Person or Group', 'Lookup', 'Calculated', 'Managed Metadata', 'Attachment'].includes(spTypeKey)
                        ? 'config' : 'direct'
                ),
                isKey: false,
                isRequired: !!field.required,
                isReadOnly: spTypeKey === 'Calculated',
                notes: field.description || '',
                source: 'real',
                choices: field.choices || []
            });
        }

        // Audit fields
        ['CreatedBy', 'CreatedDate', 'ModifiedBy', 'ModifiedDate'].forEach(name => {
            if (!usedNames.has(name)) {
                const isDate = name.includes('Date');
                properties.push({
                    name, displayName: this._formatDisplayName(name),
                    k2Type: isDate ? 'DateTime' : 'Text',
                    soType: isDate ? 'System.DateTime' : 'System.String',
                    sqlType: isDate ? 'DATETIME2(7)' : 'NVARCHAR(255)',
                    spFieldType: 'System', autoMap: 'direct',
                    isKey: false, isRequired: false, isReadOnly: true,
                    notes: 'Audit trail', source: 'real'
                });
            }
        });

        return properties;
    }

    /**
     * Generate properties using inference (fallback when no real schema)
     */
    _generatePropertiesInferred(items, complexity) {
        const properties = [];
        const usedNames = new Set();

        // Always add the system ID property first
        properties.push({
            name: 'ID', displayName: 'ID', k2Type: 'Autonumber', soType: 'System.Int32',
            sqlType: 'INT IDENTITY(1,1)', spFieldType: 'ID', autoMap: 'direct',
            isKey: true, isRequired: true, isReadOnly: true,
            notes: 'Primary key — auto-generated', source: 'inferred'
        });
        usedNames.add('ID');

        const maxFieldCount = items.reduce((max, item) => Math.max(max, item.fieldCount || 0), 0);
        const targetFieldCount = Math.max(maxFieldCount, 5);
        const distribution = FIELD_TYPE_DISTRIBUTIONS[complexity] || FIELD_TYPE_DISTRIBUTIONS.simple;
        const fieldCount = Math.min(targetFieldCount, distribution.length + 5);

        for (let i = 0; i < fieldCount && i < distribution.length; i++) {
            const spType = distribution[i % distribution.length];
            const typeMapping = K2_PROPERTY_TYPES[spType];
            if (!typeMapping) continue;

            const nameTemplates = FIELD_NAME_TEMPLATES[spType] || ['Field'];
            let fieldName = nameTemplates[0];
            let nameIdx = 0;
            while (usedNames.has(fieldName)) {
                nameIdx++;
                fieldName = nameIdx < nameTemplates.length
                    ? nameTemplates[nameIdx]
                    : `${nameTemplates[0]}_${nameIdx - nameTemplates.length + 2}`;
            }
            usedNames.add(fieldName);

            const isBlockedType = spType === 'External Data BCS';
            properties.push({
                name: fieldName, displayName: this._formatDisplayName(fieldName),
                k2Type: typeMapping.k2Type, soType: typeMapping.soType, sqlType: typeMapping.sqlType,
                spFieldType: spType,
                autoMap: isBlockedType ? 'blocked' : (
                    ['Person or Group', 'Lookup', 'Calculated', 'Managed Metadata', 'Attachment'].includes(spType)
                        ? 'config' : 'direct'
                ),
                isKey: false, isRequired: i < 2, isReadOnly: spType === 'Calculated',
                notes: isBlockedType ? 'Requires custom REST Service Broker' : '',
                source: 'inferred'
            });
        }

        // Audit fields
        const auditFields = [
            { name: 'CreatedBy', displayName: 'Created By', k2Type: 'Text', soType: 'System.String', sqlType: 'NVARCHAR(255)', spFieldType: 'System', autoMap: 'direct', isKey: false, isRequired: false, isReadOnly: true, notes: 'Audit trail', source: 'inferred' },
            { name: 'CreatedDate', displayName: 'Created Date', k2Type: 'DateTime', soType: 'System.DateTime', sqlType: 'DATETIME2(7)', spFieldType: 'System', autoMap: 'direct', isKey: false, isRequired: false, isReadOnly: true, notes: 'Audit trail', source: 'inferred' },
            { name: 'ModifiedBy', displayName: 'Modified By', k2Type: 'Text', soType: 'System.String', sqlType: 'NVARCHAR(255)', spFieldType: 'System', autoMap: 'direct', isKey: false, isRequired: false, isReadOnly: true, notes: 'Audit trail', source: 'inferred' },
            { name: 'ModifiedDate', displayName: 'Modified Date', k2Type: 'DateTime', soType: 'System.DateTime', sqlType: 'DATETIME2(7)', spFieldType: 'System', autoMap: 'direct', isKey: false, isRequired: false, isReadOnly: true, notes: 'Audit trail', source: 'inferred' }
        ];
        auditFields.forEach(f => { if (!usedNames.has(f.name)) { properties.push(f); usedNames.add(f.name); } });

        return properties;
    }

    /**
     * Generate standard CRUD methods for a SmartObject
     */
    _generateMethods(properties) {
        const inputProps = properties.filter(p => !p.isReadOnly && !p.isKey);
        const allOutputProps = properties;
        const keyProp = properties.find(p => p.isKey) || properties[0];

        return [
            {
                name: 'Create',
                displayName: 'Create',
                type: 'create',
                description: 'Create a new record',
                inputProperties: inputProps.map(p => p.name),
                requiredProperties: inputProps.filter(p => p.isRequired).map(p => p.name),
                returnProperties: [keyProp.name],
                parameters: []
            },
            {
                name: 'Read',
                displayName: 'Read',
                type: 'read',
                description: 'Read a single record by ID',
                inputProperties: [keyProp.name],
                requiredProperties: [keyProp.name],
                returnProperties: allOutputProps.map(p => p.name),
                parameters: []
            },
            {
                name: 'GetList',
                displayName: 'Get List',
                type: 'list',
                description: 'Retrieve all records (optionally filtered)',
                inputProperties: inputProps.slice(0, 5).map(p => p.name),  // First 5 as optional filters
                requiredProperties: [],
                returnProperties: allOutputProps.map(p => p.name),
                parameters: []
            },
            {
                name: 'Update',
                displayName: 'Update',
                type: 'update',
                description: 'Update an existing record',
                inputProperties: [keyProp.name, ...inputProps.map(p => p.name)],
                requiredProperties: [keyProp.name],
                returnProperties: [],
                parameters: []
            },
            {
                name: 'Delete',
                displayName: 'Delete',
                type: 'delete',
                description: 'Delete a record by ID',
                inputProperties: [keyProp.name],
                requiredProperties: [keyProp.name],
                returnProperties: [],
                parameters: []
            }
        ];
    }


    // ── Internal: Output Generators ─────────────────────────

    /**
     * Generate K2 SmartObject SODX XML
     */
    _generateSODX(so) {
        const xmlProps = so.properties.map(p => {
            const attrs = [
                `name="${this._xmlEsc(p.name)}"`,
                `type="${this._xmlEsc(p.k2Type)}"`,
                `extendedtype=""`,
                `so_type="${this._xmlEsc(p.soType)}"`
            ];
            if (p.isKey) attrs.push('iskey="true"');
            if (p.isRequired) attrs.push('required="true"');
            if (p.isReadOnly) attrs.push('readonly="true"');

            return `      <property ${attrs.join(' ')}>
        <metadata>
          <display name="${this._xmlEsc(p.displayName)}"/>
        </metadata>
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
  Generated by: SPD → K2 Five Migration Pipeline
  Source: SharePoint SE 16.0.19725.20076
  Target: K2 Five 5.8 FP26 (5.0009.1026.0)
  Database: K2_PROD | Listener: 75387P_LN01 | AG: 75387P-AG01
  Generated: ${so.generatedAt}
-->
<smartobjectroot xmlns="http://schemas.k2.com/smartobject/model" version="1.0">
  <smartobject name="${this._xmlEsc(so.name)}" guid="{${so.guid}}" version="0"
               metadata="Source: ${this._xmlEsc(so.webUrl)} | List: ${this._xmlEsc(so.listTitle)}">

    <metadata>
      <display name="${this._xmlEsc(so.displayName)}"/>
      <description>Migrated from SharePoint list: ${this._xmlEsc(so.listTitle)} at ${this._xmlEsc(so.webUrl)}</description>
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
     * Generate SQL DDL for the backing table
     */
    _generateSQL(so) {
        const columns = so.properties.map(p => {
            let colDef = `    [${p.name}] ${p.sqlType}`;
            if (p.isKey) colDef += ' PRIMARY KEY';
            if (p.isRequired && !p.isKey) colDef += ' NOT NULL';
            if (!p.isRequired && !p.isKey) colDef += ' NULL';
            return colDef;
        }).join(',\n');

        return `-- ============================================================
-- K2 SmartObject Backing Table: ${so.name}
-- Generated by: SPD → K2 Five Migration Pipeline
-- Source: ${so.webUrl} → ${so.listTitle}
-- Target: K2_PROD (75387P_LN01 / 75387P-AG01)
-- SQL Server 2019 CU32 (KB5068404)
-- ============================================================

USE [K2_PROD];
GO

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'K2_Migration')
    EXEC('CREATE SCHEMA [K2_Migration]');
GO

IF OBJECT_ID('K2_Migration.${so.name}', 'U') IS NOT NULL
    DROP TABLE [K2_Migration].[${so.name}];
GO

CREATE TABLE [K2_Migration].[${so.name}] (
${columns}
);
GO

-- Indexes
CREATE NONCLUSTERED INDEX [IX_${so.name}_CreatedDate]
    ON [K2_Migration].[${so.name}] ([CreatedDate] DESC)
    WHERE [CreatedDate] IS NOT NULL;
GO

PRINT 'Table K2_Migration.${so.name} created successfully with ${so.properties.length} columns.';
GO
`;
    }


    // ── Internal: Utilities ─────────────────────────────────

    _sanitizeName(name) {
        return name
            .replace(/[^a-zA-Z0-9_]/g, '_')
            .replace(/_+/g, '_')
            .replace(/^_|_$/g, '')
            .replace(/^\d/, 'SO_$&');
    }

    _formatDisplayName(name) {
        return name.replace(/([A-Z])/g, ' $1').replace(/^./, s => s.toUpperCase()).trim();
    }

    /**
     * Restore state from persisted JSON
     */
    _restoreFromState(soArray) {
        this.smartObjects.clear();
        for (const so of soArray) {
            this.smartObjects.set(so.id, so);
        }
        this.lastGenerationTimestamp = soArray[0]?.generatedAt || null;
        this.generationLog.push({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: `Restored ${soArray.length} SmartObjects from saved state`
        });
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
}

module.exports = { SmartObjectGenerator };
