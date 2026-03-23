using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
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
    static int Main(string[] args)
    {
        // Parse arguments: <file.nettrace> [--config-name <name>]
        string? filePath = null;
        string? configName = null;

        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--config-name" && i + 1 < args.Length)
            {
                configName = args[++i];
            }
            else if (filePath == null && !args[i].StartsWith("--"))
            {
                filePath = args[i];
            }
            else
            {
                Console.Error.WriteLine($"Unknown argument: {args[i]}");
                Console.Error.WriteLine("Usage: nettrace-analyzer <file.nettrace> [--config-name <name>]");
                return 1;
            }
        }

        if (filePath == null)
        {
            Console.Error.WriteLine("Usage: nettrace-analyzer <file.nettrace> [--config-name <name>]");
            return 1;
        }

        if (!File.Exists(filePath))
        {
            Console.Error.WriteLine($"Error: File not found: {filePath}");
            return 1;
        }

        try
        {
            var analysis = AnalyzeTrace(filePath, configName ?? "");

            double jitWallSpanMs = CalcSpan(analysis.FirstJitTimestampMs, analysis.LastJitTimestampMs);
            double methodLoadWallSpanMs = CalcSpan(analysis.FirstMethodLoadTimestampMs, analysis.LastMethodLoadTimestampMs);

            var output = new
            {
                configName = analysis.ConfigName,
                traceFile = Path.GetFullPath(analysis.FilePath),
                extractedAt = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                events = new
                {
                    jitEvents = analysis.JitEventCount,
                    methodLoadEvents = analysis.MethodLoadCount,
                    r2rEvents = analysis.R2REventCount,
                    rundownMethodEvents = analysis.RundownEventCount,
                    typedEventSuccessCount = analysis.TypedEventSuccessCount,
                },
                methods = new
                {
                    jit = analysis.JitMethods.OrderBy(m => m, StringComparer.OrdinalIgnoreCase).ToList(),
                    r2r = analysis.R2RMethods.OrderBy(m => m, StringComparer.OrdinalIgnoreCase).ToList(),
                    rundown = analysis.RundownMethods.OrderBy(m => m, StringComparer.OrdinalIgnoreCase).ToList(),
                },
                timing = new
                {
                    jitFirstTimestampMs = analysis.FirstJitTimestampMs < double.MaxValue ? Math.Round(analysis.FirstJitTimestampMs, 2) : (double?)null,
                    jitLastTimestampMs = analysis.LastJitTimestampMs > double.MinValue ? Math.Round(analysis.LastJitTimestampMs, 2) : (double?)null,
                    jitWallSpanMs = jitWallSpanMs >= 0 ? Math.Round(jitWallSpanMs, 2) : (double?)null,
                    methodLoadFirstTimestampMs = analysis.FirstMethodLoadTimestampMs < double.MaxValue ? Math.Round(analysis.FirstMethodLoadTimestampMs, 2) : (double?)null,
                    methodLoadLastTimestampMs = analysis.LastMethodLoadTimestampMs > double.MinValue ? Math.Round(analysis.LastMethodLoadTimestampMs, 2) : (double?)null,
                    methodLoadWallSpanMs = methodLoadWallSpanMs >= 0 ? Math.Round(methodLoadWallSpanMs, 2) : (double?)null,
                },
            };

            var options = new JsonSerializerOptions
            {
                WriteIndented = true,
                DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            };
            Console.WriteLine(JsonSerializer.Serialize(output, options));
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: {ex.Message}");
            Console.Error.WriteLine(ex.StackTrace);
            return 1;
        }
    }

    static TraceAnalysis AnalyzeTrace(string filePath, string configName)
    {
        var analysis = new TraceAnalysis { ConfigName = configName, FilePath = filePath };
        Console.Error.WriteLine($"--- Parsing {Path.GetFileName(filePath)} ---");

        using var source = new EventPipeEventSource(filePath);

        int totalEvents = 0;
        int clrEvents = 0;
        int rundownEvents = 0;

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

        Console.Error.WriteLine($"  Total events: {totalEvents}");
        Console.Error.WriteLine($"  CLR events: {clrEvents}");
        Console.Error.WriteLine($"  Rundown events: {rundownEvents}");
        Console.Error.WriteLine($"  JIT events (MethodJittingStarted): {analysis.JitEventCount}");
        Console.Error.WriteLine($"  JIT methods with names: {analysis.JitMethods.Count}");
        Console.Error.WriteLine($"  Method loads (MethodLoadVerbose): {analysis.MethodLoadCount}");
        Console.Error.WriteLine($"  R2R events: {analysis.R2REventCount}");
        Console.Error.WriteLine($"  R2R methods with names: {analysis.R2RMethods.Count}");
        Console.Error.WriteLine($"  Rundown methods: {analysis.RundownEventCount} ({analysis.RundownMethods.Count} with names)");
        Console.Error.WriteLine($"  Typed event decode successes: {analysis.TypedEventSuccessCount}");

        if (analysis.FirstJitTimestampMs < double.MaxValue && analysis.LastJitTimestampMs > double.MinValue)
        {
            double jitSpan = analysis.LastJitTimestampMs - analysis.FirstJitTimestampMs;
            Console.Error.WriteLine($"  JIT wall span: {jitSpan:F2} ms");
        }
        if (analysis.FirstMethodLoadTimestampMs < double.MaxValue && analysis.LastMethodLoadTimestampMs > double.MinValue)
        {
            double loadSpan = analysis.LastMethodLoadTimestampMs - analysis.FirstMethodLoadTimestampMs;
            Console.Error.WriteLine($"  MethodLoad wall span: {loadSpan:F2} ms");
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

    static double CalcSpan(double first, double last)
    {
        if (first < double.MaxValue && last > double.MinValue && last > first)
            return last - first;
        return -1;
    }
}
