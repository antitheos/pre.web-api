using Microsoft.EntityFrameworkCore;

/// <summary>
/// MirthReporting, the reporting database behind the Volume view. A separate
/// server from peerVue, so it needs its own context and connection string —
/// a three-part name would only work within one instance.
///
/// Read-only in practice: the API calls stored procedures here and writes
/// nothing.
/// </summary>
class MirthDB : DbContext
{
    public MirthDB(DbContextOptions<MirthDB> options)
        : base(options) { }

    public DbSet<SiteVolume> siteVolumes => Set<SiteVolume>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        // Stored procedure output with no identity of its own.
        modelBuilder.Entity<SiteVolume>().HasNoKey();

        // SQL returns datetime2 with no zone, so EF hands back Unspecified and
        // System.Text.Json emits no trailing Z. The proc's contract is UTC, so
        // stamp the Kind on read and let the wire format say so.
        modelBuilder
            .Entity<SiteVolume>()
            .Property(e => e.activityHourUtc)
            .HasConversion(v => v, v => DateTime.SpecifyKind(v, DateTimeKind.Utc));
    }
}
