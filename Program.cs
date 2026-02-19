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

app.Run();
