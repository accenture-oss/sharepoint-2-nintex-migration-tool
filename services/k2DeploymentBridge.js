// ============================================================
// SPD → K2 Five Migration Pipeline — K2 Deployment Bridge
// Handles SmartObject + Workflow deployment to K2 Five server
//
// SmartObjects: Direct SDK deployment via Deploy-SmartObject.ps1
// Workflows:    KPRX generation → KSPX assembly → Deploy-Kspx.ps1
//               (ported from colleague's Nintex Forms Generator)
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// Server: Windows Server 2022 Standard 21H2 20348.4893
// Database: K2_PROD | Listener: 75387P_LN01 | AG: 75387P-AG01
// ============================================================

const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');
const { generateKprx, blueprintToWorkflowIR } = require('./kprxEmitter');
const { assemble, writeAssemblyToDisk, createKspxArchive } = require('./kspxAssembler');

// K2 server configuration
const K2_CONFIG = {
    serverUrl: '',           // Set via API
    port: 5555,              // Default K2 SmartObject server port
    securityLabel: 'K2',     // Default security label
    integrated: true,        // Windows Integrated auth (set to false for explicit credentials)
    k2DllPath: 'C:\\Program Files\\K2\\Bin',
    k2User: '',              // Optional: explicit K2 user for on-premises (avoids browser auth)
    k2Password: '',          // Optional: K2 user password
    k2Domain: '',            // Optional: domain for K2 user (e.g., 'DOMAIN' for 'DOMAIN\\user')
    database: 'K2_PROD',
    listener: '75387P_LN01',
    ag: '75387P-AG01',
    sqlVersion: 'SQL Server 2019 CU32'
};


class K2DeploymentBridge {

    constructor() {
        this.config = { ...K2_CONFIG };
        this.deploymentQueue = [];
        this.deploymentHistory = [];
        this.isConnected = false;
        this.connectionDetails = null;
    }

    _ensureLogDir() {
        const logsDir = path.join(__dirname, '..', 'logs', 'k2');
        if (!fs.existsSync(logsDir)) {
            fs.mkdirSync(logsDir, { recursive: true });
        }
        return logsDir;
    }

    _writePowerShellLog(operation, script, result, extra = {}) {
        const logsDir = this._ensureLogDir();
        const stamp = new Date().toISOString().replace(/[:.]/g, '-');
        const file = path.join(logsDir, `${stamp}-${operation}.log`);

        const stdout = result && result.stdout ? result.stdout : '';
        const stderr = result && result.stderr ? result.stderr : '';
        const status = result && Object.prototype.hasOwnProperty.call(result, 'status') ? result.status : 'n/a';
        const signal = result && Object.prototype.hasOwnProperty.call(result, 'signal') ? result.signal : 'n/a';
        const timedOut = result && Object.prototype.hasOwnProperty.call(result, 'error') && result.error
            ? (result.error.code === 'ETIMEDOUT' ? 'true' : 'false')
            : 'false';

        const lines = [
            `timestamp: ${new Date().toISOString()}`,
            `operation: ${operation}`,
            `exitStatus: ${status}`,
            `signal: ${signal}`,
            `timedOut: ${timedOut}`,
            `serverUrl: ${this.config.serverUrl || ''}`,
            `k2DllPath: ${this.config.k2DllPath || ''}`,
            extra && extra.note ? `note: ${extra.note}` : ''
        ].filter(Boolean);

        const content = [
            lines.join('\n'),
            '--- SCRIPT ---',
            script || '',
            '--- STDOUT ---',
            stdout,
            '--- STDERR ---',
            stderr
        ].join('\n');

        fs.writeFileSync(file, content, 'utf-8');
        return file;
    }

    /**
     * Configure K2 server connection
     */
    configure(options) {
        const next = { ...this.config, ...options };

        // Keep resilient defaults when UI/API sends empty strings.
        if (!next.k2DllPath || !String(next.k2DllPath).trim()) {
            next.k2DllPath = K2_CONFIG.k2DllPath;
        }
        if (!next.port || Number.isNaN(Number(next.port))) {
            next.port = K2_CONFIG.port;
        }

        this.config = next;
        this.connectionDetails = null;
        this.isConnected = false;
    }

    /**
     * Test K2 server connectivity
     * In production: calls K2 Management API /api/health
     * Currently: validates configuration and simulates connection
     */
    async testConnection() {
        const startTime = Date.now();

        if (!this.config.serverUrl) {
            return {
                success: false,
                error: 'K2 server URL not configured',
                duration: Date.now() - startTime
            };
        }

        // Test K2 connection using TCP + K2 SDK (fully non-interactive, no HTTP prompts)
        const k2Url = this.config.serverUrl.replace(/\/+$/, '');
        const k2Host = k2Url.replace(/^https?:\/\//, '').split(':')[0];
        const k2Port = this.config.port || 5555;
        const psScript = `
            $ErrorActionPreference = "Stop"
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect("${k2Host}", ${k2Port})
                $tcp.Close()
                $result = @{ "success" = $true; "message" = "K2 server reachable on port ${k2Port}"; "host" = "${k2Host}" }
                Write-Host ($result | ConvertTo-Json -Compress)
            } catch {
                $result = @{ "success" = $false; "error" = "Cannot reach ${k2Host}:${k2Port} - " + $_.Exception.Message }
                Write-Host ($result | ConvertTo-Json -Compress)
            }
        `;

        try {
            const psResult = await this._runPowerShell(psScript);
            if (psResult.success) {
                this.isConnected = true;
                this.connectionDetails = {
                    serverUrl: this.config.serverUrl,
                    serverVersion: 'K2 Five 5.8 FP26',
                    build: '5.0009.1026.0',
                    serverOS: 'Windows Server 2022 Standard 21H2',
                    database: this.config.database,
                    listener: this.config.listener,
                    ag: this.config.ag,
                    sqlVersion: this.config.sqlVersion,
                    securityLabel: this.config.securityLabel,
                    designerUrl: k2Url + '/Designer/',
                    connectedAt: new Date().toISOString()
                };
                return {
                    success: true,
                    serverInfo: this.connectionDetails,
                    duration: Date.now() - startTime
                };
            } else {
                return {
                    success: false,
                    error: psResult.error || 'Connection failed',
                    duration: Date.now() - startTime
                };
            }
        } catch (err) {
            return {
                success: false,
                error: err.message,
                duration: Date.now() - startTime
            };
        }
    }

    /**
     * Run a PowerShell script and return parsed JSON output
     */
    async _runPowerShell(script, options = {}) {
        const { spawnSync } = require('child_process');
        const operation = options.operation || 'powershell';
        const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : 60000;
        const encodedScript = Buffer.from(script, 'utf16le').toString('base64');
        const result = spawnSync('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encodedScript
        ], { timeout: timeoutMs, encoding: 'utf-8' });

        const stdout = (result.stdout || '').trim();
        const stderr = (result.stderr || '').trim();
        const logFile = this._writePowerShellLog(operation, script, result);

        console.log('[PS stdout]', stdout.substring(0, 1000));
        if (stderr) console.log('[PS stderr]', stderr.substring(0, 500));

        if (result.error) {
            throw new Error(`PowerShell launch failure: ${result.error.message}. Log: ${logFile}`);
        }

        if (typeof result.status === 'number' && result.status !== 0 && !stdout.includes('{')) {
            const detail = stderr || `PowerShell exited with code ${result.status}`;
            throw new Error(`PowerShell error: ${detail.substring(0, 500)}. Log: ${logFile}`);
        }

        // Parse JSON from stdout
        const lines = stdout.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
            const line = lines[i].trim();
            if (line.startsWith('{')) {
                try {
                    const parsed = JSON.parse(line);
                    if (parsed && typeof parsed === 'object') {
                        parsed._psLogFile = logFile;
                    }
                    return parsed;
                } catch(e) { /* try next line */ }
            }
        }

        // If no JSON in stdout, check if stderr has useful info
        if (stderr) {
            throw new Error('PowerShell error: ' + stderr.substring(0, 500) + `. Log: ${logFile}`);
        }
        throw new Error('No JSON output from PowerShell. stdout: ' + stdout.substring(0, 500) + `. Log: ${logFile}`);
    }

    /**
     * Deploy a single SmartObject to K2 Five via .NET SDK
     * Uses Deploy-SmartObject.ps1 which calls SourceCode.SmartObjects.Management
     */
    async deploy(smartObject, sodxXml, onProgress) {
        const deploymentId = `deploy-${uuidv4().slice(0, 8)}`;
        const startTime = Date.now();

        const deployment = {
            id: deploymentId,
            smartObjectId: smartObject.id,
            smartObjectName: smartObject.name,
            status: 'deploying',
            steps: [],
            startedAt: new Date().toISOString(),
            completedAt: null,
            error: null
        };

        this.deploymentQueue.push(deployment);

        try {
            // Step 1: Validate SODX
            if (onProgress) onProgress(1, 4, 'Validating SODX definition...');
            await this._step(deployment, 'validate_sodx', 'Validate SODX Schema', async () => {
                if (!sodxXml || !sodxXml.includes('<smartobjectroot')) {
                    throw new Error('Invalid SODX: missing root element');
                }
                return { valid: true, propertyCount: smartObject.properties.length };
            });

            // Step 2: Save backup to disk
            if (onProgress) onProgress(2, 4, 'Saving SODX backup...');
            await this._step(deployment, 'save_backup', 'Save Backup', async () => {
                const fs = require('fs');
                const path = require('path');
                const exportDir = path.join(__dirname, '..', 'k2-export');
                if (!fs.existsSync(exportDir)) {
                    fs.mkdirSync(exportDir, { recursive: true });
                }
                const sodxPath = path.join(exportDir, `${smartObject.name}.sodx`);
                fs.writeFileSync(sodxPath, sodxXml, 'utf-8');
                return { saved: sodxPath };
            });

            // Step 3: Deploy to K2 via .NET SDK
            if (onProgress) onProgress(3, 4, 'Publishing SmartObject to K2 Five...');
            await this._step(deployment, 'publish_to_k2', 'Publish to K2', async () => {
                if (!this.config.serverUrl) {
                    throw new Error('K2 server URL not configured');
                }

                const fs = require('fs');
                const path = require('path');
                const os = require('os');
                const scriptPath = path.join(__dirname, '..', 'Deploy-SmartObject.ps1');
                const k2Host = this.config.serverUrl
                    .replace(/^https?:\/\//, '')
                    .replace(/\/+$/, '')
                    .split(':')[0];

                // Write JSON and SODX to temp files to avoid command-line size limits
                const tmpJson = path.join(os.tmpdir(), `k2deploy_${smartObject.name}_${Date.now()}.json`);
                const tmpSodx = path.join(os.tmpdir(), `k2deploy_${smartObject.name}_${Date.now()}.sodx`);
                fs.writeFileSync(tmpJson, JSON.stringify(smartObject), 'utf-8');
                fs.writeFileSync(tmpSodx, sodxXml, 'utf-8');

                // Build PowerShell parameters with optional on-premises credentials
                const psParams = [
                    `-K2Server '${k2Host}'`,
                    `-K2Port ${this.config.port || 5555}`,
                    `-SmartObjectJsonFile '${tmpJson}'`,
                    `-SodxXmlFile '${tmpSodx}'`
                ];

                // Broker type: SmartBox (default) or SharePoint
                const brokerType = this.config.brokerType || 'SmartBox';
                psParams.push(`-BrokerType '${brokerType}'`);
                
                // Only pass k2DllPath if explicitly set (avoid passing empty string)
                if (this.config.k2DllPath && String(this.config.k2DllPath).trim()) {
                    psParams.push(`-K2DllPath '${this.config.k2DllPath}'`);
                }
                
                // Add explicit credentials if provided (on-premises)
                if (this.config.k2User && this.config.k2Password) {
                    psParams.push(`-K2User '${this.config.k2User}'`);
                    psParams.push(`-K2Password '${this.config.k2Password}'`);
                    if (this.config.k2Domain) {
                        psParams.push(`-K2Domain '${this.config.k2Domain}'`);
                    }
                }
                
                const psScript = `& '${scriptPath}' ${psParams.join(' ')}`;

                try {
                    const result = await this._runPowerShell(psScript, { operation: 'smartobject-deploy', timeoutMs: 120000 });
                    try { fs.unlinkSync(tmpJson); } catch(e) {}
                    try { fs.unlinkSync(tmpSodx); } catch(e) {}
                    // Check if K2 actually created the SmartObject
                    if (result.success === false) {
                        throw new Error(result.error || 'K2 PublishSmartObject failed');
                    }
                    if (result.exists === false) {
                        throw new Error(result.error || 'SmartObject was not created - SODX XML format may not match K2 expectations');
                    }
                    return result;
                } catch (err) {
                    try { fs.unlinkSync(tmpJson); } catch(e) {}
                    try { fs.unlinkSync(tmpSodx); } catch(e) {}
                    throw err;
                }
            });

            // Step 4: Done
            if (onProgress) onProgress(4, 4, `SmartObject "${smartObject.name}" published to K2`);

            deployment.status = 'deployed';
            deployment.completedAt = new Date().toISOString();

            if (onProgress) onProgress(6, 6, `SmartObject "${smartObject.name}" deployed successfully`);

        } catch (err) {
            deployment.status = 'failed';
            deployment.error = err.message;
            deployment.completedAt = new Date().toISOString();
            console.error(`[K2 DEPLOY ERROR] ${smartObject.name}: ${err.message}`);

            if (onProgress) onProgress(0, 6, `Deployment failed: ${err.message}`);
        }

        deployment.durationMs = Date.now() - startTime;
        this.deploymentHistory.push({ ...deployment });

        return deployment;
    }

    /**
     * Get deployment status for a SmartObject
     */
    getDeploymentStatus(smartObjectId) {
        return this.deploymentQueue.find(d => d.smartObjectId === smartObjectId) || null;
    }

    /**
     * Get all deployment history
     */
    getDeploymentHistory() {
        return this.deploymentHistory;
    }

    /**
     * Get connection info
     */
    getConnectionInfo() {
        return {
            isConnected: this.isConnected,
            serverUrl: this.config.serverUrl || '',
            config: {
                serverUrl: this.config.serverUrl || '(not configured)',
                port: this.config.port,
                k2DllPath: this.config.k2DllPath,
                brokerType: this.config.brokerType || 'SmartBox',
                database: this.config.database,
                listener: this.config.listener,
                ag: this.config.ag,
                securityLabel: this.config.securityLabel
            },
            sqlServer: this.config.sqlServer,
            sqlCatalog: this.config.sqlCatalog,
            sqlUser: this.config.sqlUser,
            sqlPassword: this.config.sqlPassword,
            sqlDomain: this.config.sqlDomain,
            details: this.connectionDetails
        };
    }


    // ── Internal ────────────────────────────────────────────

    async _step(deployment, stepId, stepName, executor) {
        const step = {
            id: stepId,
            name: stepName,
            status: 'running',
            startedAt: new Date().toISOString(),
            result: null,
            error: null
        };
        deployment.steps.push(step);

        try {
            step.result = await executor();
            step.status = 'completed';
        } catch (err) {
            step.status = 'failed';
            step.error = err.message;
            throw err;
        } finally {
            step.completedAt = new Date().toISOString();
        }
    }

    // ══════════════════════════════════════════════════════════
    // KSPX Workflow Deployment Pipeline
    // Ported from colleague's Nintex Forms Generator approach
    // ══════════════════════════════════════════════════════════

    /**
     * Deploy a pre-built .kspx package to the K2 server.
     *
     * @param {string} kspxFilePath     - Path to the .kspx file
     * @param {string} envConfigPath    - Path to EnvironmentConfig.xml
     * @param {Object} options          - { dryRun, category }
     * @returns {Object}                 - Deployment result
     */
    async deployWorkflowKspx(kspxFilePath, envConfigPath, options = {}) {
        const startTime = Date.now();

        if (!this.config.serverUrl) {
            return { success: false, error: 'K2 server URL not configured' };
        }

        const k2Host = this.config.serverUrl
            .replace(/^https?:\/\//, '')
            .replace(/\/+$/, '')
            .split(':')[0];

        const scriptPath = path.join(__dirname, '..', 'Deploy-Kspx.ps1');

        // Build PowerShell parameters
        const psParams = [
            `-KspxFile '${kspxFilePath}'`,
            `-EnvironmentConfig '${envConfigPath}'`,
            `-TargetK2 '${k2Host}'`,
            `-Port ${this.config.port || 5555}`
        ];

        if (options.dryRun) {
            psParams.push('-DryRun');
        }

        if (options.category) {
            psParams.push(`-Category '${options.category}'`);
        }

        if (this.config.k2DllPath && String(this.config.k2DllPath).trim()) {
            psParams.push(`-K2DllPath '${this.config.k2DllPath}'`);
        }

        if (this.config.k2User && this.config.k2Password) {
            psParams.push(`-K2User '${this.config.k2User}'`);
            psParams.push(`-K2Password '${this.config.k2Password}'`);
            if (this.config.k2Domain) {
                psParams.push(`-K2Domain '${this.config.k2Domain}'`);
            }
        }

        const psScript = `& '${scriptPath}' ${psParams.join(' ')}`;

        try {
            const result = await this._runPowerShell(psScript, {
                operation: 'kspx-deploy',
                timeoutMs: 180000  // 3 minutes for large packages
            });

            const deployEntry = {
                id: `kspx-deploy-${uuidv4().slice(0, 8)}`,
                type: 'kspx-workflow',
                kspxFile: kspxFilePath,
                target: `${k2Host}:${this.config.port || 5555}`,
                dryRun: options.dryRun || false,
                result,
                durationMs: Date.now() - startTime,
                timestamp: new Date().toISOString()
            };

            this.deploymentHistory.push(deployEntry);
            return { success: true, ...deployEntry };

        } catch (err) {
            console.error('[KSPX Deploy Error]', err.message);
            return {
                success: false,
                error: err.message,
                durationMs: Date.now() - startTime
            };
        }
    }

    /**
     * Harvest (export) existing K2 artifacts from the server into a .kspx package.
     *
     * @param {string} category  - K2 category to export (e.g. 'Workflow/Generated')
     * @param {string} outFile   - Output .kspx file path
     * @returns {Object}          - Harvest result
     */
    async harvestKspx(category, outFile) {
        if (!this.config.serverUrl) {
            return { success: false, error: 'K2 server URL not configured' };
        }

        const k2Host = this.config.serverUrl
            .replace(/^https?:\/\//, '')
            .replace(/\/+$/, '')
            .split(':')[0];

        const scriptPath = path.join(__dirname, '..', 'Harvest-Kspx.ps1');

        const psParams = [
            `-K2Server '${k2Host}'`,
            `-Port ${this.config.port || 5555}`,
            `-Category '${category}'`,
            `-OutFile '${outFile}'`
        ];

        if (this.config.k2DllPath && String(this.config.k2DllPath).trim()) {
            psParams.push(`-K2DllPath '${this.config.k2DllPath}'`);
        }

        const psScript = `& '${scriptPath}' ${psParams.join(' ')}`;

        try {
            const result = await this._runPowerShell(psScript, {
                operation: 'kspx-harvest',
                timeoutMs: 120000
            });

            return { success: true, ...result, outFile };
        } catch (err) {
            console.error('[KSPX Harvest Error]', err.message);
            return { success: false, error: err.message };
        }
    }

    /**
     * Full E2E workflow deployment: Blueprint → KPRX → KSPX → Deploy.
     * This is the main automation method that replaces manual K2 Designer work.
     *
     * @param {Object} blueprint       - Workflow blueprint from workflowBlueprintGenerator
     * @param {Object} options
     *   {
     *     siteName: string,         - SharePoint site name for category
     *     listTitle: string,        - SharePoint list title
     *     webUrl: string,           - SharePoint web URL
     *     smartObjectName: string,  - Target SmartObject name
     *     dryRun: boolean           - If true, only analyze (no deploy)
     *   }
     * @param {Function} onProgress  - Optional progress callback(step, total, message)
     * @returns {Object}              - Full deployment result
     */
    async generateAndDeployWorkflow(blueprint, options = {}, onProgress) {
        const startTime = Date.now();
        const deploymentId = `wf-deploy-${uuidv4().slice(0, 8)}`;

        const deployment = {
            id: deploymentId,
            workflowName: blueprint.workflowName || blueprint.name,
            status: 'generating',
            steps: [],
            startedAt: new Date().toISOString(),
            completedAt: null,
            error: null
        };

        this.deploymentQueue.push(deployment);

        try {
            // ── Step 1: Convert blueprint to workflow IR ────────
            if (onProgress) onProgress(1, 5, 'Converting blueprint to workflow IR...');
            const ir = await this._step(deployment, 'blueprint_to_ir', 'Convert Blueprint → IR', async () => {
                return blueprintToWorkflowIR(blueprint, {
                    listTitle: options.listTitle || blueprint.listTitle,
                    webUrl: options.webUrl || blueprint.webUrl,
                    smartObjectName: options.smartObjectName
                });
            });

            // ── Step 2: Generate KPRX XML ──────────────────────
            if (onProgress) onProgress(2, 5, 'Generating KPRX process XML...');
            const kprxXml = await this._step(deployment, 'generate_kprx', 'Generate KPRX XML', async () => {
                return generateKprx(ir.result);
            });

            // ── Step 3: Assemble KSPX package ──────────────────
            if (onProgress) onProgress(3, 5, 'Assembling KSPX package...');
            const kspxResult = await this._step(deployment, 'assemble_kspx', 'Assemble KSPX Package', async () => {
                const projName = options.siteName
                    ? `${options.siteName}_${blueprint.workflowName || 'Workflow'}`
                    : blueprint.workflowName || 'K2_Migration';

                const assemblyOpts = {
                    projectName: projName,
                    category: `Workflow/Generated/${options.siteName || 'Default'}`,
                    targetEnvironment: options.targetEnvironment || 'Development',
                    k2Server: this.config.serverUrl
                        ? this.config.serverUrl.replace(/^https?:\/\//, '').split(':')[0]
                        : 'localhost',
                    k2Port: this.config.port || 5555,
                    sharepointUrl: options.webUrl || ''
                };

                const workflowDefs = [{
                    name: blueprint.workflowName || blueprint.name,
                    kprxXml: kprxXml.result
                }];

                const result = assemble(assemblyOpts, workflowDefs);

                // Write to disk and create archive
                const os = require('os');
                const outDir = path.join(os.tmpdir(), `k2_kspx_${deploymentId}`);
                writeAssemblyToDisk(result, outDir);

                const kspxPath = path.join(os.tmpdir(), `${projName}_${Date.now()}.kspx`);
                await createKspxArchive(result, kspxPath);

                return {
                    kspxPath,
                    outDir,
                    summary: result.summary,
                    totalFiles: result.totalFiles
                };
            });

            // ── Step 4: Deploy KSPX to K2 ──────────────────────
            if (onProgress) onProgress(4, 5, options.dryRun ? 'Analyzing deployment (dry run)...' : 'Deploying KSPX to K2...');

            const deployResult = await this._step(deployment, 'deploy_kspx', 'Deploy KSPX Package', async () => {
                const envConfigPath = path.join(
                    path.dirname(kspxResult.result.kspxPath),
                    'EnvironmentConfig.xml'
                );

                // Write the env config adjacent to the kspx
                const envConfigContent = require('./kspxAssembler').emitEnvironmentConfig({
                    targetEnvironment: options.targetEnvironment || 'Development',
                    k2Server: this.config.serverUrl
                        ? this.config.serverUrl.replace(/^https?:\/\//, '').split(':')[0]
                        : 'localhost',
                    k2Port: this.config.port || 5555,
                    sharepointUrl: options.webUrl || ''
                });
                fs.writeFileSync(envConfigPath, envConfigContent, 'utf8');

                return await this.deployWorkflowKspx(
                    kspxResult.result.kspxPath,
                    envConfigPath,
                    {
                        dryRun: options.dryRun || false,
                        category: `Workflow/Generated/${options.siteName || 'Default'}`
                    }
                );
            });

            // ── Step 5: Cleanup & finalize ─────────────────────
            if (onProgress) onProgress(5, 5, 'Deployment complete.');
            deployment.status = deployResult.result.success ? 'deployed' : 'failed';
            deployment.completedAt = new Date().toISOString();

            // Save KPRX to k2-export for reference
            const exportDir = path.join(__dirname, '..', 'k2-export');
            if (!fs.existsSync(exportDir)) fs.mkdirSync(exportDir, { recursive: true });
            const kprxPath = path.join(exportDir, `${blueprint.workflowName || 'workflow'}.kprx`);
            fs.writeFileSync(kprxPath, kprxXml.result, 'utf8');

        } catch (err) {
            deployment.status = 'failed';
            deployment.error = err.message;
            deployment.completedAt = new Date().toISOString();
            console.error(`[K2 WF DEPLOY ERROR] ${blueprint.workflowName}: ${err.message}`);
            if (onProgress) onProgress(0, 5, `Deployment failed: ${err.message}`);
        }

        deployment.durationMs = Date.now() - startTime;
        this.deploymentHistory.push({ ...deployment });

        return deployment;
    }
}

module.exports = { K2DeploymentBridge };
