using System.Security.Cryptography;
using System.Text;
using ElrdBackend.Options;
using Microsoft.Extensions.Options;

namespace ElrdBackend.Security;

/// <summary>Prüft den Admin-Schlüssel (Kopfzeile <c>X-Admin-Key</c>) für Verwaltung und Debug.</summary>
public sealed class AdminKey(IOptions<BackendOptions> options)
{
    public const string Header = "X-Admin-Key";
    public const int MinimumLength = 16;

    public bool IsConfigured => (options.Value.Admin.Key?.Trim().Length ?? 0) >= MinimumLength;

    public bool Matches(string? candidate)
    {
        var expected = options.Value.Admin.Key?.Trim();
        if (expected is null || expected.Length < MinimumLength || string.IsNullOrEmpty(candidate)) return false;
        // Über Hashes vergleichen: gleiche Länge, konstante Zeit.
        var a = SHA256.HashData(Encoding.UTF8.GetBytes(expected));
        var b = SHA256.HashData(Encoding.UTF8.GetBytes(candidate.Trim()));
        return CryptographicOperations.FixedTimeEquals(a, b);
    }
}

/// <summary>Endpunktfilter: nur mit gültigem Admin-Schlüssel.</summary>
public sealed class AdminKeyFilter(AdminKey adminKey) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        if (!adminKey.IsConfigured)
        {
            return Results.Problem(
                title: "Verwaltung gesperrt",
                detail: $"Elrd:Admin:Key ist nicht gesetzt (mindestens {AdminKey.MinimumLength} Zeichen).",
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }
        if (!adminKey.Matches(context.HttpContext.Request.Headers[AdminKey.Header]))
        {
            return Results.Problem(title: "Admin-Schlüssel falsch", statusCode: StatusCodes.Status401Unauthorized);
        }
        return await next(context);
    }
}
