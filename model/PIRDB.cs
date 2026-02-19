using Microsoft.EntityFrameworkCore;

class PIRDB : DbContext
{
    public PIRDB(DbContextOptions<PIRDB> options)
        : base(options) { }

    public DbSet<SiteStatus> siteStatuses => Set<SiteStatus>();
}
