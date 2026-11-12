using ElrdBackend.Options;
using Microsoft.Extensions.Options;

namespace ElrdBackend.Storage;

/// <summary>
/// Löscht Einsätze, die seit <c>Elrd:Retention:Hours</c> nicht mehr geändert wurden.
/// Die Schublade ist kein Archiv – dokumentiert wird in der App.
/// </summary>
public sealed class RetentionWorker(DataStore store, IOptions<BackendOptions> options, TimeProvider time, ILogger<RetentionWorker> logger)
    : BackgroundService
{
    public int Purge()
    {
        var hours = Math.Max(1, options.Value.Retention.Hours);
        var limit = time.GetUtcNow().AddHours(-hours);
        var removed = store.Write(state => state.Alarms.RemoveAll(a => a.UpdatedAt < limit));
        if (removed > 0) logger.LogInformation("{Count} Einsätze nach {Hours} h gelöscht", removed, hours);
        return removed;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(10), time);
        do
        {
            Purge();
        }
        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false));
    }
}
