using System.Globalization;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
var conString =
    builder.Configuration.GetConnectionString("PRIDB")
    ?? throw new InvalidOperationException("Connection string 'PRIDB'" + " not found.");
builder.Services.AddDbContext<PIRDB>(opt => opt.UseSqlServer(conString));
builder.Services.AddDatabaseDeveloperPageExceptionFilter();

var app = builder.Build();
app.UseMiddleware<ApiKeyMiddleware>();

app.MapGet("/", () => "Hello World!");

app.MapGet(
    "/status",
    async (PIRDB db) => await db.siteStatuses.FromSqlRaw("EXEC dbo.pri_site_status").ToListAsync()
);

app.MapGet(
    "/modality/{siteName}",
    async (PIRDB db, string siteName) =>
    {
        var results = await db.siteModalityStatuses.FromSqlRaw("EXEC dbo.pri_site_modality_status").ToListAsync();
        return results.Where(m => m.siteName == siteName).ToList();
    }
);

app.MapGet(
    "/modality",
    async (PIRDB db) =>
    {
        var results = await db.siteModalityStatuses.FromSqlRaw("EXEC dbo.pri_site_modality_status").ToListAsync();
        return results.ToList();

    }
);

// Ingest volume: counts per site x modality x UTC hour, over a UTC window.
//
// Dates arrive as strings rather than DateTime so they can be parsed with an
// explicit UTC assumption. Minimal-API model binding would parse them against
// the server's locale, which on an Eastern host silently shifts every bucket
// by four hours — the whole point of this endpoint is that it does not.
//
// Both bounds are optional; omitting them lets the proc default to the last
// completed UTC hour.
app.MapGet(
    "/daily-ingest",
    async (PIRDB db, string? from, string? to) =>
    {
        // We do not own this database and there is no index on CreatedDate, so
        // a wide window is a heavy scan on someone else's production server.
        // 190 days covers the agreed 4-month backfill with room to spare.
        const int maxSpanDays = 190;

        if (!TryParseUtc(from, out var fromUtc))
            return Results.BadRequest("'from' is not a valid date/time.");
        if (!TryParseUtc(to, out var toUtc))
            return Results.BadRequest("'to' is not a valid date/time.");

        if (fromUtc.HasValue && toUtc.HasValue)
        {
            if (fromUtc >= toUtc)
                return Results.BadRequest("'from' must be earlier than 'to'.");

            if ((toUtc.Value - fromUtc.Value).TotalDays > maxSpanDays)
                return Results.BadRequest($"Window exceeds {maxSpanDays} days.");
        }

        var rows = await db
            .siteDailyIngests.FromSqlInterpolated(
                $"EXEC dbo.pri_site_daily_ingest @FromDateUtc = {fromUtc}, @ToDateUtc = {toUtc}"
            )
            .ToListAsync();

        return Results.Ok(rows);
    }
);

// Parses as UTC whatever the input looks like: a bare timestamp is assumed to
// be UTC, one carrying an offset is converted to it. Null/blank means "not
// supplied", which is valid and defers to the proc's own default.
static bool TryParseUtc(string? value, out DateTime? result)
{
    result = null;

    if (string.IsNullOrWhiteSpace(value))
        return true;

    if (
        !DateTime.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal,
            out var parsed
        )
    )
        return false;

    result = parsed;
    return true;
}

app.Run();
