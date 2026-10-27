param([string]$Root='C:\Debug_ControlTower')
$ErrorActionPreference='Stop'
$paths=@(
  $Root,
  (Join-Path $Root 'scripts'),
  (Join-Path $Root 'www'),
  (Join-Path $Root 'www\data'),
  (Join-Path $Root 'RMAN_Logs'),
  (Join-Path $Root 'logs'),
  (Join-Path $Root 'evidence')
)
foreach($p in $paths){ New-Item -ItemType Directory -Force -Path $p | Out-Null }
Write-Host 'Created/verified Control Tower folders:' -ForegroundColor Green
$paths | ForEach-Object { Write-Host " - $_" }
Write-Host 'Recommended permissions:' -ForegroundColor Yellow
Write-Host ' - SQL Server Agent service account: Modify on www\data and logs'
Write-Host ' - Dashboard users: Read on www and RMAN_Logs'
Write-Host ' - Do not grant Everyone/Anonymous Full Control.'
