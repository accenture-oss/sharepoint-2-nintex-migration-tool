using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Xml;

namespace K2Deploy
{
    class Program
    {
        static string k2BinPath = @"C:\Program Files\K2\Bin";
        static string k2HostBinPath = @"C:\Program Files\K2\Host Server\Bin";
        static string connStr = "Integrated=True;IsPrimaryLogin=True;Authenticate=True;EncryptedPassword=False;Host=localhost;Port=5555";
        
        [STAThread]
        static int Main(string[] args)
        {
            AppDomain.CurrentDomain.AssemblyResolve += (sender, e) =>
            {
                string assemblyName = new AssemblyName(e.Name).Name + ".dll";
                string path1 = Path.Combine(k2BinPath, assemblyName);
                string path2 = Path.Combine(k2HostBinPath, assemblyName);
                if (File.Exists(path1)) return Assembly.LoadFrom(path1);
                if (File.Exists(path2)) return Assembly.LoadFrom(path2);
                return null;
            };
            
            try
            {
                Console.WriteLine("=== K2 KPRX Deployer v18 (ZIP KSPX Strategy) ===");
                
                if (args.Length < 2) { Console.WriteLine("Usage: K2Deployer.exe <kprx-file> <output-dir>"); return 1; }
                
                string kprxFile = args[0];
                string outputDir = args[1];
                
                string tempDir = Path.Combine(Path.GetTempPath(), "K2Deploy_" + Guid.NewGuid().ToString("N").Substring(0,8));
                Directory.CreateDirectory(tempDir);
                
                // Load + Compile
                Console.WriteLine("Loading: " + kprxFile);
                var process = SourceCode.Workflow.Authoring.Process.Load(kprxFile);
                Console.WriteLine("LOADED: " + process.Name);
                process.SaveAs(Path.Combine(tempDir, process.Name + ".kprx"));
                process.DeployToCategory = true;
                
                Console.WriteLine("Compiling...");
                process.Compile();
                Console.WriteLine("Compiled: OK");
                
                // Setup MSBuild project for pkg.Save
                Type extProjType = null;
                foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
                {
                    extProjType = asm.GetType("SourceCode.Workflow.Authoring.ExtenderProject");
                    if (extProjType != null) break;
                }
                Type buildProjType = extProjType;
                while (buildProjType != null && buildProjType.Name != "BuildProject") 
                    buildProjType = buildProjType.BaseType;
                
                object extProject = Activator.CreateInstance(extProjType);
                var initBE = buildProjType.GetMethod("InitializeBuildEngine", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                if (initBE != null) try { initBE.Invoke(extProject, null); } catch {}
                
                var msBuildField = buildProjType.GetField("_msBuildProject", BindingFlags.NonPublic | BindingFlags.Instance);
                var projCollField = buildProjType.GetField("BuildEngine", BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static);
                object projCollection = null;
                if (projCollField != null) projCollection = projCollField.GetValue(extProject);
                if (projCollection == null)
                {
                    Type pcType = Type.GetType("Microsoft.Build.Evaluation.ProjectCollection, Microsoft.Build, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a");
                    if (pcType != null) projCollection = Activator.CreateInstance(pcType);
                }
                string projFile = Path.Combine(tempDir, "build.proj");
                File.WriteAllText(projFile, "<Project xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\"><PropertyGroup></PropertyGroup></Project>");
                Type msProjType = Type.GetType("Microsoft.Build.Evaluation.Project, Microsoft.Build, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a");
                if (msProjType != null && projCollection != null)
                {
                    var proj = Activator.CreateInstance(msProjType, new object[] { projFile, null, null, projCollection });
                    msBuildField.SetValue(extProject, proj);
                }
                var setProp = buildProjType.GetMethod("SetMSBuildProperty",
                    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
                    null, new Type[] { typeof(string), typeof(string) }, null);
                if (setProp != null)
                {
                    setProp.Invoke(extProject, new object[] { "DeploymentServerName", "localhost" });
                    setProp.Invoke(extProject, new object[] { "DeploymentServerPort", "5555" });
                }
                var setFN = buildProjType.GetMethod("SetFileName",
                    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance,
                    null, new Type[] { typeof(string) }, null);
                if (setFN != null) try { setFN.Invoke(extProject, new object[] { Path.Combine(tempDir, "Deploy.k2proj") }); } catch {}
                
                var pkg = process.CreateDeploymentPackage();
                pkg.TestOnly = false;
                pkg.WorkflowManagementConnectionString = connStr;
                pkg.SmartObjectConnectionString = connStr;
                pkg.DeploymentLabelName = process.Name + "_v1";
                
                var containerField = pkg.GetType().GetField("_propertiesContainer", BindingFlags.NonPublic | BindingFlags.Instance);
                var packageFileField = pkg.GetType().GetField("_packageFile", BindingFlags.NonPublic | BindingFlags.Instance);
                containerField.SetValue(pkg, extProject);
                if (packageFileField != null) packageFileField.SetValue(pkg, Path.Combine(tempDir, process.Name + ".kspx"));
                
                pkg.Save(tempDir, process.Name);
                Console.WriteLine("pkg.Save: OK");
                
                // ============================================================
                // PATCH the .msbuild with connection strings
                // ============================================================
                string msbuildFile = null;
                foreach (var f in Directory.GetFiles(tempDir, "*.msbuild"))
                    msbuildFile = f;
                
                if (msbuildFile != null)
                {
                    string content = File.ReadAllText(msbuildFile);
                    content = content.Replace(
                        "<WorkflowManagementConnectionStringProperty />",
                        "<WorkflowManagementConnectionStringProperty>" + connStr + "</WorkflowManagementConnectionStringProperty>");
                    content = content.Replace(
                        "<SmartObjectConnectionStringProperty />",
                        "<SmartObjectConnectionStringProperty>" + connStr + "</SmartObjectConnectionStringProperty>");
                    File.WriteAllText(msbuildFile, content);
                    Console.WriteLine("Patched .msbuild with connection strings");
                }
                
                // ============================================================
                // CREATE PROPER ZIP .kspx from all pkg.Save output
                // ============================================================
                string zipKspx = Path.Combine(outputDir, process.Name + ".kspx");
                if (File.Exists(zipKspx)) File.Delete(zipKspx);
                
                Console.WriteLine("\n--- Creating ZIP .kspx ---");
                using (var zip = ZipFile.Open(zipKspx, ZipArchiveMode.Create))
                {
                    // Add all files from temp dir (except build.proj and the .kprx copy)
                    foreach (var f in Directory.GetFiles(tempDir, "*.*", SearchOption.AllDirectories))
                    {
                        string relativePath = f.Substring(tempDir.Length + 1);
                        // Skip build.proj (our temp file) and the original kprx copy
                        if (relativePath == "build.proj") continue;
                        if (relativePath.EndsWith(".kprx")) continue;
                        if (relativePath == "Deploy.k2proj") continue;
                        
                        zip.CreateEntryFromFile(f, relativePath);
                        Console.WriteLine("  + " + relativePath + " (" + new FileInfo(f).Length + ")");
                    }
                }
                
                // Verify ZIP
                var zipInfo = new FileInfo(zipKspx);
                byte[] header = new byte[4];
                using (var fs = File.OpenRead(zipKspx)) { fs.Read(header, 0, 4); }
                bool isZip = (header[0] == 0x50 && header[1] == 0x4B);
                Console.WriteLine("\nZIP created: " + zipKspx);
                Console.WriteLine("  Size: " + zipInfo.Length + " bytes");
                Console.WriteLine("  Valid ZIP (PK): " + isZip);
                Console.WriteLine("  KSPX_ZIP=" + zipKspx);
                
                try { Directory.Delete(tempDir, true); } catch {}
                Console.WriteLine("\nDONE.");
                return 0;
            }
            catch (Exception ex)
            {
                Console.WriteLine("FATAL:"); UnwrapException(ex, 0); return 2;
            }
        }
        
        static void UnwrapException(Exception ex, int depth)
        {
            if (depth > 10) return;
            string indent = new string(' ', depth * 2);
            Console.WriteLine(indent + "[" + depth + "] " + ex.GetType().FullName + ": " + ex.Message);
            if (ex.StackTrace != null)
            {
                string[] lines = ex.StackTrace.Split('\n');
                for (int i = 0; i < Math.Min(3, lines.Length); i++)
                    Console.WriteLine(indent + "  " + lines[i].Trim());
            }
            if (ex.InnerException != null) UnwrapException(ex.InnerException, depth + 1);
        }
    }
}
