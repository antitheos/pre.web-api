using Microsoft.EntityFrameworkCore;

/// <summary>
/// One row of dbo.pri_site_daily_ingest: a count of ingest events for one
/// site, one modality, one UTC hour. Keyless — these are stored procedure
/// results with no identity of their own.
///
/// Times are UTC. activityHourUtc is the canonical bucket; activityDateUtc
/// and activityHour are the same instant split out for convenience, not a
/// second source of truth. Never recombine them with a local offset.
/// </summary>
public class SiteDailyIngest
{
    public required string siteName { get; set; }

    /// <summary>UTC instant the hour bucket starts at. The downstream key.</summary>
    public DateTime activityHourUtc { get; set; }

    public DateOnly activityDateUtc { get; set; }

    /// <summary>0-23, UTC.</summary>
    public int activityHour { get; set; }

    /// <summary>'(none)' where the study row or its modality is missing.</summary>
    public required string modality { get; set; }

    public int createdCount { get; set; }
    public int assignedCount { get; set; }
    public int reviewedCount { get; set; }
}
