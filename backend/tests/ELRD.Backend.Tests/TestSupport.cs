using System.Runtime.CompilerServices;
using ElrdBackend.Options;
using ElrdBackend.Storage;
using Microsoft.Extensions.Logging.Abstractions;

namespace ElrdBackend.Tests;

public sealed class AssertionException(string message) : Exception(message);

public static class Assert
{
    public static void True(bool condition, string message = "Bedingung nicht erfüllt", [CallerArgumentExpression(nameof(condition))] string? expression = null)
    {
        if (!condition) throw new AssertionException($"{message}: {expression}");
    }

    public static void Equal<T>(T expected, T actual, [CallerArgumentExpression(nameof(actual))] string? expression = null)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new AssertionException($"{expression}: erwartet „{expected}“, war „{actual}“");
        }
    }

    public static T NotNull<T>(T? value, [CallerArgumentExpression(nameof(value))] string? expression = null) where T : class =>
        value ?? throw new AssertionException($"{expression} ist null");

    public static void Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new AssertionException($"{typeof(TException).Name} erwartet");
    }
}

/// <summary>Einstellbare Uhr.</summary>
public sealed class ManualTime(DateTimeOffset start) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = start;
    public override DateTimeOffset GetUtcNow() => Now;
    public void Advance(TimeSpan span) => Now += span;
}

/// <summary>Speicher in einem frischen temporären Ordner.</summary>
public sealed class TempStore : IDisposable
{
    public string Directory { get; } = Path.Combine(Path.GetTempPath(), "elrd-test-" + Guid.NewGuid().ToString("N"));
    public BackendOptions Options { get; } = new();

    public TempStore(string? encryptionKey = null)
    {
        Options.Storage.DataDirectory = Directory;
        Options.Storage.EncryptionKey = encryptionKey;
    }

    public DataStore Open() => new(Microsoft.Extensions.Options.Options.Create(Options), NullLogger<DataStore>.Instance);

    public void Dispose()
    {
        try { System.IO.Directory.Delete(Directory, recursive: true); } catch (IOException) { }
    }
}
