using System.Globalization;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
var conString =
    builder.Configuration.GetConnectionString("PRIDB")
    ?? throw new InvalidOperationException("Connection string 'PRIDB'" + " not found.");
builder.Services.AddDbContext<PIRDB>(opt => opt.UseSqlServer(conString));

// MirthReporting sits on a different server, so it gets its own context and
// connection string. Deliberately NOT required at startup, unlike PRIDB: the
// Volume rebuild is in progress, and a missing MIRTHDB should disable one
// endpoint rather than take down /status and /modality with it.
var mirthConString = builder.Configuration.GetConnectionString("MIRTHDB");
if (!string.IsNullOrWhiteSpace(mirthConString))
{
    builder.Services.AddDbContext<MirthDB>(opt => opt.UseSqlServer(mirthConString));
}
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

// Reviewed study volume from MirthReporting: counts per site x modality x UTC
// hour, split STAT / Routine / Other. Same UTC contract and window guard as
// /daily-ingest, which this replaces as the source for the Volume view.
//
// Omitting both bounds returns the whole table, which is the loader's normal
// call — rows arrive late by weeks, so a trailing window on review time loses
// back-loaded batches. See the proc header.
app.MapGet(
    "/site-volume",
    async (IServiceProvider services, string? from, string? to) =>
    {
        const int maxSpanDays = 400;

        // Configured separately from PRIDB; say so plainly rather than
        // failing with a dependency-injection error.
        var db = services.GetService<MirthDB>();
        if (db is null)
            return Results.Problem(
                "MIRTHDB connection string is not configured.",
                statusCode: StatusCodes.Status503ServiceUnavailable);

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

        try
        {
            var rows = await db
                .siteVolumes.FromSqlInterpolated(
                    $"EXEC dbo.pri_site_volume @FromDateUtc = {fromUtc}, @ToDateUtc = {toUtc}"
                )
                .ToListAsync();

            return Results.Ok(rows);
        }
        catch (SqlException ex)
        {
            // MIRTHDB points at a different server from PRIDB and connects
            // with a SQL login rather than Windows auth: the app server is
            // Server 2012 and the Mirth box Server 2022, and the two cannot
            // agree a Kerberos encryption type, which surfaces as "Cannot
            // generate SSPI context". A blind 500 makes a credential problem
            // indistinguishable from a broken proc, so classify it. The number
            // is enough to tell them apart without returning provider text
            // verbatim.
            var reason = ex.Number switch
            {
                18456 => "login failed for the application pool identity",
                4060 => "cannot open the database for that login",
                53 or -1 => "server not found or not reachable",
                229 or 297 => "permission denied on the stored procedure",
                2812 => "stored procedure not found",
                _ => null,
            };

            // A recognised error is classified without echoing provider text.
            // An unrecognised one is useless without it — error 0 in
            // particular is a transport failure whose whole meaning lives in
            // the message, and often in the inner exception (SSPI and Win32
            // failures nest there). This API is key-protected and internal, so
            // returning it is a reasonable trade for being able to diagnose.
            if (reason is not null)
            {
                return Results.Problem(
                    $"MIRTHDB: {reason} (SQL error {ex.Number}).",
                    statusCode: StatusCodes.Status502BadGateway
                );
            }

            var inner = ex.InnerException is null ? "" : $" | inner: {ex.InnerException.Message}";
            return Results.Problem(
                $"MIRTHDB: SQL error {ex.Number}: {ex.Message}{inner}",
                statusCode: StatusCodes.Status502BadGateway
            );
        }
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
