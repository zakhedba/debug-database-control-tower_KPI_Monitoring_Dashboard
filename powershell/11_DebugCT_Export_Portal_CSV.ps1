param(
    [string]$SqlInstance = "localhost",
    [string]$Database    = "DEBUG_CONTROL_TOWER",
    [string]$OutputDir   = "C:\Debug_ControlTower\www\data"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$started = Get-Date
$errors = New-Object System.Collections.Generic.List[string]

function Invoke-ControlTowerQuery {
    param(
        [Parameter(Mandatory=$true)][string]$Query,
        [int]$TimeoutSeconds = 45
    )

    $cs = "Server=$SqlInstance;Database=$Database;Integrated Security=SSPI;Application Name=Debug Database Control Tower Exporter;"
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cmd = $cn.CreateCommand()
    $cmd.CommandTimeout = $TimeoutSeconds
    $cmd.CommandText = $Query
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $dt = New-Object System.Data.DataTable

    try {
        $cn.Open()
        [void]$da.Fill($dt)
        return $dt
    }
    finally {
        $da.Dispose()
        $cmd.Dispose()
        $cn.Dispose()
    }
}

function Write-AtomicCsv {
    param(
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)]$Data
    )

    $final = Join-Path $OutputDir $FileName
    $temp = Join-Path $OutputDir ("." + $FileName + "." + [Guid]::NewGuid().ToString("N") + ".tmp")

    try {
        @($Data) | Export-Csv -Path $temp -NoTypeInformation -Encoding UTF8

        $done = $false
        for($attempt=1; $attempt -le 10 -and -not $done; $attempt++) {
            try {
                Move-Item -Force -Path $temp -Destination $final -ErrorAction Stop
                $done = $true
            }
            catch {
                if($attempt -eq 10) { throw }
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }
    finally {
        if(Test-Path $temp) {
            Remove-Item -Force $temp -ErrorAction SilentlyContinue
        }
    }
}

function Export-QueryCsv {
    param(
        [string]$FileName,
        [string]$Query,
        [int]$TimeoutSeconds = 45,
        [switch]$Core
    )

    try {
        $data = Invoke-ControlTowerQuery -Query $Query -TimeoutSeconds $TimeoutSeconds
        Write-AtomicCsv -FileName $FileName -Data $data
        return $true
    }
    catch {
        $msg = "$FileName : $($_.Exception.Message)"
        $errors.Add($msg)
        Write-Warning $msg
        if($Core) { throw }
        return $false
    }
}

function Due {
    param([string]$FileName,[int]$Minutes)
    $p = Join-Path $OutputDir $FileName
    if(-not (Test-Path $p)) { return $true }
    if($Minutes -le 1) { return $true }
    return ((Get-Date).Minute % $Minutes -eq 0)
}

# Core collector + interval I/O. Existing collector retains your history/evidence.
Invoke-ControlTowerQuery -Query @"
EXEC dbo.usp_CT_Collect_1Min;
EXEC dbo.usp_CT_Collect_IO_Delta;
"@ -TimeoutSeconds 45 | Out-Null

# Core files: must succeed every minute.
Export-QueryCsv -Core -FileName "summary.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Summary_Stable;"
Export-QueryCsv -Core -FileName "uptime.csv"  -Query "SELECT * FROM dbo.vw_CT_Portal_Uptime_CurrentMonth ORDER BY database_name;"
Export-QueryCsv -Core -FileName "jobs.csv"    -Query "SELECT * FROM dbo.vw_CT_Portal_Jobs_Stable ORDER BY CASE WHEN health_relevant=1 AND last_status='FAILED' THEN 0 WHEN last_status='FAILED' THEN 1 ELSE 2 END, job_name;"
Export-QueryCsv -Core -FileName "backups.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Backups_Stable ORDER BY CASE WHEN backup_status='CRITICAL' THEN 0 ELSE 1 END, database_name;"
Export-QueryCsv -Core -FileName "memory.csv"  -Query "SELECT * FROM dbo.vw_CT_Portal_Memory;"
Export-QueryCsv -Core -FileName "io.csv"      -Query "SELECT * FROM dbo.vw_CT_Portal_IO_Stable ORDER BY avg_io_latency_ms DESC;"
Export-QueryCsv -Core -FileName "health_drivers.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Health_Drivers ORDER BY display_order;"

# Operational evidence: inexpensive and useful each minute.
Export-QueryCsv -FileName "events.csv"    -Query "SELECT * FROM dbo.vw_CT_Portal_Recent_Events;"
Export-QueryCsv -FileName "incidents.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Incident_Monthly ORDER BY month_start;"

# Expensive/noisy datasets are deliberately staggered.
if(Due "sla.csv" 5) {
    Export-QueryCsv -FileName "sla.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_SLA_Current ORDER BY avg_elapsed_ms DESC;" -TimeoutSeconds 60
}
if(Due "tuning_actions.csv" 5) {
    Export-QueryCsv -FileName "tuning_actions.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Tuning_Actions ORDER BY action_date DESC;"
}
if(Due "missing_indexes.csv" 15) {
    Export-QueryCsv -FileName "missing_indexes.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Missing_Indexes;" -TimeoutSeconds 60
}
if(Due "fragmentation.csv" 10) {
    Export-QueryCsv -FileName "fragmentation.csv" -Query "SELECT * FROM dbo.vw_CT_Portal_Index_Fragmentation ORDER BY fragmentation_pct DESC;" -TimeoutSeconds 60
}

$status = [pscustomobject]@{
    Server        = $SqlInstance
    Database      = $Database
    ExportedAt    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    DurationSec   = [math]::Round(((Get-Date)-$started).TotalSeconds,2)
    Status        = $(if($errors.Count -eq 0){"OK"}else{"WARNING"})
    ErrorCount    = $errors.Count
    Errors        = ($errors -join " | ")
}

Write-AtomicCsv -FileName "export_status.csv" -Data @($status)

if($errors.Count -gt 0) {
    Write-Warning ("Stable exporter completed with {0} non-core error(s)." -f $errors.Count)
}
