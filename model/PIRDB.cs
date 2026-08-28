using Microsoft.EntityFrameworkCore;

class PIRDB : DbContext
{
    public PIRDB(DbContextOptions<PIRDB> options)
        : base(options) { }

    public DbSet<SiteStatus> siteStatuses => Set<SiteStatus>();

    public DbSet<SiteModalityStatus> siteModalityStatuses => Set<SiteModalityStatus>();

    public DbSet<SiteDailyIngest> siteDailyIngests => Set<SiteDailyIngest>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<SiteModalityStatus>()
            .HasKey(s => new { s.siteName, s.modality });

        // Keyless rather than a composite key like SiteModalityStatus above:
        // these rows are stored procedure output with no identity, and a key
        // spanning an hour bucket invites change-tracking surprises.
        modelBuilder.Entity<SiteDailyIngest>().HasNoKey();

        // SQL returns datetime2 with no zone, so EF hands back
        // DateTimeKind.Unspecified and System.Text.Json emits no trailing Z.
        // The proc's contract is UTC, so stamp the Kind on read and let the
        // wire format say so.
        modelBuilder
            .Entity<SiteDailyIngest>()
            .Property(e => e.activityHourUtc)
            .HasConversion(v => v, v => DateTime.SpecifyKind(v, DateTimeKind.Utc));
    }
}
