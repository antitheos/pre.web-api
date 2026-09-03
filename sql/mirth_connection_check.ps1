<#
    Diagnose "Cannot generate SSPI context" against the Mirth SQL server.
    Run ON THE IIS SERVER. Needs nothing installed — no sqlcmd, no RSAT.

        powershell -ExecutionPolicy Bypass -File .\mirth_connection_check.ps1

    Tries the short name, the FQDN and every resolved IP in turn. If the FQDN
    or an IP succeeds where the short name fails, the cause is conclusively a
    missing or duplicate SPN — not permissions, not the firewall, not the proc.
#>

$server   = "00-MIRTH-01"
$database = "MirthReporting"

$domain = $env:USERDNSDOMAIN
$targets = @($server)
if ($domain) { $targets += "$server.$domain" }
try {
    $targets += [System.Net.Dns]::GetHostAddresses($server) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString }
} catch { Write-Host "DNS lookup for $server failed: $($_.Exception.Message)" }

Write-Host "`nRunning as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)`n"

foreach ($t in ($targets | Select-Object -Unique)) {
    $cs = "Server=$t;Database=$database;Trusted_Connection=True;Encrypt=False;Connect Timeout=10"
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT SUSER_SNAME() + ' @ ' + @@SERVERNAME"
        Write-Host ("  OK    {0,-32} -> {1}" -f $t, $cmd.ExecuteScalar()) -ForegroundColor Green
    }
    catch {
        Write-Host ("  FAIL  {0,-32} -> {1}" -f $t, $_.Exception.Message) -ForegroundColor Red
    }
    finally { $conn.Dispose() }
}

# Which SPNs are registered? ADSI is built in, so this needs no RSAT.
Write-Host "`nSPNs matching MSSQLSvc/$server :"
try {
    $s = [adsisearcher]"(servicePrincipalName=MSSQLSvc/$server*)"
    $found = $s.FindAll()
    if ($found.Count -eq 0) {
        Write-Host "  NONE — this alone explains the SSPI error." -ForegroundColor Yellow
    }
    foreach ($r in $found) {
        Write-Host "  account: $($r.Properties.samaccountname)"
        $r.Properties.serviceprincipalname |
            Where-Object { $_ -like "MSSQLSvc/$server*" } |
            ForEach-Object { Write-Host "    $_" }
    }
} catch { Write-Host "  AD query failed: $($_.Exception.Message)" }

Write-Host "`nKerberos tickets currently held (klist):"
klist 2>&1 | Select-String "Server:" | Select-Object -First 10
