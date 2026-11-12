using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ElrdBackend.Alamos;
using ElrdBackend.Debug;
using ElrdBackend.Json;
using ElrdBackend.Mqtt;
using ElrdBackend.Options;
using ElrdBackend.Security;
using ElrdBackend.Storage;
using Microsoft.Extensions.Options;

namespace ElrdBackend.Api;

public sealed record OrganisationDto(string Id, string Name, string ApiKeyHint, DateTimeOffset CreatedAt, int AlarmCount, string Topic);
public sealed record CreateOrganisationRequest(string Id, string Name);
public sealed record OrganisationKeyDto(OrganisationDto Organisation, string ApiKey);
public sealed record StatusDto(string Version, bool DebugEnabled, int RetentionHours, MqttStatus Mqtt, int Organisations, int Alarms);
public sealed record CreateTestAlarmRequest(string? SampleId, string? Via);
public sealed record SimulateRequest(string Change, string? Via);
public sealed record RawRequest(string Json, string? Via);
public sealed record DeliveryDto(string Via, string Outcome, string Message, AlarmDto? Alarm);
public sealed record DebugInfoDto(IReadOnlyList<SampleInfo> Samples, IReadOnlyList<ChangeInfo> Changes);

/// <summary>
/// Verwaltung (Organisationen, Status) und – wenn eingeschaltet – Debug-Funktionen.
/// Alles nur mit Admin-Schlüssel (<c>X-Admin-Key</c>). Die Seite unter „/“ nutzt diese Aufrufe.
/// </summary>
public static class AdminEndpoints
{
    public static void MapAdminEndpoints(this IEndpointRouteBuilder routes)
    {
        var admin = routes.MapGroup("/admin/api").AddEndpointFilter<AdminKeyFilter>();

        admin.MapGet("/status", (IOptions<BackendOptions> options, MqttBridge mqtt, DataStore store) =>
        {
            var (organisations, alarms) = store.Read(state => (state.Organisations.Count, state.Alarms.Count));
            return new StatusDto(BackendApp.Version, options.Value.Debug.Enabled, options.Value.Retention.Hours, mqtt.Status, organisations, alarms);
        });

        admin.MapGet("/organisations", (Organisations organisations, DataStore store, MqttBridge mqtt) =>
            organisations.All().Select(o => ToDto(o, store, mqtt)).ToList());

        admin.MapPost("/organisations", (CreateOrganisationRequest request, Organisations organisations, DataStore store, MqttBridge mqtt) =>
        {
            try
            {
                var (organisation, key) = organisations.Create(request.Id ?? "", request.Name ?? "");
                return Results.Ok(new OrganisationKeyDto(ToDto(organisation, store, mqtt), key));
            }
            catch (ArgumentException error)
            {
                return Results.Problem(title: "Organisation nicht angelegt", detail: error.Message, statusCode: StatusCodes.Status400BadRequest);
            }
        });

        admin.MapPost("/organisations/{id}/key", (string id, Organisations organisations, DataStore store, MqttBridge mqtt) =>
        {
            var key = organisations.RenewKey(id);
            var organisation = organisations.All().FirstOrDefault(o => o.Id == id);
            return key is null || organisation is null ? Results.NotFound() : Results.Ok(new OrganisationKeyDto(ToDto(organisation, store, mqtt), key));
        });

        admin.MapDelete("/organisations/{id}", (string id, Organisations organisations) =>
            organisations.Delete(id) ? Results.NoContent() : Results.NotFound());

        // MARK: Debug

        var debug = admin.MapGroup("/debug").AddEndpointFilter<DebugEnabledFilter>();

        debug.MapGet("/info", () => new DebugInfoDto(SampleAlarms.All, SampleAlarms.Changes));

        debug.MapGet("/{org}/alarms", (string org, DataStore store) =>
            store.Read(state => state.Alarms
                .Where(a => a.OrganisationId == org)
                .OrderByDescending(a => a.UpdatedAt)
                .Select(AlarmDto.From)
                .ToList()));

        debug.MapPost("/{org}/alarms", async (string org, CreateTestAlarmRequest request, Delivery delivery, TimeProvider time, CancellationToken token) =>
        {
            JsonObject envelope;
            try { envelope = SampleAlarms.Create(request.SampleId ?? "vu", time.GetUtcNow()); }
            catch (ArgumentException error) { return Results.Problem(detail: error.Message, statusCode: 400); }
            return await delivery.DeliverAsync(org, envelope, request.Via, token);
        });

        debug.MapPost("/{org}/alarms/{id:guid}/simulate", async (string org, Guid id, SimulateRequest request, DataStore store, Delivery delivery, TimeProvider time, CancellationToken token) =>
        {
            var alarm = store.Read(state => state.Alarms.Where(a => a.OrganisationId == org && a.Id == id).Select(DataStore.Copy).FirstOrDefault());
            if (alarm is null) return Results.NotFound();
            JsonObject envelope;
            try { envelope = SampleAlarms.Change(alarm, request.Change, time.GetUtcNow()); }
            catch (ArgumentException error) { return Results.Problem(detail: error.Message, statusCode: 400); }
            return await delivery.DeliverAsync(org, envelope, request.Via, token);
        });

        debug.MapPost("/{org}/raw", async (string org, RawRequest request, Delivery delivery, CancellationToken token) =>
        {
            JsonNode? node;
            try { node = JsonNode.Parse(request.Json ?? ""); }
            catch (JsonException error) { return Results.Problem(title: "Kein gültiges JSON", detail: error.Message, statusCode: 400); }
            if (node is not JsonObject envelope) return Results.Problem(detail: "JSON-Objekt erwartet.", statusCode: 400);
            return await delivery.DeliverAsync(org, envelope, request.Via, token);
        });

        debug.MapDelete("/{org}/alarms/{id:guid}", (string org, Guid id, DataStore store) =>
            store.Write(state => state.Alarms.RemoveAll(a => a.OrganisationId == org && a.Id == id)) > 0 ? Results.NoContent() : Results.NotFound());

        debug.MapDelete("/{org}/alarms", (string org, DataStore store) =>
        {
            var removed = store.Write(state => state.Alarms.RemoveAll(a => a.OrganisationId == org));
            return Results.Ok(new { removed });
        });
    }

    private static OrganisationDto ToDto(Organisation organisation, DataStore store, MqttBridge mqtt) => new(
        organisation.Id,
        organisation.Name,
        organisation.ApiKeyHint,
        organisation.CreatedAt,
        store.Read(state => state.Alarms.Count(a => a.OrganisationId == organisation.Id)),
        mqtt.AlarmTopic(organisation.Id));

    private sealed class DebugEnabledFilter(IOptions<BackendOptions> options) : IEndpointFilter
    {
        public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
        {
            if (!options.Value.Debug.Enabled)
            {
                return Results.Problem(title: "Debug ausgeschaltet", detail: "Elrd:Debug:Enabled ist nicht gesetzt.", statusCode: StatusCodes.Status404NotFound);
            }
            return await next(context);
        }
    }
}

/// <summary>Stellt eine V2-Nachricht zu: direkt in die Schublade oder über den Broker (ganze Kette).</summary>
public sealed class Delivery(AlarmIngest ingest, MqttBridge mqtt, Organisations organisations)
{
    public async Task<IResult> DeliverAsync(string organisationId, JsonObject envelope, string? via, CancellationToken token)
    {
        if (!organisations.Exists(organisationId)) return Results.NotFound();
        var payload = Encoding.UTF8.GetBytes(envelope.ToJsonString(JsonDefaults.Options));
        if (string.Equals(via, "mqtt", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                await mqtt.PublishAlarmAsync(organisationId, payload, token);
            }
            catch (Exception error) when (error is InvalidOperationException or MqttException or IOException)
            {
                return Results.Problem(title: "Senden über MQTT fehlgeschlagen", detail: error.Message, statusCode: StatusCodes.Status502BadGateway);
            }
            return Results.Ok(new DeliveryDto("mqtt", "Sent", $"An {mqtt.AlarmTopic(organisationId)} gesendet – kommt über das Abonnement zurück.", null));
        }
        var result = ingest.Ingest(organisationId, payload, source: "debug", isTest: true);
        var dto = new DeliveryDto("direct", result.Outcome.ToString(), result.Message, result.Alarm is null ? null : AlarmDto.From(result.Alarm));
        return result.IsSuccess ? Results.Ok(dto) : Results.BadRequest(dto);
    }
}
