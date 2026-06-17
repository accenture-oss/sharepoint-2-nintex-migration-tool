// ============================================================
// SPD → K2 Five Migration Pipeline — XSN Parser
// Extracts InfoPath form definitions from .xsn files (CAB archives)
//
// Parses:
//   - myschema.xsd → Field names, data types, nesting
//   - manifest.xsf → Data connections, submit rules, views
//   - template.xml → Default values
//
// Output: Structured JSON used by SmartObject + SmartForm generators
// ============================================================

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const xml2js = require('xml2js');
const { v4: uuidv4 } = require('uuid');

// XSD type → K2 SmartObject type mapping
const XSD_TO_K2_TYPE = {
    'xsd:string':        'Text',
    'xsd:normalizedString': 'Text',
    'xsd:token':         'Text',
    'string':            'Text',
    'xsd:integer':       'Number',
    'xsd:int':           'Number',
    'xsd:long':          'Number',
    'xsd:short':         'Number',
    'xsd:decimal':       'Number',
    'xsd:float':         'Number',
    'xsd:double':        'Number',
    'integer':           'Number',
    'xsd:boolean':       'YesNo',
    'boolean':           'YesNo',
    'xsd:date':          'DateTime',
    'xsd:dateTime':      'DateTime',
    'xsd:time':          'DateTime',
    'date':              'DateTime',
    'xsd:base64Binary':  'File',
    'xsd:anyURI':        'Text',
    'xsd:XHTML':         'Memo',
    'xhtml':             'Memo'
};

// XSD type → SmartForm control mapping
const XSD_TO_CONTROL = {
    'xsd:string':    'TextBox',
    'xsd:integer':   'TextBox',
    'xsd:decimal':   'TextBox',
    'xsd:boolean':   'CheckBox',
    'xsd:date':      'DatePicker',
    'xsd:dateTime':  'DatePicker',
    'xsd:base64Binary': 'Attachment',
    'xsd:XHTML':     'TextArea'
};


class XsnParser {

    constructor() {
        this.parsedForms = new Map();   // formId → parsed form definition
        this.parseLog = [];
        this.tempDir = path.join(require('os').tmpdir(), 'xsn_extract_' + Date.now());
    }

    /**
     * Parse a single XSN file
     * @param {string} xsnPath - Absolute path to .xsn file
     * @param {Object} metadata - Optional: { siteUrl, listTitle, webTitle }
     * @returns {Object} Parsed form definition
     */
    async parseXsn(xsnPath, metadata = {}) {
        const formId = `xsn-${uuidv4().slice(0, 8)}`;
        const extractDir = path.join(this.tempDir, formId);

        try {
            this._log('info', `Parsing XSN: ${path.basename(xsnPath)}`);

            // Step 1: Extract CAB archive using Windows expand command
            if (!fs.existsSync(extractDir)) {
                fs.mkdirSync(extractDir, { recursive: true });
            }

            try {
                execSync(`expand "${xsnPath}" -F:* "${extractDir}"`, {
                    timeout: 30000,
                    windowsHide: true,
                    stdio: 'pipe'
                });
            } catch (expandErr) {
                // Fallback: try PowerShell Expand-Archive (for ZIP-packaged XSN)
                try {
                    execSync(`powershell -ExecutionPolicy Bypass -Command "Expand-Archive -Path '${xsnPath}' -DestinationPath '${extractDir}' -Force"`, {
                        timeout: 30000,
                        windowsHide: true,
                        stdio: 'pipe'
                    });
                } catch (psErr) {
                    throw new Error(`Cannot extract XSN (not CAB or ZIP): ${expandErr.message}`);
                }
            }

            // Step 2: Find and parse the files
            const files = fs.readdirSync(extractDir);
            this._log('info', `  Extracted ${files.length} files: ${files.join(', ')}`);

            const result = {
                id: formId,
                xsnFile: path.basename(xsnPath),
                siteUrl: metadata.siteUrl || '',
                listTitle: metadata.listTitle || '',
                webTitle: metadata.webTitle || '',
                fields: [],
                views: [],
                dataConnections: [],
                submitRules: [],
                formName: '',
                formDescription: '',
                namespace: '',
                parsedAt: new Date().toISOString()
            };

            // Parse manifest.xsf (form metadata)
            const manifestFile = files.find(f => f.toLowerCase() === 'manifest.xsf');
            if (manifestFile) {
                const manifestResult = await this._parseManifest(
                    path.join(extractDir, manifestFile)
                );
                Object.assign(result, manifestResult);
            }

            // Parse XSD schema (field definitions) — may be named myschema.xsd or *.xsd
            const xsdFile = files.find(f => f.toLowerCase().endsWith('.xsd'));
            if (xsdFile) {
                const fields = await this._parseXsd(path.join(extractDir, xsdFile));
                result.fields = fields;
                this._log('info', `  Found ${fields.length} fields from schema`);
            }

            // Parse template.xml (default values)
            const templateFile = files.find(f => f.toLowerCase() === 'template.xml');
            if (templateFile) {
                const defaults = await this._parseTemplate(
                    path.join(extractDir, templateFile), result.fields
                );
                // Merge defaults into fields
                for (const field of result.fields) {
                    if (defaults[field.name] !== undefined) {
                        field.defaultValue = defaults[field.name];
                    }
                }
            }

            // Store parsed form
            this.parsedForms.set(formId, result);
            this._log('info', `  ✓ Parsed: ${result.formName || xsnPath} — ${result.fields.length} fields, ${result.views.length} views`);

            return result;

        } catch (err) {
            this._log('error', `Failed to parse ${xsnPath}: ${err.message}`);
            throw err;
        } finally {
            // Cleanup temp files
            try {
                if (fs.existsSync(extractDir)) {
                    fs.rmSync(extractDir, { recursive: true, force: true });
                }
            } catch (e) { /* cleanup failure is non-fatal */ }
        }
    }

    /**
     * Parse a batch of XSN files from a directory or ZIP
     * @param {string} inputPath - Directory containing XSN files, or a ZIP archive
     * @returns {Object} { parsed: count, errors: count, forms: [] }
     */
    async parseBatch(inputPath) {
        const stats = { parsed: 0, errors: 0, forms: [] };

        if (!fs.existsSync(inputPath)) {
            throw new Error(`Input path not found: ${inputPath}`);
        }

        let xsnDir = inputPath;

        // If ZIP, extract first
        if (inputPath.endsWith('.zip')) {
            xsnDir = path.join(this.tempDir, 'batch');
            fs.mkdirSync(xsnDir, { recursive: true });
            execSync(`powershell -ExecutionPolicy Bypass -Command "Expand-Archive -Path '${inputPath}' -DestinationPath '${xsnDir}' -Force"`, {
                timeout: 120000, windowsHide: true, stdio: 'pipe'
            });
        }

        // Find all XSN files recursively
        const xsnFiles = this._findFiles(xsnDir, '.xsn');
        this._log('info', `Found ${xsnFiles.length} XSN files to parse`);

        for (const xsnPath of xsnFiles) {
            try {
                // Extract metadata from directory structure (sites/hr/LeaveRequests/file.xsn)
                const relativePath = path.relative(xsnDir, xsnPath);
                const parts = relativePath.split(path.sep);
                const metadata = this._inferMetadata(parts, xsnPath);

                const form = await this.parseXsn(xsnPath, metadata);
                stats.forms.push(form);
                stats.parsed++;
            } catch (err) {
                stats.errors++;
                this._log('error', `  ✗ ${path.basename(xsnPath)}: ${err.message}`);
            }
        }

        this._log('info', `Batch complete: ${stats.parsed} parsed, ${stats.errors} errors`);
        return stats;
    }

    /**
     * Get parsed forms as SmartObject input format
     * Produces the exact input the SmartObjectGenerator needs
     */
    toSmartObjectInput() {
        return Array.from(this.parsedForms.values()).map(form => ({
            name: (form.formName || form.xsnFile.replace('.xsn', '')).replace(/[^a-zA-Z0-9_]/g, '_'),
            displayName: form.formName || form.xsnFile.replace('.xsn', ''),
            listTitle: form.listTitle,
            webUrl: form.siteUrl,
            properties: form.fields.map(f => ({
                name: f.name,
                displayName: f.displayName || f.name,
                k2Type: f.k2Type,
                soType: f.k2Type,
                spFieldType: f.xsdType,
                isRequired: f.required || false,
                isReadOnly: false,
                defaultValue: f.defaultValue || null,
                choices: f.choices || null,
                maxLength: f.maxLength || null
            })),
            source: 'xsn',
            xsnFormId: form.id
        }));
    }

    /**
     * Get all parsed forms
     */
    getAll() {
        return Array.from(this.parsedForms.values());
    }

    /**
     * Get parsed form by ID
     */
    getById(id) {
        return this.parsedForms.get(id) || null;
    }

    /**
     * Get parse log
     */
    getLog() {
        return this.parseLog;
    }

    /**
     * Clear all parsed forms
     */
    clear() {
        this.parsedForms.clear();
        this.parseLog = [];
    }


    // ── Internal: Parse Manifest ────────────────────────────

    async _parseManifest(filePath) {
        const xml = fs.readFileSync(filePath, 'utf-8');
        const parsed = await xml2js.parseStringPromise(xml, {
            explicitArray: false,
            mergeAttrs: true,
            tagNameProcessors: [xml2js.processors.stripPrefix]
        });

        const result = {
            formName: '',
            formDescription: '',
            namespace: '',
            views: [],
            dataConnections: [],
            submitRules: []
        };

        try {
            const xdoc = parsed.xDocumentClass || parsed.formTemplate || {};
            result.formName = xdoc.name || xdoc.title || '';
            result.formDescription = xdoc.description || '';
            result.namespace = xdoc.solutionVersion || '';

            // Parse views
            const viewsNode = xdoc.views || xdoc.Views || {};
            const viewList = viewsNode.view || viewsNode.View || [];
            const views = Array.isArray(viewList) ? viewList : (viewList ? [viewList] : []);
            result.views = views.map((v, i) => ({
                name: v.name || v.Name || `View ${i + 1}`,
                caption: v.caption || v.Caption || '',
                fileName: v.filename || v.fileName || ''
            }));

            // Parse data connections
            const dcNode = xdoc.dataConnections || xdoc.DataConnections || {};
            const dcList = dcNode.dataConnection || dcNode.DataConnection || [];
            const dcs = Array.isArray(dcList) ? dcList : (dcList ? [dcList] : []);
            result.dataConnections = dcs.map(dc => ({
                name: dc.name || dc.Name || '',
                type: dc.initOnLoad ? 'query' : 'submit',
                initOnLoad: dc.initOnLoad === 'yes'
            }));

            // Parse submit settings
            const submitNode = xdoc.submit || xdoc.Submit || {};
            if (submitNode.useHttpHandler || submitNode.submitAction) {
                result.submitRules.push({
                    action: 'submit',
                    type: submitNode.showSignatureReminder ? 'signed' : 'standard'
                });
            }
        } catch (e) {
            this._log('warn', `  Manifest parse partial: ${e.message}`);
        }

        return result;
    }


    // ── Internal: Parse XSD Schema ──────────────────────────

    async _parseXsd(filePath) {
        const xml = fs.readFileSync(filePath, 'utf-8');
        const parsed = await xml2js.parseStringPromise(xml, {
            explicitArray: false,
            mergeAttrs: true,
            tagNameProcessors: [xml2js.processors.stripPrefix]
        });

        const fields = [];
        this._extractFieldsFromSchema(parsed, fields, '');
        return fields;
    }

    _extractFieldsFromSchema(node, fields, parentPath) {
        if (!node || typeof node !== 'object') return;

        // Handle xsd:element
        if (node.element) {
            const elements = Array.isArray(node.element) ? node.element : [node.element];
            for (const el of elements) {
                if (!el || !el.name) continue;

                // Skip InfoPath internal namespace prefix fields
                if (el.name.startsWith('_')) continue;

                const fieldName = el.name;

                // Check for nested complex type (group/section or root myFields)
                const complexType = el.complexType || el.ComplexType;
                if (complexType) {
                    // Root element (myFields, my, etc.) or a section group — recurse into it
                    const seq = complexType.sequence || complexType.Sequence || complexType.all || complexType;
                    this._extractFieldsFromSchema(seq, fields, 
                        (fieldName === 'myFields' || fieldName === 'my') ? '' : (parentPath ? `${parentPath}.${fieldName}` : fieldName)
                    );
                    continue;
                }

                const xsdType = el.type || this._inferTypeFromElement(el);
                const k2Type = XSD_TO_K2_TYPE[xsdType] || 'Text';

                // Check for restrictions (choices, maxLength)
                const restriction = this._findRestriction(el);
                const choices = restriction?.enumerations || null;
                const maxLength = restriction?.maxLength || null;

                // Check if it's a repeating group (maxOccurs > 1)
                const isRepeating = el.maxOccurs === 'unbounded' || parseInt(el.maxOccurs) > 1;

                fields.push({
                    name: fieldName,
                    displayName: this._toDisplayName(fieldName),
                    path: parentPath ? `${parentPath}.${fieldName}` : fieldName,
                    xsdType: xsdType,
                    k2Type: k2Type,
                    controlType: XSD_TO_CONTROL[xsdType] || 'TextBox',
                    required: el.minOccurs === '1' || el.use === 'required',
                    choices: choices,
                    maxLength: maxLength,
                    isRepeating: isRepeating || false,
                    defaultValue: el.default || null,
                    nillable: el.nillable === 'true'
                });
            }
        }

        // Handle xsd:sequence, xsd:all, xsd:complexType
        for (const key of ['sequence', 'Sequence', 'all', 'All', 'complexType', 'ComplexType', 'schema', 'Schema']) {
            if (node[key]) {
                this._extractFieldsFromSchema(node[key], fields, parentPath);
            }
        }
    }

    _inferTypeFromElement(el) {
        // If element has inline simpleType with restriction
        const simpleType = el.simpleType || el.SimpleType;
        if (simpleType) {
            const restriction = simpleType.restriction || simpleType.Restriction;
            if (restriction && restriction.base) {
                return restriction.base;
            }
        }
        // Default to string
        return 'xsd:string';
    }

    _findRestriction(el) {
        const simpleType = el.simpleType || el.SimpleType;
        if (!simpleType) return null;

        const restriction = simpleType.restriction || simpleType.Restriction;
        if (!restriction) return null;

        const result = {};

        // Enumerations (choice values)
        const enums = restriction.enumeration;
        if (enums) {
            const enumList = Array.isArray(enums) ? enums : [enums];
            result.enumerations = enumList.map(e => e.value || e).filter(Boolean);
        }

        // Max length
        const maxLen = restriction.maxLength;
        if (maxLen) {
            result.maxLength = parseInt(maxLen.value || maxLen) || null;
        }

        return result;
    }


    // ── Internal: Parse Template XML ────────────────────────

    async _parseTemplate(filePath, fields) {
        const xml = fs.readFileSync(filePath, 'utf-8');
        const parsed = await xml2js.parseStringPromise(xml, {
            explicitArray: false,
            mergeAttrs: true,
            tagNameProcessors: [xml2js.processors.stripPrefix]
        });

        const defaults = {};
        this._extractDefaults(parsed, defaults, '');
        return defaults;
    }

    _extractDefaults(node, defaults, parentPath) {
        if (!node || typeof node !== 'object') return;

        for (const [key, value] of Object.entries(node)) {
            if (key.startsWith('$') || key === '_') continue;

            const fieldPath = parentPath ? `${parentPath}.${key}` : key;

            if (typeof value === 'string' && value.trim()) {
                defaults[key] = value.trim();
            } else if (typeof value === 'object' && !Array.isArray(value)) {
                this._extractDefaults(value, defaults, fieldPath);
            }
        }
    }


    // ── Internal: Utility Methods ───────────────────────────

    _findFiles(dir, extension) {
        const results = [];
        const items = fs.readdirSync(dir, { withFileTypes: true });
        for (const item of items) {
            const fullPath = path.join(dir, item.name);
            if (item.isDirectory()) {
                results.push(...this._findFiles(fullPath, extension));
            } else if (item.name.toLowerCase().endsWith(extension)) {
                results.push(fullPath);
            }
        }
        return results;
    }

    _inferMetadata(pathParts, xsnPath) {
        // Try to extract site/list info from directory structure
        // Expected: sites/hr/LeaveRequests/LeaveRequest.xsn
        const metadata = {};
        if (pathParts.length >= 3) {
            metadata.webTitle = pathParts[pathParts.length - 3];
            metadata.listTitle = pathParts[pathParts.length - 2];
        } else if (pathParts.length >= 2) {
            metadata.listTitle = pathParts[pathParts.length - 2];
        }
        return metadata;
    }

    _toDisplayName(fieldName) {
        // Convert camelCase/PascalCase to Display Name
        return fieldName
            .replace(/([A-Z])/g, ' $1')
            .replace(/^./, s => s.toUpperCase())
            .replace(/_/g, ' ')
            .trim();
    }

    _log(level, message) {
        this.parseLog.push({
            timestamp: new Date().toISOString(),
            level,
            message
        });
        if (level === 'error') {
            console.error(`[XSN] ${message}`);
        } else {
            console.log(`[XSN] ${message}`);
        }
    }

    /**
     * Restore from saved state
     */
    restore(formsArray) {
        this.parsedForms.clear();
        for (const form of formsArray) {
            this.parsedForms.set(form.id, form);
        }
        this._log('info', `Restored ${formsArray.length} parsed XSN forms from saved state`);
    }
}

module.exports = { XsnParser };
