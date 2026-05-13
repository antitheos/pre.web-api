using Microsoft.EntityFrameworkCore;

class PIRDB : DbContext
{
    public PIRDB(DbContextOptions<PIRDB> options)
        : base(options) { }

    public DbSet<SiteStatus> siteStatuses => Set<SiteStatus>();

    public DbSet<SiteModalityStatus> siteModalityStatuses => Set<SiteModalityStatus>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<SiteModalityStatus>()
            .HasKey(s => new { s.siteName, s.modality });
    }
}
