using System.Reflection;
using ElrdBackend.Alamos;
using ElrdBackend.Api;
using ElrdBackend.Json;
using ElrdBackend.Mqtt;
using ElrdBackend.Options;
using ElrdBackend.Push;
using ElrdBackend.Security;
using ElrdBackend.Storage;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;

namespace ElrdBackend;

/// <summary>Aufbau der Web-App (auch von den Tests genutzt).</summary>
public static class BackendApp
{
    public static string Version { get; } =
        typeof(BackendApp).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    public static WebApplication Build(string[] args, Action<WebApplicationBuilder>? configure = null)
    {
        var builder = WebApplication.CreateBuilder(args);
        configure?.Invoke(builder);

        builder.Services.Configure<BackendOptions>(builder.Configuration.GetSection(BackendOptions.SectionName));
        builder.Services.ConfigureHttpJsonOptions(json => JsonDefaults.Configure(json.SerializerOptions));
        builder.Services.AddProblemDetails();
        builder.Services.TryAddTimeProvider();
        builder.Services.AddSingleton<DataStore>();
        builder.Services.AddSingleton<AlarmIngest>();
        builder.Services.AddSingleton<Organisations>();
        builder.Services.AddSingleton<AdminKey>();
        builder.Services.AddSingleton<Delivery>();
        // Schritt 144: Push-Mitteilungen (Transport in Tests ersetzbar).
        builder.Services.TryAddSingleton<PushTransport>();
        builder.Services.AddSingleton<PushNotifier>();
        builder.Services.AddSingleton<MqttBridge>();
        builder.Services.AddHostedService(provider => provider.GetRequiredService<MqttBridge>());
        builder.Services.AddSingleton<RetentionWorker>();
        builder.Services.AddHostedService(provider => provider.GetRequiredService<RetentionWorker>());
        builder.Services.Configure<ForwardedHeadersOptions>(forwarded =>
        {
            // Hinter einem Reverse Proxy (Caddy, nginx, Hoster): Schema/IP übernehmen.
            forwarded.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
            forwarded.KnownIPNetworks.Clear();
            forwarded.KnownProxies.Clear();
        });

        var app = builder.Build();
        var push = app.Services.GetRequiredService<PushNotifier>();
        app.Services.GetRequiredService<AlarmIngest>().Processed += push.OnIngest;
        app.UseForwardedHeaders();
        app.UseExceptionHandler();
        app.UseDefaultFiles();
        app.UseStaticFiles();

        app.MapGet("/health", (MqttBridge mqtt) => new
        {
            status = "ok",
            version = Version,
            mqtt = mqtt.Status.Enabled ? (mqtt.Status.Connected ? "connected" : "disconnected") : "disabled",
        });
        app.MapAppEndpoints();
        app.MapAdminEndpoints();

        WarnAboutConfiguration(app);
        return app;
    }

    private static void TryAddTimeProvider(this IServiceCollection services)
    {
        if (services.All(service => service.ServiceType != typeof(TimeProvider)))
        {
            services.AddSingleton(TimeProvider.System);
        }
    }

    private static void WarnAboutConfiguration(WebApplication app)
    {
        var options = app.Services.GetRequiredService<IOptions<BackendOptions>>().Value;
        var logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("ELRD");
        if (!app.Services.GetRequiredService<AdminKey>().IsConfigured)
        {
            logger.LogWarning("Elrd:Admin:Key fehlt – Verwaltung und Debug-Seite sind gesperrt.");
        }
        if (options.Debug.Enabled)
        {
            logger.LogWarning("Debug-Funktionen sind eingeschaltet (Elrd:Debug:Enabled). Im Echtbetrieb ausschalten.");
        }
        if (options.Mqtt.Enabled && !options.Mqtt.UseTls)
        {
            logger.LogWarning("MQTT ohne TLS – Einsatzdaten gehen unverschlüsselt über das Netz. Nur lokal zum Testen verwenden.");
        }
        if (string.IsNullOrWhiteSpace(options.Storage.EncryptionKey))
        {
            logger.LogWarning("store.json wird unverschlüsselt gespeichert (Elrd:Storage:EncryptionKey).");
        }
    }
}
