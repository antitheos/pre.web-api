using Microsoft.EntityFrameworkCore;

/// <summary>
/// One row of MirthReporting.dbo.pri_site_volume: reviewed study counts for
/// one site, one modality bucket, one UTC hour, split by priority. Keyless —
/// stored procedure results with no identity of their own.
///
/// statCount + routineCount + otherCount = totalCount, by construction.
/// otherCount is expected to be zero; a non-zero value means the Priority
/// column holds something beyond STAT and ROUTINE, and the stacked chart
/// would not reach its own total.
///
/// Times are UTC. activityHourUtc is the canonical bucket; the other two are
/// the same instant split out, not a second source of truth.
/// </summary>
public class SiteVolume
{
    public required string siteName { get; set; }

    /// <summary>CT, MR, US, XR, NM, MG, RF or Other.</summary>
    public required string modality { get; set; }

    /// <summary>UTC instant the hour bucket starts at. The downstream key.</summary>
    public DateTime activityHourUtc { get; set; }

    public DateOnly activityDateUtc { get; set; }

    /// <summary>0-23, UTC.</summary>
    public int activityHour { get; set; }

    public int statCount { get; set; }
    public int routineCount { get; set; }
    public int otherCount { get; set; }
    public int totalCount { get; set; }
}
