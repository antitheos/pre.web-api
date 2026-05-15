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

app.Run();
