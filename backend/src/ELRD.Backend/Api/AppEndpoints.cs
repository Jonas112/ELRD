using System.Text.Json.Nodes;
using ElrdBackend.Push;
using ElrdBackend.Security;
using ElrdBackend.Storage;

namespace ElrdBackend.Api;

/// <summary>Einsatz, wie ihn die App bekommt: Verwaltungsangaben plus <c>data</c> im FE2-Format V2.</summary>
public sealed record AlarmDto(
    Guid Id,
    string ExternalId,
    int Revision,
    DateTimeOffset ReceivedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? ClosedAt,
    string? Sender,
    string Source,
    bool IsTest,
    JsonObject Data)
{
    public static AlarmDto From(StoredAlarm alarm) => new(
        alarm.Id, alarm.ExternalId, alarm.Revision, alarm.ReceivedAt, alarm.UpdatedAt, alarm.ClosedAt,
        alarm.Sender, alarm.Source, alarm.IsTest, (JsonObject)alarm.Data.DeepClone());
}

public sealed record AlarmListDto(DateTimeOffset ServerTime, IReadOnlyList<AlarmDto> Alarms);

public sealed record PingDto(string OrganisationId, string OrganisationName, DateTimeOffset ServerTime, string Version, int RetentionHours, bool PushEnabled);

/// <summary>Schritt 144: Gerät für Push-Mitteilungen anmelden.</summary>
public sealed record RegisterDeviceRequest(string? Token, string? Environment);
public sealed record RegisterDeviceDto(bool Registered, bool PushEnabled);

/// <summary>
/// Schnittstelle für die App (nur lesen). Anmeldung je Organisation mit
/// <c>Authorization: Bearer &lt;Schlüssel&gt;</c>.
/// </summary>
public static class AppEndpoints
{
    private const string OrganisationItem = "elrd.organisation";

    public static void MapAppEndpoints(this IEndpointRouteBuilder routes)
    {
        var api = routes.MapGroup("/api/v1").AddEndpointFilter<AppKeyFilter>();

        api.MapGet("/ping", (HttpContext context, TimeProvider time, Microsoft.Extensions.Options.IOptions<Options.BackendOptions> options, PushNotifier push) =>
        {
            var organisation = Current(context);
            return new PingDto(organisation.Id, organisation.Name, time.GetUtcNow(), BackendApp.Version, options.Value.Retention.Hours, push.Configured);
        });

        // Schritt 144: Gerät für Push-Mitteilungen an- bzw. abmelden.
        api.MapPost("/devices", (HttpContext context, RegisterDeviceRequest request, PushNotifier push) =>
        {
            try
            {
                push.Register(Current(context).Id, request.Token ?? "", request.Environment);
                return Results.Ok(new RegisterDeviceDto(true, push.Configured));
            }
            catch (ArgumentException error)
            {
                return Results.Problem(title: "Gerät nicht angemeldet", detail: error.Message, statusCode: StatusCodes.Status400BadRequest);
            }
        });

        api.MapDelete("/devices/{token}", (HttpContext context, string token, PushNotifier push) =>
        {
            push.Unregister(Current(context).Id, token);
            return Results.NoContent();
        });

        // Alle Einsätze der Organisation; mit since nur die danach geänderten.
        api.MapGet("/alarms", (HttpContext context, DataStore store, TimeProvider time, DateTimeOffset? since, bool? includeClosed) =>
        {
            var organisation = Current(context);
            var serverTime = time.GetUtcNow();
            var withClosed = includeClosed ?? true;
            var alarms = store.Read(state => state.Alarms
                .Where(a => a.OrganisationId == organisation.Id)
                .Where(a => since is null || a.UpdatedAt > since)
                .Where(a => withClosed || a.ClosedAt is null)
                .OrderByDescending(a => a.UpdatedAt)
                .Select(AlarmDto.From)
                .ToList());
            return new AlarmListDto(serverTime, alarms);
        });

        api.MapGet("/alarms/{id:guid}", (HttpContext context, DataStore store, Guid id) =>
        {
            var organisation = Current(context);
            var alarm = store.Read(state => state.Alarms
                .Where(a => a.OrganisationId == organisation.Id && a.Id == id)
                .Select(AlarmDto.From)
                .FirstOrDefault());
            return alarm is null ? Results.NotFound() : Results.Ok(alarm);
        });
    }

    private static Organisation Current(HttpContext context) => (Organisation)context.Items[OrganisationItem]!;

    /// <summary>Prüft den App-Schlüssel und merkt sich die Organisation für den Aufruf.</summary>
    private sealed class AppKeyFilter(Organisations organisations) : IEndpointFilter
    {
        public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
        {
            var request = context.HttpContext.Request;
            string? key = null;
            var header = request.Headers.Authorization.ToString();
            if (header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) key = header["Bearer ".Length..];
            key ??= request.Headers["X-Api-Key"].ToString();
            var organisation = organisations.Authenticate(key);
            if (organisation is null)
            {
                return Results.Problem(title: "Schlüssel ungültig", detail: "App-Schlüssel fehlt oder ist falsch.", statusCode: StatusCodes.Status401Unauthorized);
            }
            context.HttpContext.Items[OrganisationItem] = organisation;
            return await next(context);
        }
    }
}
