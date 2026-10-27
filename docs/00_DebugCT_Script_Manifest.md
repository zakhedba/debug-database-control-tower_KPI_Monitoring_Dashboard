# Debug Database Control Tower v3 — Script Manifest

## Naming convention

`NN_DebugCT_<Action>_<Component>.<ext>`

- `00–09` SQL Server repository / database objects / SQL Agent / validation / rollback
- `10–19` Windows / PowerShell automation
- `20–29` Oracle / RMAN integration
- `30–39` Web dashboard / optional IIS configuration
- `90–99` documentation / deployment notes

The `DebugCT` prefix identifies files belonging to **Debug Database Control Tower**.

## Canonical deployment order

1. `sqlserver/00_DebugCT_Create_Repository_Database.sql`
2. `sqlserver/01_DebugCT_Install_Core_Objects.sql`
3. `sqlserver/02_DebugCT_Configure_Stability_and_Policies.sql`
4. `powershell/10_DebugCT_Create_Folders.ps1`
5. Copy `powershell/11_DebugCT_Export_Portal_CSV.ps1` to `C:\Debug_ControlTower\scripts\`
6. Copy `web/30_DebugCT_Dashboard_Local_RMAN.html` to the chosen dashboard location.
7. `sqlserver/03_DebugCT_Create_SQLAgent_Jobs.sql`
8. Run the 1-minute collector twice, about 60 seconds apart, to establish interval I/O.
9. `sqlserver/04_DebugCT_Validate_Deployment.sql`
10. Optional: use `oracle/20_DebugCT_Oracle_KPI_Evidence.sql` and `oracle/21_DebugCT_Publish_RMAN_Logs.sh`.
11. Optional IIS hosting: copy `web/web.config` next to the hosted dashboard and data directory after security review.

## Safe rollback

Run `sqlserver/05_DebugCT_Disable_Monitoring_Jobs.sql` to disable the Control Tower SQL Agent jobs without dropping historical evidence.

## Runtime folders

Recommended Windows layout:

```text
C:\Debug_ControlTower\
├── scripts\
│   └── 11_DebugCT_Export_Portal_CSV.ps1
├── www\
│   └── data\
├── RMAN_Logs\
├── logs\
└── evidence\
```

## Public repository rule

Do not commit real CSV exports, RMAN logs, backup files, credentials, internal hostnames/IP addresses, ticket data, or screenshots containing confidential infrastructure information.
