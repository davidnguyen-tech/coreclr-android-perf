using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers.Clr;

class TraceAnalysis
{
    public string ConfigName { get; set; } = "";
    public string FilePath { get; set; } = "";
    public HashSet<string> JitMethods { get; } = new(StringComparer.Ordinal);
    public HashSet<string> R2RMethods { get; } = new(StringComparer.Ordinal);
    public int JitEventCount { get; set; }
    public int R2REventCount { get; set; }
    public int MethodLoadCount { get; set; }
    public double FirstJitTimestampMs { get; set; } = double.MaxValue;
    public double LastJitTimestampMs { get; set; } = double.MinValue;
    public double FirstMethodLoadTimestampMs { get; set; } = double.MaxValue;
    public double LastMethodLoadTimestampMs { get; set; } = double.MinValue;
    public HashSet<string> RundownMethods { get; } = new(StringComparer.Ordinal);
    public int RundownEventCount { get; set; }
    public int TypedEventSuccessCount { get; set; }
}

class Program
{
    static void Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: nettrace-analyzer <r2r_comp.nettrace> <r2r_comp_pgo.nettrace> [report.md]");
            return;
        }

        string r2rCompPath = args[0];
        string r2rCompPgoPath = args[1];
        string reportPath = args.Length > 2 ? args[2] : "/tmp/nettrace-comparison-report.md";

        Console.WriteLine($"Analyzing R2R_COMP:     {Path.GetFileName(r2rCompPath)}");
        Console.WriteLine($"Analyzing R2R_COMP_PGO: {Path.GetFileName(r2rCompPgoPath)}");
        Console.WriteLine();

        var r2rComp = AnalyzeTrace(r2rCompPath, "R2R_COMP");
        var r2rCompPgo = AnalyzeTrace(r2rCompPgoPath, "R2R_COMP_PGO");

        bool hasMethodNames = r2rCompPgo.JitMethods.Count > 0 || r2rComp.JitMethods.Count > 0;

        GenerateReport(r2rComp, r2rCompPgo, reportPath);

        if (!hasMethodNames)
        {
            Console.WriteLine("\nSPEEDSCOPE_FALLBACK_NEEDED");
        }
    }

    static TraceAnalysis AnalyzeTrace(string filePath, string configName)
    {
        var analysis = new TraceAnalysis { ConfigName = configName, FilePath = filePath };
        Console.WriteLine($"--- Parsing {configName} ---");

        try
        {
            using var source = new EventPipeEventSource(filePath);

            int totalEvents = 0;
            int clrEvents = 0;
            int rundownEvents = 0;
            int payloadFailCount = 0;

            // === Approach 1: Typed CLR events (auto-decoded schemas) ===
            source.Clr.MethodJittingStarted += delegate(MethodJittingStartedTraceData data)
            {
                analysis.JitEventCount++;
                double ts = data.TimeStampRelativeMSec;
                if (ts < analysis.FirstJitTimestampMs) analysis.FirstJitTimestampMs = ts;
                if (ts > analysis.LastJitTimestampMs) analysis.LastJitTimestampMs = ts;

                string? method = FormatTypedMethod(data.MethodNamespace, data.MethodName, data.MethodSignature);
                if (method != null)
                {
                    analysis.JitMethods.Add(method);
                    analysis.TypedEventSuccessCount++;
                }
            };

            source.Clr.MethodLoadVerbose += delegate(MethodLoadUnloadVerboseTraceData data)
            {
                analysis.MethodLoadCount++;
                double ts = data.TimeStampRelativeMSec;
                if (ts < analysis.FirstMethodLoadTimestampMs) analysis.FirstMethodLoadTimestampMs = ts;
                if (ts > analysis.LastMethodLoadTimestampMs) analysis.LastMethodLoadTimestampMs = ts;

                bool isJitted = (data.MethodFlags & MethodFlags.Jitted) != 0;
                string? method = FormatTypedMethod(data.MethodNamespace, data.MethodName, data.MethodSignature);
                if (method != null)
                {
                    if (isJitted)
                        analysis.JitMethods.Add(method);
                    else
                        analysis.R2RMethods.Add(method);
                    analysis.TypedEventSuccessCount++;
                }
            };

            // R2R events handled via Dynamic.All below (no typed parser for R2RGetEntryPoint)

            // === Approach 2: Dynamic fallback for events typed parser might miss ===
            source.Dynamic.All += delegate(TraceEvent data)
            {
                totalEvents++;
                string providerName = data.ProviderName;

                if (providerName == "Microsoft-Windows-DotNETRuntime")
                {
                    clrEvents++;
                    int eventId = (int)data.ID;
                    if (eventId == 283 || eventId == 284)
                    {
                        // R2R events not caught by typed parser
                        string? method = TryExtractMethodName(data);
                        if (method != null)
                            analysis.R2RMethods.Add(method);
                    }
                }
                else if (providerName == "Microsoft-Windows-DotNETRuntimeRundown")
                {
                    rundownEvents++;
                    int eventId = (int)data.ID;
                    if (eventId == 144 || eventId == 150)
                    {
                        analysis.RundownEventCount++;
                        string? method = TryExtractMethodName(data);
                        if (method != null)
                            analysis.RundownMethods.Add(method);
                    }
                }
            };

            source.Process();

            Console.WriteLine($"  Total events: {totalEvents}");
            Console.WriteLine($"  CLR events: {clrEvents}");
            Console.WriteLine($"  Rundown events: {rundownEvents}");
            Console.WriteLine($"  JIT events (MethodJittingStarted): {analysis.JitEventCount}");
            Console.WriteLine($"  JIT methods with names: {analysis.JitMethods.Count}");
            Console.WriteLine($"  Method loads (MethodLoadVerbose): {analysis.MethodLoadCount}");
            Console.WriteLine($"  R2R events: {analysis.R2REventCount}");
            Console.WriteLine($"  R2R methods with names: {analysis.R2RMethods.Count}");
            Console.WriteLine($"  Rundown methods: {analysis.RundownEventCount} ({analysis.RundownMethods.Count} with names)");
            Console.WriteLine($"  Typed event decode successes: {analysis.TypedEventSuccessCount}");

            if (analysis.FirstJitTimestampMs < double.MaxValue && analysis.LastJitTimestampMs > double.MinValue)
            {
                double jitSpan = analysis.LastJitTimestampMs - analysis.FirstJitTimestampMs;
                Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  JIT wall span: {0:F2} ms", jitSpan));
            }
            if (analysis.FirstMethodLoadTimestampMs < double.MaxValue && analysis.LastMethodLoadTimestampMs > double.MinValue)
            {
                double loadSpan = analysis.LastMethodLoadTimestampMs - analysis.FirstMethodLoadTimestampMs;
                Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "  MethodLoad wall span: {0:F2} ms", loadSpan));
            }
            Console.WriteLine();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"  ERROR parsing {configName}: {ex.Message}");
            Console.Error.WriteLine($"  {ex.StackTrace}");
        }

        return analysis;
    }

    // Regex to normalize runtime-specific addresses in method signatures
    static readonly Regex PmtRegex = new(@"pMT: 0x[0-9a-fA-F]+", RegexOptions.Compiled);

    static string? FormatTypedMethod(string? ns, string? name, string? sig)
    {
        if (string.IsNullOrWhiteSpace(name) || name == "?")
            return null;

        var sb = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(ns) && ns != "?")
        {
            sb.Append(ns);
            sb.Append("::");
        }
        sb.Append(name);
        if (!string.IsNullOrWhiteSpace(sig) && sig != "?")
        {
            sb.Append(sig);
        }
        string result = sb.ToString();
        // Filter out garbage strings from truncated payloads
        if (result.Length < 2 || result.Any(c => c < 0x20 && c != '\t'))
            return null;
        // Normalize runtime addresses so same methods match across runs
        result = PmtRegex.Replace(result, "pMT: 0x*");
        return result;
    }

    static string? TryExtractMethodName(TraceEvent data)
    {
        try
        {
            string? ns = null, name = null, sig = null;
            var payloadNames = data.PayloadNames;
            if (payloadNames != null && payloadNames.Length > 0)
            {
                foreach (var pn in payloadNames)
                {
                    string lower = pn.ToLowerInvariant();
                    if (lower.Contains("namespace") || lower == "methodnamespace")
                        ns = data.PayloadStringByName(pn);
                    else if (lower == "methodname" || (lower == "name" && name == null))
                        name = data.PayloadStringByName(pn);
                    else if (lower.Contains("signature") || lower == "methodsignature")
                        sig = data.PayloadStringByName(pn);
                }
            }
            return FormatTypedMethod(ns, name, sig);
        }
        catch
        {
            return null;
        }
    }

    static void GenerateReport(TraceAnalysis r2rComp, TraceAnalysis r2rCompPgo, string reportPath)
    {
        bool hasMethodNames = r2rCompPgo.JitMethods.Count > 0 || r2rComp.JitMethods.Count > 0;

        if (!hasMethodNames)
        {
            Console.WriteLine("WARNING: No method names extracted from typed/dynamic events.");
            Console.WriteLine("         Remote EventPipe traces have truncated payloads.");
        }

        var sb = new StringBuilder();
        sb.AppendLine("# Nettrace Comparison Report: R2R_COMP vs R2R_COMP_PGO");
        sb.AppendLine();
        sb.AppendLine($"**Generated**: {DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}");
        sb.AppendLine();
        sb.AppendLine("## Trace Files");
        sb.AppendLine();
        sb.AppendLine($"- **R2R_COMP**: `{Path.GetFullPath(r2rComp.FilePath)}`");
        sb.AppendLine($"- **R2R_COMP_PGO**: `{Path.GetFullPath(r2rCompPgo.FilePath)}`");
        sb.AppendLine();

        sb.AppendLine("## Summary");
        sb.AppendLine();
        sb.AppendLine("| Metric | R2R_COMP | R2R_COMP_PGO | Delta |");
        sb.AppendLine("|--------|----------|--------------|-------|");

        sb.AppendLine($"| JIT Events (MethodJittingStarted) | {r2rComp.JitEventCount} | {r2rCompPgo.JitEventCount} | {FormatDelta(r2rComp.JitEventCount, r2rCompPgo.JitEventCount)} |");
        sb.AppendLine($"| JIT Methods (unique names) | {r2rComp.JitMethods.Count} | {r2rCompPgo.JitMethods.Count} | {FormatDelta(r2rComp.JitMethods.Count, r2rCompPgo.JitMethods.Count)} |");
        sb.AppendLine($"| R2R Entry Point Events | {r2rComp.R2REventCount} | {r2rCompPgo.R2REventCount} | {FormatDelta(r2rComp.R2REventCount, r2rCompPgo.R2REventCount)} |");
        sb.AppendLine($"| R2R Methods (unique names) | {r2rComp.R2RMethods.Count} | {r2rCompPgo.R2RMethods.Count} | {FormatDelta(r2rComp.R2RMethods.Count, r2rCompPgo.R2RMethods.Count)} |");
        sb.AppendLine($"| Method Loads (Verbose) | {r2rComp.MethodLoadCount} | {r2rCompPgo.MethodLoadCount} | {FormatDelta(r2rComp.MethodLoadCount, r2rCompPgo.MethodLoadCount)} |");
        sb.AppendLine($"| Rundown Methods | {r2rComp.RundownEventCount} | {r2rCompPgo.RundownEventCount} | {FormatDelta(r2rComp.RundownEventCount, r2rCompPgo.RundownEventCount)} |");

        double r2rJitSpan = CalcSpan(r2rComp.FirstJitTimestampMs, r2rComp.LastJitTimestampMs);
        double pgoJitSpan = CalcSpan(r2rCompPgo.FirstJitTimestampMs, r2rCompPgo.LastJitTimestampMs);
        var inv = CultureInfo.InvariantCulture;
        if (r2rJitSpan >= 0 || pgoJitSpan >= 0)
        {
            string r2rSpanStr = r2rJitSpan >= 0 ? string.Format(inv, "{0:F1} ms", r2rJitSpan) : "N/A";
            string pgoSpanStr = pgoJitSpan >= 0 ? string.Format(inv, "{0:F1} ms", pgoJitSpan) : "N/A";
            string deltaStr = (r2rJitSpan >= 0 && pgoJitSpan >= 0)
                ? string.Format(inv, "{0:+#,##0.0;-#,##0.0;0.0} ms", pgoJitSpan - r2rJitSpan)
                : "N/A";
            sb.AppendLine($"| JIT Wall Span | {r2rSpanStr} | {pgoSpanStr} | {deltaStr} |");
        }

        double r2rLoadSpan = CalcSpan(r2rComp.FirstMethodLoadTimestampMs, r2rComp.LastMethodLoadTimestampMs);
        double pgoLoadSpan = CalcSpan(r2rCompPgo.FirstMethodLoadTimestampMs, r2rCompPgo.LastMethodLoadTimestampMs);
        if (r2rLoadSpan >= 0 || pgoLoadSpan >= 0)
        {
            string r2rStr = r2rLoadSpan >= 0 ? string.Format(inv, "{0:F1} ms", r2rLoadSpan) : "N/A";
            string pgoStr = pgoLoadSpan >= 0 ? string.Format(inv, "{0:F1} ms", pgoLoadSpan) : "N/A";
            string deltaStr = (r2rLoadSpan >= 0 && pgoLoadSpan >= 0)
                ? string.Format(inv, "{0:+#,##0.0;-#,##0.0;0.0} ms", pgoLoadSpan - r2rLoadSpan)
                : "N/A";
            sb.AppendLine($"| MethodLoad Wall Span | {r2rStr} | {pgoStr} | {deltaStr} |");
        }

        sb.AppendLine();

        if (hasMethodNames)
        {
            WriteMethodAnalysis(sb, r2rComp, r2rCompPgo);
        }
        else
        {
            sb.AppendLine("## Method-Level Analysis");
            sb.AppendLine();
            sb.AppendLine("⚠️ **Method names could not be extracted from event payloads.**");
            sb.AppendLine();
            sb.AppendLine("Remote EventPipe traces have truncated payloads (TraceEvent limitation with cross-platform EventPipe).");
            sb.AppendLine("Falling back to speedscope conversion for method name extraction.");
            sb.AppendLine();
        }

        File.WriteAllText(reportPath, sb.ToString());
        Console.WriteLine(sb.ToString());
        Console.WriteLine($"\nFull report saved to: {reportPath}");
    }

    static void WriteMethodAnalysis(StringBuilder sb, TraceAnalysis r2rComp, TraceAnalysis r2rCompPgo)
    {
        var pgoMissed = r2rCompPgo.JitMethods
            .Where(m => !r2rComp.JitMethods.Contains(m))
            .OrderBy(m => m, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var commonJit = r2rCompPgo.JitMethods
            .Where(m => r2rComp.JitMethods.Contains(m))
            .OrderBy(m => m, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var pgoImproved = r2rComp.JitMethods
            .Where(m => !r2rCompPgo.JitMethods.Contains(m))
            .OrderBy(m => m, StringComparer.OrdinalIgnoreCase)
            .ToList();

        sb.AppendLine($"## PGO-Missed Methods ({pgoMissed.Count})");
        sb.AppendLine();
        sb.AppendLine("Methods **JIT-compiled in R2R_COMP_PGO** but **R2R precompiled in R2R_COMP**.");
        sb.AppendLine("These are missing from the PGO `.mibc` profile.");
        sb.AppendLine();

        if (pgoMissed.Count > 0)
        {
            var grouped = pgoMissed
                .GroupBy(m => ExtractNamespace(m))
                .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase);

            foreach (var group in grouped)
            {
                sb.AppendLine($"### {group.Key}");
                sb.AppendLine();
                foreach (var method in group.OrderBy(m => m, StringComparer.OrdinalIgnoreCase))
                {
                    sb.AppendLine($"- `{method}`");
                }
                sb.AppendLine();
            }
        }
        else
        {
            sb.AppendLine("_No PGO-missed methods found._");
            sb.AppendLine();
        }

        sb.AppendLine($"## Common JIT Methods ({commonJit.Count})");
        sb.AppendLine();
        sb.AppendLine("Methods JIT-compiled in **both** configs (not in either R2R image).");
        sb.AppendLine();

        if (commonJit.Count > 0)
        {
            foreach (var method in commonJit)
                sb.AppendLine($"- `{method}`");
        }
        else
        {
            sb.AppendLine("_No common JIT methods found._");
        }
        sb.AppendLine();

        if (pgoImproved.Count > 0)
        {
            sb.AppendLine($"## PGO-Improved Methods ({pgoImproved.Count})");
            sb.AppendLine();
            sb.AppendLine("Methods JIT'd in R2R_COMP but **not** in R2R_COMP_PGO (PGO profile covered these).");
            sb.AppendLine();
            foreach (var method in pgoImproved)
                sb.AppendLine($"- `{method}`");
            sb.AppendLine();
        }
    }

    static string ExtractNamespace(string method)
    {
        int idx = method.LastIndexOf("::");
        if (idx > 0) return method.Substring(0, idx);
        int dotIdx = method.LastIndexOf('.');
        if (dotIdx > 0) return method.Substring(0, dotIdx);
        return "(unknown)";
    }

    static string FormatDelta(int baseline, int test)
    {
        int delta = test - baseline;
        if (delta > 0) return $"+{delta}";
        if (delta < 0) return $"{delta}";
        return "0";
    }

    static double CalcSpan(double first, double last)
    {
        if (first < double.MaxValue && last > double.MinValue && last > first)
            return last - first;
        return -1;
    }
}
