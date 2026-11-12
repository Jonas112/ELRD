using System.Reflection;
using ElrdBackend.Tests;

// Führt alle öffentlichen statischen Methoden der Klassen mit Namen „…Tests“ aus.
var tests = typeof(Assert).Assembly.GetTypes()
    .Where(type => type.Name.EndsWith("Tests", StringComparison.Ordinal) && type.IsClass)
    .SelectMany(type => type.GetMethods(BindingFlags.Public | BindingFlags.Static).Select(method => (type, method)))
    .OrderBy(test => test.type.Name).ThenBy(test => test.method.Name)
    .ToList();

var filter = args.FirstOrDefault();
var failed = 0;
var skipped = 0;
foreach (var (type, method) in tests)
{
    var name = $"{type.Name}.{method.Name}";
    if (filter is not null && !name.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
    try
    {
        var result = method.Invoke(null, null);
        if (result is Task task) await task;
        Console.WriteLine($"  ✓ {name}");
    }
    catch (Exception error)
    {
        var inner = error is TargetInvocationException { InnerException: { } cause } ? cause : error;
        if (inner is SkipException skip)
        {
            skipped++;
            Console.WriteLine($"  – {name} (übersprungen: {skip.Message})");
            continue;
        }
        failed++;
        Console.WriteLine($"  ✗ {name}\n      {inner.GetType().Name}: {inner.Message}");
        if (inner is not AssertionException) Console.WriteLine(inner.StackTrace);
    }
}

Console.WriteLine(failed == 0
    ? $"Alle Tests bestanden ({tests.Count - skipped} ausgeführt, {skipped} übersprungen)."
    : $"{failed} Test(s) fehlgeschlagen.");
return failed == 0 ? 0 : 1;

public sealed class SkipException(string reason) : Exception(reason);
