using System.ComponentModel.DataAnnotations;
using Microsoft.EntityFrameworkCore;

public class SiteStatus
{
    [Key]
    public required string siteName { get; set; }
    public int workloadCount { get; set; }
    public DateTime fetchDate { get; set; }

    public int Assigned_Under_24 { get; set; }
    public int Assigned_Under_48 { get; set; }
    public int Assigned_Under_72 { get; set; }
    public int Assigned_Over_72 { get; set; }
}
