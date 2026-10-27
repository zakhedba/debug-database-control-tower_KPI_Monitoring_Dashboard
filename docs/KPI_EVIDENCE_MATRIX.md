# DBA KPI definition and evidence matrix

| KPI | Definition / scoring approach | Existing source | Required verification | Candidate reporting cadence |
|---|---|---|---|---|
| Availability | Measured availability by **approved scope** and period; source document default pass rule: worst monthly uptime >=95% | `uptime.csv`, SQL availability history | Verify outages captured and approved denominator/exclusions | Monthly |
| SQL response SLA | % measured statements within documented SLA; source default pass >=95% | `sla.csv`, SLA policy/history | Confirm sampling bias, query class and percentile/transaction boundaries | Weekly/monthly |
| Critical jobs | Zero currently failed health-relevant jobs (source rule) | `jobs.csv` | Approve job classification; test failed-job alert | Daily |
| Backup compliance | Zero policy-scoped backup exceptions (source rule) | `backups.csv`, SQL backup history, Oracle RMAN query/log evidence | Check full/differential/log requirements by recovery model; prove restore separately | Daily/monthly |
| Memory pressure | Not CRITICAL (source rule) | `memory.csv` | Compare OS pressure signals and workload | Daily |
| Interval I/O latency | Source rule latest max interval <=50 ms or no sample; warning >20 ms, critical >50 ms | `io.csv` | Require sufficient delta samples; report no-data distinctly | Daily |
| Blocking | Zero blocking sessions (source rule) | summary/event history | Validate time window and workload impact | Daily |
| Tuning outcomes | Changes with benchmark and owner | `tuning_actions.csv`, `missing_indexes.csv`, `fragmentation.csv` | Before/after plans, logical reads, duration and regressions | Monthly |
| Incident reduction | Trend in classified incidents | `events.csv`, `incidents.csv` | Confirm consistent categorisation and denominator | Monthly |
| Oracle backup | RMAN history + parsed log status | RMAN query pack / dashboard | RMAN status does not establish restorable backup; test recovery | Daily/quarterly |
| Replication | **Not yet implemented in these files** | None | Document topology, lag, consistency, failover and data-loss test | Proposed |
| HA | **Not yet implemented in these files** | None | Role detection, automatic/manual failover test, RTO measurement | Proposed |
| DR readiness | **Not yet proven in these files** | Backup evidence only | Run isolated restore and DR exercise; record achieved RTO/RPO | Proposed |

The source health score weights are **25/20/15/15/10/10/5** (availability/SLA/jobs/backups/memory/I/O/blocking). Do not manipulate production scope merely to improve the score. Tailor thresholds to service tier and document approvals.
