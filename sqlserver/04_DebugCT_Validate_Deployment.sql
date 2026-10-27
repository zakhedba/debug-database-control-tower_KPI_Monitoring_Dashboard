USE [DEBUG_CONTROL_TOWER];
GO
SET NOCOUNT ON;

PRINT '1. Configuration and monitored scope';
SELECT * FROM dbo.CT_Portal_Config ORDER BY config_key;
SELECT database_name,is_production,monitor_uptime,monitor_sla,monitor_backup,notes
FROM dbo.CT_Monitored_Database ORDER BY is_production DESC,database_name;

PRINT '2. Stable summary and health drivers';
SELECT * FROM dbo.vw_CT_Portal_Summary_Stable;
SELECT * FROM dbo.vw_CT_Portal_Health_Drivers ORDER BY display_order;

PRINT '3. KPI views';
SELECT * FROM dbo.vw_CT_Portal_Uptime_CurrentMonth ORDER BY database_name;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_SLA_Current ORDER BY avg_elapsed_ms DESC;
SELECT * FROM dbo.vw_CT_Portal_Jobs_Stable
ORDER BY CASE WHEN health_relevant=1 AND last_status='FAILED' THEN 0 ELSE 1 END,job_name;
SELECT * FROM dbo.vw_CT_Portal_Backups_Stable
ORDER BY CASE WHEN backup_status='CRITICAL' THEN 0 ELSE 1 END,database_name;
SELECT * FROM dbo.vw_CT_Portal_Memory;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_IO_Stable ORDER BY avg_io_latency_ms DESC;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_Missing_Indexes;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_Index_Fragmentation ORDER BY fragmentation_pct DESC;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_Recent_Events;
SELECT * FROM dbo.vw_CT_Portal_Incident_Monthly ORDER BY month_start;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_Tuning_Actions ORDER BY action_date DESC;

PRINT '4. I/O delta collection - first run establishes baseline, later run yields interval data';
EXEC dbo.usp_CT_Collect_IO_Delta;
SELECT TOP (50) * FROM dbo.vw_CT_Portal_IO_Stable ORDER BY avg_io_latency_ms DESC;

PRINT '5. SQL Agent job verification';
SELECT j.name,j.enabled,
       CASE h.run_status WHEN 0 THEN 'FAILED' WHEN 1 THEN 'SUCCEEDED' WHEN 2 THEN 'RETRY'
            WHEN 3 THEN 'CANCELED' WHEN 4 THEN 'IN PROGRESS' ELSE 'UNKNOWN' END AS last_status,
       CASE WHEN h.run_date>0 THEN msdb.dbo.agent_datetime(h.run_date,h.run_time) END AS last_run,
       h.message
FROM msdb.dbo.sysjobs j
OUTER APPLY (
  SELECT TOP (1) h.run_status,h.run_date,h.run_time,h.message
  FROM msdb.dbo.sysjobhistory h
  WHERE h.job_id=j.job_id AND h.step_id=0
  ORDER BY h.instance_id DESC
) h
WHERE j.name IN (N'DEBUG_Control_Tower_Portal_Refresh',N'DEBUG_Control_Tower_Heavy_Collector')
ORDER BY j.name;
GO
