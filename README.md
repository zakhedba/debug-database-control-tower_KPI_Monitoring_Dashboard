# Debug Database Control Tower — DBA KPI Evidence Portfolio

**SQL Server observability | Oracle RMAN evidence | repeatable DBA KPI reporting**

> **Status: reference implementation / not independently deployed or production-validated in this repository.** Code is supplied from the original public portfolio edition. All operational targets and thresholds are configurable and should be approved by business owners. Do not use this as evidence of achieved results until you have run controlled tests.

## The problem
Database teams need trustworthy evidence for uptime, performance, backup compliance, operational incidents, capacity and tuning. Raw screenshots and a list of jobs are insufficient for audit, executive reporting, or resilience assessments.

## What is included
- SQL Server repository schema, policies, stored procedures, collectors, views, SQL Agent scheduling, validation and safe disable.
- PowerShell automation for CSV export.
- Local HTML dashboard showing database availability, SLA, jobs, backups, memory, I/O, index candidates, fragmentation, incidents, tuning actions and weighted health indicators.
- Read-only Oracle KPI query pack and optional RMAN-log publication/viewer.
- Documentation, KPI-to-evidence map and demonstration templates.

## Architecture
```text
SQL Server estate --> DEBUG_CONTROL_TOWER --> SQL Agent / collectors
                                          |--> PowerShell CSV export --> local HTML dashboard
Oracle read-only evidence / RMAN log files ---------------------------> dashboard
                                                                |--> review/evidence pack
```

## KPI coverage and boundaries

| KPI | Existing evidence | Not proven by this repository |
| --- | --- | --- |
| Availability | Uptime history/current-month view | Full application or network uptime |
| Response-time SLA | SQL response/SLA evidence | End-user transaction SLA |
| Agent jobs | Critical job status | All external schedulers |
| Backup compliance | Policy-aware SQL backup evidence, Oracle RMAN history/log parsing | Recoverability until restore tests pass |
| Memory and I/O | Memory indicators, interval I/O deltas | Capacity forecast without trend analysis |
| Performance tuning | Index candidates, waits/I/O, tuning action register | Business improvement without benchmark results |
| Incidents | Events and monthly incident records | Complete ITSM lifecycle |
| Replication / HA / DR | Assessment templates supplied | **No implementation or live failover evidence bundled** |
| Security / audit | Oracle audit query examples, access controls guidance | Regulatory certification or complete audit programme |

Read [the KPI evidence matrix](docs/KPI_EVIDENCE_MATRIX.md) and [the resilience gaps and next steps](docs/RESILIENCE_ROADMAP.md).

## Health score versus service reliability
The source documentation defines weighted health components: uptime 25, SLA 20, jobs 15, backups 15, memory 10, I/O 10, and blocking 5 (total 100). The **default 95% monthly uptime target is a configuration default, not a recommended universal production SLA**. Set targets according to approved service levels. A dashboard health score is **not** the same as uptime or tested recovery capability.

## Reproduce in a lab (do not deploy blindly)
1. Read [the deployment order](docs/99_DebugCT_Deployment_Order.txt) and full [operations document](docs/Debug_Database_Control_Tower_Technical_Operations_Documentation_v3.docx).
2. Review scripts and configure SQL instance, monitored database scope, recovery model and backup policies for a disposable lab.
3. Apply numbered SQL scripts `00` to `02`, then run PowerShell folder creation and place exporter/dashboard files where prescribed.
4. **Review** SQL Agent job definitions, permissions, collection cost and PowerShell invocation before enabling the schedules.
5. Collect at least two 1-minute samples and run `sqlserver/04_DebugCT_Validate_Deployment.sql`.
6. Open `web/30_DebugCT_Dashboard_Local_RMAN.html` locally and select the generated CSV folder. Load only sanitised RMAN logs in a public demonstration.
7. Record tests using [the evidence template](evidence/templates/PROJECT_EVIDENCE_TEMPLATE.md). Use the safe-disable script for the documented collector rollback.

**Do not treat the supplied SQL scripts as independently security-reviewed or tested.** Lab-first, least privilege, change approval and rollback readiness are required.

## Evidence to publish next
- Sanitised screenshots of lab-only dashboard data.
- Measured uptime/SLA calculation examples and test cases.
- A successful backup **and a verified restore** with target vs actual RTO/RPO.
- HA and replication architecture decisions, lag monitoring and simulated failover test report.
- Before/after performance benchmarks, with setup, repeat counts and limitations.

## Security
Never publish live CSV exports, RMAN logs, backup files, credentials, IPs, internal hostnames, client details or production screenshots. `.gitignore` is defence-in-depth, **not** a guarantee of sanitisation. Review every committed file and its Git history. See [SECURITY.md](SECURITY.md).

## Attribution / scope
Portfolio files supplied by the project owner. The project may demonstrate engineering design and learning; do not claim production availability, compliance, implemented DR or real client outcomes without independent evidence.
