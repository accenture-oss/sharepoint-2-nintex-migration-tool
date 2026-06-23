// ============================================================
// SPD → K2 Five Migration Pipeline — KSPX Package Assembler
// Assembles KPRX process files, environment config, and project
// metadata into a deployable .kspx package (ZIP archive).
//
// Ported from colleague's Python assembler (assembler.py).
// Produces a valid K2 deployment package that Deploy-Kspx.ps1
// can push to the K2 server.
//
// Target: K2 Five 5.8 FP26 (5.0009.1026.0)
// ============================================================

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { ZipArchive } = require('archiver');
const { deterministicGuid, safeName } = require('./kprxEmitter');

/**
 * Assembly options
 * @typedef {Object} AssemblyOptions
 * @property {string} projectName      - K2 project name (used for .k2proj and .sln)
 * @property {string} category         - Deployment category (e.g. 'Workflow/Generated/SiteName')
 * @property {string} targetEnvironment - e.g. 'UAT', 'Production'
 * @property {string} k2Server         - K2 server hostname
 * @property {number} k2Port           - K2 server port (default: 5555)
 * @property {string} sqlConnection    - SQL connection string for K2 (optional)
 * @property {string} sharepointUrl    - Target SharePoint URL (optional)
 */

/**
 * Assembly result
 * @typedef {Object} AssemblyResult
 * @property {number} formsEmitted
 * @property {number} workflowsEmitted
 * @property {number} quarantined
 * @property {number} totalFiles
 * @property {Map<string,string>} files - Map of relative path → file content
 * @property {Object} summary
 */

/**
 * Generate Environment Config XML consumed by Deploy-Kspx.ps1.
 * This must be the first file emitted (MSBuild reads it before .k2proj).
 */
function emitEnvironmentConfig(opts) {
    const targetEnv = opts.targetEnvironment || 'Development';
    const k2Server = opts.k2Server || 'localhost';
    const k2Port = opts.k2Port || 5555;
    const sqlConn = opts.sqlConnection || '';
    const spUrl = opts.sharepointUrl || '';

    let xml = `<?xml version="1.0" encoding="UTF-8"?>\n`;
    xml += `<EnvironmentConfig Environment="${escXml(targetEnv)}" Generator="SPD-K2 Migration Pipeline">\n`;

    // K2 Server connection
    xml += `  <K2Server>\n`;
    xml += `    <Url>${escXml(k2Server)}</Url>\n`;
    xml += `    <Port>${k2Port}</Port>\n`;
    xml += `  </K2Server>\n`;

    // SQL Connection (if provided)
    if (sqlConn) {
        xml += `  <SqlConnection>${escXml(sqlConn)}</SqlConnection>\n`;
    }

    // SharePoint
    if (spUrl) {
        xml += `  <SharePoint>\n`;
        xml += `    <Url>${escXml(spUrl)}</Url>\n`;
        xml += `  </SharePoint>\n`;
    }

    // Tokens — key/value pairs for environment-specific substitution
    xml += `  <Tokens>\n`;
    const tokenMap = {
        'K2_SERVER': k2Server,
        'K2_PORT': String(k2Port),
        'SQL_CONNECTION': sqlConn,
        'SHAREPOINT_BASE_URL': spUrl,
        'TARGET_ENVIRONMENT': targetEnv
    };
    for (const [k, v] of Object.entries(tokenMap)) {
        xml += `    <Token Name="${escXml(k)}">${escXml(v)}</Token>\n`;
    }
    xml += `  </Tokens>\n`;

    xml += `</EnvironmentConfig>\n`;
    return xml;
}

/**
 * Generate a .k2proj file — MSBuild reads this to compile the bundle.
 * @param {string} projName
 * @param {Map<string,string>} files - all files in the bundle
 */
function emitK2Proj(projName, files) {
    const projGuid = '{' + deterministicGuid('k2proj', projName).toUpperCase() + '}';

    let xml = `<?xml version="1.0" encoding="UTF-8"?>\n`;
    xml += `<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003" DefaultTargets="Build">\n`;

    // PropertyGroup
    xml += `  <PropertyGroup>\n`;
    xml += `    <ProjectGuid>${projGuid}</ProjectGuid>\n`;
    xml += `    <ProjectTypeGuids>{F184B08F-C81C-45F6-A57F-5ABD9991F28F};{349C5851-65DF-11DA-9384-00065B846F21}</ProjectTypeGuids>\n`;
    xml += `    <OutputType>Library</OutputType>\n`;
    xml += `    <RootNamespace>${escXml(projName)}</RootNamespace>\n`;
    xml += `    <AssemblyName>${escXml(projName)}</AssemblyName>\n`;
    xml += `    <TargetFrameworkVersion>v4.5</TargetFrameworkVersion>\n`;
    xml += `    <K2BuildServer>${escXml('$(K2BuildServer)')}</K2BuildServer>\n`;
    xml += `    <K2EnvironmentConfig>Properties\\EnvironmentConfig.xml</K2EnvironmentConfig>\n`;
    xml += `  </PropertyGroup>\n`;

    // Include every artifact as a content item
    xml += `  <ItemGroup>\n`;
    const sortedFiles = Array.from(files.keys()).sort();
    for (const rel of sortedFiles) {
        // Skip the .k2proj, .sln, and .md files
        if (rel.endsWith('.k2proj') || rel.endsWith('.sln') || rel.endsWith('.md')) continue;
        xml += `    <Content Include="${escXml(rel.replace(/\//g, '\\'))}"/>\n`;
    }
    xml += `  </ItemGroup>\n`;

    // MSBuild reference to K2 build targets
    xml += `  <Import Project="$(MSBuildExtensionsPath)\\SourceCode\\K2.Studio\\K2.Studio.targets" `;
    xml += `Condition="Exists('$(MSBuildExtensionsPath)\\SourceCode\\K2.Studio\\K2.Studio.targets')"/>\n`;

    xml += `</Project>\n`;
    return xml;
}

/**
 * Generate a Visual Studio .sln file
 */
function emitSln(projName) {
    const projGuid = '{' + deterministicGuid('k2proj', projName).toUpperCase() + '}';

    return (
        `Microsoft Visual Studio Solution File, Format Version 12.00\n` +
        `# Generated by SPD-K2 Migration Pipeline\n` +
        `Project("{F184B08F-C81C-45F6-A57F-5ABD9991F28F}") = ` +
        `"${projName}", "${projName}.k2proj", "${projGuid}"\n` +
        `EndProject\n` +
        `Global\n` +
        `\tGlobalSection(SolutionConfigurationPlatforms) = preSolution\n` +
        `\t\tDebug|Any CPU = Debug|Any CPU\n` +
        `\t\tRelease|Any CPU = Release|Any CPU\n` +
        `\tEndGlobalSection\n` +
        `\tGlobalSection(ProjectConfigurationPlatforms) = postSolution\n` +
        `\t\t${projGuid}.Debug|Any CPU.ActiveCfg = Debug|Any CPU\n` +
        `\t\t${projGuid}.Debug|Any CPU.Build.0 = Debug|Any CPU\n` +
        `\t\t${projGuid}.Release|Any CPU.ActiveCfg = Release|Any CPU\n` +
        `\t\t${projGuid}.Release|Any CPU.Build.0 = Release|Any CPU\n` +
        `\tEndGlobalSection\n` +
        `EndGlobal\n`
    );
}

/**
 * Generate README.md for the package
 */
function emitReadme(opts, forms, workflows, quarantined) {
    let md = `# ${opts.projectName} — K2 Migration Bundle\n\n`;
    md += `Generated by **SPD-K2 Migration Pipeline**.\n\n`;
    md += `- Target environment: **${opts.targetEnvironment || 'Development'}**\n`;
    md += `- K2 server: \`${opts.k2Server || 'localhost'}:${opts.k2Port || 5555}\`\n`;
    md += `- Forms emitted: ${forms.length}\n`;
    md += `- Workflows emitted: ${workflows.length}\n`;
    md += `- Quarantined: ${quarantined.length}\n\n`;

    md += `## Build & Deploy\n\n`;
    md += '```powershell\n';
    md += `# Build the VS solution against a K2 build server\n`;
    md += `./scripts/Build-Solution.ps1 -SolutionPath ${opts.projectName}.sln -Configuration Release\n\n`;
    md += `# Harvest the .kspx\n`;
    md += `./scripts/Harvest-Kspx.ps1 ${opts.k2Server || 'localhost'} -ProjectName ${opts.projectName}\n\n`;
    md += `# Deploy to target\n`;
    md += `./scripts/Deploy-Kspx.ps1 -KspxFile ${opts.projectName}.kspx \\\n`;
    md += `  -EnvironmentConfig Properties/EnvironmentConfig.xml\n`;
    md += '```\n';

    if (quarantined.length > 0) {
        md += `\n## ⚠ Quarantined Items\n\n`;
        quarantined.forEach(q => { md += `- ${q}\n`; });
    }

    return md;
}

/**
 * Assemble a complete KSPX package from workflow + form data.
 *
 * @param {Object} opts - AssemblyOptions
 * @param {Array<Object>} workflowDefs - Array of workflow definitions
 *        Each must have: { name, kprxXml }
 * @param {Array<Object>} formDefs - Optional, array of SmartForm definitions
 *        Each must have: { name, svdxXml } (currently pass-through)
 * @param {Array<string>} quarantined - Optional, list of quarantined items
 * @returns {AssemblyResult}
 */
function assemble(opts, workflowDefs = [], formDefs = [], quarantined = []) {
    const projName = safeName(opts.projectName || 'K2_Migration');
    const files = new Map();

    const formsEmitted = [];
    const workflowsEmitted = [];

    // ── Forms ────────────────────────────────────────────
    for (const f of formDefs) {
        const formName = safeName(f.name);
        const relPath = `Forms/${formName}.svdx`;
        files.set(relPath, f.svdxXml || f.xml || '<!-- form placeholder -->');
        formsEmitted.push(f.name);
    }

    // ── Workflows ────────────────────────────────────────
    for (const w of workflowDefs) {
        const wfName = safeName(w.name);
        files.set(`Workflows/${wfName}.kprx`, w.kprxXml || w.xml);

        // Generate SVDX stubs for each workflow's associated SmartObjects
        if (w.svdxFiles) {
            for (const [sname, sxml] of Object.entries(w.svdxFiles)) {
                files.set(`Services/${sname}`, sxml);
            }
        }

        workflowsEmitted.push(w.name);
    }

    // ── Quarantine queue ─────────────────────────────────
    if (quarantined.length > 0) {
        files.set('QUARANTINE.md',
            `# Quarantined artifacts — manual review required\n\n` +
            quarantined.map(q => `- ${q}`).join('\n') + '\n'
        );
    }

    // ── Environment config (must come before .k2proj) ────
    files.set('Properties/EnvironmentConfig.xml', emitEnvironmentConfig(opts));

    // ── .k2proj ──────────────────────────────────────────
    files.set(`${projName}.k2proj`, emitK2Proj(projName, files));

    // ── .sln ─────────────────────────────────────────────
    files.set(`${projName}.sln`, emitSln(projName));

    // ── README ───────────────────────────────────────────
    files.set('README.md', emitReadme(opts, formsEmitted, workflowsEmitted, quarantined));

    const result = {
        formsEmitted: formsEmitted.length,
        workflowsEmitted: workflowsEmitted.length,
        quarantined: quarantined.length,
        totalFiles: files.size,
        files,
        summary: {
            projectName: projName,
            forms: formsEmitted,
            workflows: workflowsEmitted,
            quarantinedItems: quarantined
        }
    };

    return result;
}

/**
 * Write the assembled result to disk.
 *
 * @param {AssemblyResult} result
 * @param {string} outDir - Output directory path
 * @returns {string} The output directory path
 */
function writeAssemblyToDisk(result, outDir) {
    const out = path.resolve(outDir);

    for (const [rel, content] of result.files) {
        const filePath = path.join(out, rel);
        const dir = path.dirname(filePath);
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }
        fs.writeFileSync(filePath, content, 'utf8');
    }

    return out;
}

/**
 * Create a ZIP (.kspx) archive from the assembled files.
 *
 * @param {AssemblyResult} result
 * @param {string} outputPath - Full path for the .kspx file
 * @returns {Promise<string>} Resolved path of the created .kspx file
 */
function createKspxArchive(result, outputPath) {
    return new Promise((resolve, reject) => {
        const dir = path.dirname(outputPath);
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }

        const output = fs.createWriteStream(outputPath);
        const archive = new ZipArchive({ zlib: { level: 9 } });

        output.on('close', () => resolve(outputPath));
        archive.on('error', err => reject(err));

        archive.pipe(output);

        for (const [rel, content] of result.files) {
            archive.append(content, { name: rel });
        }

        archive.finalize();
    });
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

module.exports = {
    assemble,
    writeAssemblyToDisk,
    createKspxArchive,
    emitEnvironmentConfig,
    emitK2Proj,
    emitSln
};
