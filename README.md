# SP to Nintex (K2 Five) Migration Tool

Practical operations guide for running the migration pipeline end-to-end.

## What this tool does

This project helps migrate SharePoint Designer and InfoPath assets into K2 Five artifacts in phases:

1. Discovery import (workflow and form inventory)
2. Analysis and tiering
3. SmartObject generation and deployment
4. SmartForm generation and deployment
5. Workflow routing and blueprint support

The backend is an Express API in `server.js`, and the UI is served from `public/`.

## Prerequisites

- Windows machine with PowerShell 5+ or PowerShell 7+
- Node.js 18+ (recommended)
- Access to a K2 Five environment
- K2 SDK DLLs installed (default path):
  - `C:\Program Files\K2\Bin`
- Network access from this machine to K2 host/port (default 5555)

Optional but commonly needed:

- SQL Server reachability for metadata/testing endpoints
- A K2 account with rights to publish SmartObjects and SmartForms

## Repository layout (important files)

- `server.js`: main API server and orchestration
- `services/`: discovery/analysis/generation/deployment bridge logic
- `Deploy-SmartObject.ps1`: SmartObject deployment script
- `Deploy-SmartForm.ps1`: SmartForm deployment script
- `Deploy-Workflow.ps1`: workflow deployment script
- `public/index.html`: web UI entry point
- `.migration-state/`: persisted runtime state
- `logs/k2/`: PowerShell execution logs

## Install and start

From the repository root:

```powershell
npm install
npm start
```

Default server URL:

- `http://localhost:3001`

Health check:

```powershell
Invoke-RestMethod -Uri "http://localhost:3001/api/health" -Method Get
```

## Operating workflow (recommended)

## 1) Configure K2 connection

Send connection settings once after startup:

```powershell
$body = @{
  serverUrl = "https://k2nintexsppoc"
  port = 5555
  securityLabel = "K2"
  k2DllPath = "C:\Program Files\K2\Bin"

  # Optional explicit K2 auth (recommended when Integrated auth prompts/fails)
  k2User = ""
  k2Password = ""
  k2Domain = ""

  # Optional SQL settings for /api/k2/test-sql
  sqlServer = ".\SPSEDBPOC"
  sqlCatalog = ""
  sqlUser = ""
  sqlPassword = ""
  sqlDomain = "SPSEPOC"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:3001/api/k2/configure" -Method Post -ContentType "application/json" -Body $body
Invoke-RestMethod -Uri "http://localhost:3001/api/k2/test" -Method Post
```

## 2) Import discovery data

Use existing export scripts to produce source CSV/JSON files, then upload:

- Discovery CSV upload endpoint: `POST /api/discovery/upload`
- Schema JSON upload endpoint: `POST /api/discovery/upload-schema`
- Optional XSN upload endpoint: `POST /api/discovery/upload-xsn`

If you use the UI, open `http://localhost:3001` and upload from there.

## 3) Run analysis

```powershell
Invoke-RestMethod -Uri "http://localhost:3001/api/analysis/run" -Method Post
Invoke-RestMethod -Uri "http://localhost:3001/api/analysis/results?page=1&pageSize=100" -Method Get
```

## 4) Generate SmartObjects

```powershell
Invoke-RestMethod -Uri "http://localhost:3001/api/smartobjects/generate" -Method Post
Invoke-RestMethod -Uri "http://localhost:3001/api/smartobjects" -Method Get
```

Deploy:

- Single: `POST /api/smartobjects/:id/deploy`
- Batch: `POST /api/smartobjects/deploy-all`

Reconcile local vs K2 for SmartObjects:

- `POST /api/k2/reconcile`

## 5) Generate SmartForms

```powershell
Invoke-RestMethod -Uri "http://localhost:3001/api/smartforms/generate" -Method Post
Invoke-RestMethod -Uri "http://localhost:3001/api/smartforms" -Method Get
```

Deploy:

- Single: `POST /api/smartforms/:id/deploy`
- Batch: `POST /api/smartforms/deploy-all`

Reconcile local vs K2 for SmartForms:

- `POST /api/k2/reconcile-smartforms`

## 6) Workflow templates and routing

- Fetch workflow templates from K2: `POST /api/k2/workflow-templates`
- Generate routing set: `POST /api/workflow-routing/generate`
- List routing rows: `GET /api/workflow-routing`
- Bind mapped template to a row: `POST /api/workflow-routing/:id/bind`

Legacy blueprint endpoints also exist under `/api/blueprints/*`.

## High-value operational endpoints

- `GET /api/health`
- `GET /api/environment`
- `GET /api/k2/connection`
- `POST /api/k2/test`
- `POST /api/k2/test-sql`
- `GET /api/k2/deployment-history`
- `GET /api/smartobjects/log`
- `GET /api/smartforms/log`

## State and logging

- Runtime state persists in `.migration-state/*.json`
- K2/PowerShell diagnostics are written to `logs/k2/*.log`

If server restarts, state is restored automatically from `.migration-state`.

## Troubleshooting

## Execution policy blocks scripts

Symptom:

- PowerShell reports script execution is disabled.

Fix:

- Run with `-ExecutionPolicy Bypass` in invocation path.
- Or set machine/user policy appropriately.

## K2 SDK load failures (blocked DLL)

Symptom:

- SDK load error with code similar to `0x80131515`.

Fix:

```powershell
Get-ChildItem "C:\Program Files\K2\Bin\*.dll" | Unblock-File
```

## Auth popup or authorization failed

Symptom:

- Browser/auth prompt or authorization failure during deploy.

Fix:

- Configure explicit K2 credentials through `POST /api/k2/configure` (`k2User`, `k2Password`, `k2Domain`).
- Verify account has K2 publish/admin permissions.

## SmartForm duplicate key in Form.Control

Recent fix:

- `Deploy-SmartForm.ps1` now avoids a root form control name collision by using a unique internal root control name.
- Existing views/forms are checked and cleaned before republish where possible.

If issues persist:

1. Check `details` in API response for DIAG lines.
2. Check `logs/k2/*.log` for the exact PowerShell command and output.
3. Verify runtime script path is the same file you edited.

## Path mismatch between edited and runtime script

If you run scripts from another folder (for example a copy in `C:\Shared\...`), ensure both locations are synchronized. Otherwise fixes in this repository will not be used by runtime.

## Typical day-2 runbook

1. Start server (`npm start`)
2. Configure/test K2 connection
3. Upload discovery/schema/XSN files
4. Run analysis
5. Generate and deploy SmartObjects
6. Reconcile SmartObjects
7. Generate and deploy SmartForms
8. Reconcile SmartForms
9. Generate workflow routing and bind templates
10. Validate cutover endpoints and export reports as needed

## Security notes

- Do not commit real credentials.
- Prefer environment or secure secret management for production usage.
- Limit operator rights to minimum required for deployment tasks.

## Support files in this repo

There are many `Deploy-*`, `Test-*`, and `Export-*` scripts for targeted validation and troubleshooting. Use them when isolating specific K2 SDK, package, or publish issues.
