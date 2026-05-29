// ============================================================
// SPD → K2 Five Migration Pipeline — K2 Deployment Bridge
// Handles SmartObject deployment to K2 Five server
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// Server: Windows Server 2022 Standard 21H2 20348.4893
// Database: K2_PROD | Listener: 75387P_LN01 | AG: 75387P-AG01
// ============================================================

const { v4: uuidv4 } = require('uuid');

// K2 server configuration
const K2_CONFIG = {
    serverUrl: '',           // Set via API
    port: 5555,              // Default K2 SmartObject server port
    securityLabel: 'K2',     // Default security label
    integrated: true,        // Windows Integrated auth
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

    /**
     * Configure K2 server connection
     */
    configure(options) {
        this.config = { ...this.config, ...options };
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
    async _runPowerShell(script) {
        const { spawnSync } = require('child_process');
        const encodedScript = Buffer.from(script, 'utf16le').toString('base64');
        const result = spawnSync('powershell.exe', [
            '-NoProfile', '-NonInteractive', '-EncodedCommand', encodedScript
        ], { timeout: 60000, encoding: 'utf-8' });

        const stdout = (result.stdout || '').trim();
        const stderr = (result.stderr || '').trim();

        console.log('[PS stdout]', stdout.substring(0, 1000));
        if (stderr) console.log('[PS stderr]', stderr.substring(0, 500));

        // Parse JSON from stdout
        const lines = stdout.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
            const line = lines[i].trim();
            if (line.startsWith('{')) {
                try {
                    return JSON.parse(line);
                } catch(e) { /* try next line */ }
            }
        }

        // If no JSON in stdout, check if stderr has useful info
        if (stderr) {
            throw new Error('PowerShell error: ' + stderr.substring(0, 500));
        }
        throw new Error('No JSON output from PowerShell. stdout: ' + stdout.substring(0, 500));
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

                const psScript = `& '${scriptPath}' -K2Server '${k2Host}' -K2Port ${this.config.port || 5555} -SmartObjectJsonFile '${tmpJson}' -SodxXmlFile '${tmpSodx}'`;

                try {
                    const result = await this._runPowerShell(psScript);
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
}

module.exports = { K2DeploymentBridge };
