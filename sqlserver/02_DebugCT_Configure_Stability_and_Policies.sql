USE [DEBUG_CONTROL_TOWER];
GO

/* ============================================================================
   DEBUG CONTROL TOWER - STABILISATION V2
   Purpose:
     - Keep the existing collectors/history.
     - Make the live health score reflect current operational risk rather than
       stale cumulative I/O or any failure that happened at any point in 24h.
     - Separate true production databases from TEST/UAT/archive databases.
     - Add per-database backup policy and critical-job monitoring.
     - Measure I/O latency as interval deltas instead of SQL-startup lifetime averages.
   Safe behaviour:
     - This script does NOT change database recovery models.
     - This script does NOT disable SQL Agent jobs.
     - This script does NOT automatically mark databases non-production.
   ============================================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* --------------------------------------------------------------------------
   0. CURRENT SCORE BREAKDOWN
   -------------------------------------------------------------------------- */
SELECT
    server_name,
    last_refresh,
    worst_database_uptime_pct,
    pct_within_sla,
    failed_jobs_24h,
    backup_exceptions,
    available_memory_pct,
    max_io_latency_ms,
    blocking_sessions,
    health_score
FROM dbo.vw_CT_Portal_Summary;
GO

/* --------------------------------------------------------------------------
   1. REVIEW PRODUCTION SCOPE
   The original installation defaults every user DB to production.
   Review these candidates and update only databases that are genuinely
   TEST/UAT/DEV/archive/old copies.
   -------------------------------------------------------------------------- */
SELECT
    database_name,
    is_production,
    monitor_uptime,
    monitor_sla,
    monitor_backup,
    CASE
      WHEN database_name LIKE '%test%'
        OR database_name LIKE 'tst%'
        OR database_name LIKE '%uat%'
        OR database_name LIKE '%dev%'
        OR database_name LIKE '%archive%'
        OR database_name LIKE '%old%'
        OR database_name LIKE '%copy%'
        OR database_name LIKE '%backup%'
        OR database_name LIKE '%2022%'
        OR database_name LIKE '%2023%'
        OR database_name LIKE '%2024%'
        OR database_name LIKE '%2025%'
      THEN 'REVIEW - likely non-production'
      ELSE 'REVIEW'
    END AS recommendation
FROM dbo.CT_Monitored_Database
ORDER BY recommendation DESC, database_name;
GO

/*
EXAMPLE ONLY - uncomment individual databases after confirmation:

UPDATE dbo.CT_Monitored_Database
SET is_production=0,
    monitor_uptime=0,
    monitor_sla=0,
    monitor_backup=0,
    notes='Excluded from production KPI scope after review',
    updated_at=SYSDATETIME()
WHERE database_name IN
(
    N'APP_TEST'
    --,N'REPORTING_TEST'
    --,N'ARCHIVE_COPY'
    --,N'APP_UAT'
    --,N'DEV_COPY'
);
*/

/* --------------------------------------------------------------------------
   2. CRITICAL SQL AGENT JOB MONITORING
   Only jobs that directly protect availability, backup, integrity or the
   Control Tower should affect the live health score.
   -------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CT_Job_Monitoring','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_Job_Monitoring
    (
        job_name       sysname       NOT NULL PRIMARY KEY,
        is_critical    bit           NOT NULL CONSTRAINT DF_CT_JobMon_Critical DEFAULT(0),
        category       varchar(40)   NOT NULL CONSTRAINT DF_CT_JobMon_Category DEFAULT('OTHER'),
        notes          nvarchar(500) NULL,
        updated_at     datetime2(0)  NOT NULL CONSTRAINT DF_CT_JobMon_Updated DEFAULT(SYSDATETIME())
    );
END;
GO

MERGE dbo.CT_Job_Monitoring AS T
USING
(
    SELECT N'DEBUG_Control_Tower_Portal_Refresh' AS job_name,1 AS is_critical,'MONITORING' AS category,N'1-minute portal/export pipeline' AS notes
    UNION ALL SELECT N'DEBUG_Control_Tower_Heavy_Collector',1,'MONITORING',N'Hourly heavy evidence collector'
) S
ON T.job_name=S.job_name
WHEN MATCHED THEN
  UPDATE SET is_critical=S.is_critical,category=S.category,notes=S.notes,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN
  INSERT(job_name,is_critical,category,notes)
  VALUES(S.job_name,S.is_critical,S.category,S.notes);
GO

/* Register other SQL Agent jobs as non-critical by default. */
INSERT dbo.CT_Job_Monitoring(job_name,is_critical,category,notes)
SELECT j.name,0,'OTHER',N'Visible in portal but not counted in live infrastructure health score'
FROM msdb.dbo.sysjobs j
WHERE NOT EXISTS (SELECT 1 FROM dbo.CT_Job_Monitoring m WHERE m.job_name=j.name);
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Jobs_Stable
AS
WITH h AS
(
    SELECT
        j.job_id,
        j.name AS job_name,
        j.enabled,
        h.run_date,
        h.run_time,
        h.run_status,
        h.run_duration,
        h.message,
        ROW_NUMBER() OVER(PARTITION BY j.job_id ORDER BY h.instance_id DESC) rn
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.sysjobhistory h
      ON h.job_id=j.job_id
     AND h.step_id=0
)
SELECT
    h.job_name,
    h.enabled,
    ISNULL(m.is_critical,0) AS health_relevant,
    ISNULL(m.category,'OTHER') AS category,
    CASE WHEN h.run_date>0 THEN msdb.dbo.agent_datetime(h.run_date,h.run_time) END AS last_run,
    CASE h.run_status
      WHEN 0 THEN 'FAILED'
      WHEN 1 THEN 'SUCCEEDED'
      WHEN 2 THEN 'RETRY'
      WHEN 3 THEN 'CANCELED'
      WHEN 4 THEN 'IN PROGRESS'
      ELSE 'NEVER/UNKNOWN'
    END AS last_status,
    h.run_duration,
    h.message
FROM h
LEFT JOIN dbo.CT_Job_Monitoring m ON m.job_name=h.job_name
WHERE h.rn=1;
GO

/* --------------------------------------------------------------------------
   3. BACKUP POLICY BY DATABASE
   Do not hide real backup risk. Scope only true production databases and
   define whether point-in-time log backup is actually required.
   -------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CT_Backup_Policy','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_Backup_Policy
    (
        database_name       sysname NOT NULL PRIMARY KEY,
        is_enabled          bit NOT NULL CONSTRAINT DF_CT_BackupPolicy_Enabled DEFAULT(1),
        require_full        bit NOT NULL CONSTRAINT DF_CT_BackupPolicy_Full DEFAULT(1),
        full_max_hours      int NOT NULL CONSTRAINT DF_CT_BackupPolicy_FullHours DEFAULT(28),
        require_log         bit NOT NULL CONSTRAINT DF_CT_BackupPolicy_Log DEFAULT(0),
        log_max_minutes     int NOT NULL CONSTRAINT DF_CT_BackupPolicy_LogMinutes DEFAULT(120),
        notes               nvarchar(500) NULL,
        updated_at          datetime2(0) NOT NULL CONSTRAINT DF_CT_BackupPolicy_Updated DEFAULT(SYSDATETIME())
    );
END;
GO

MERGE dbo.CT_Backup_Policy AS T
USING
(
    SELECT
        d.name AS database_name,
        CAST(1 AS bit) AS is_enabled,
        CAST(1 AS bit) AS require_full,
        28 AS full_max_hours,
        CAST(CASE WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED') THEN 1 ELSE 0 END AS bit) AS require_log,
        120 AS log_max_minutes
    FROM sys.databases d
    JOIN dbo.CT_Monitored_Database m
      ON m.database_name=d.name
     AND m.is_production=1
     AND m.monitor_backup=1
    WHERE d.database_id>4
) S
ON T.database_name=S.database_name
WHEN NOT MATCHED THEN
  INSERT(database_name,is_enabled,require_full,full_max_hours,require_log,log_max_minutes)
  VALUES(S.database_name,S.is_enabled,S.require_full,S.full_max_hours,S.require_log,S.log_max_minutes);
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Backups_Stable
AS
WITH b AS
(
    SELECT
        bs.database_name,
        MAX(CASE WHEN bs.type='D' THEN bs.backup_finish_date END) AS last_full_backup,
        MAX(CASE WHEN bs.type='I' THEN bs.backup_finish_date END) AS last_diff_backup,
        MAX(CASE WHEN bs.type='L' THEN bs.backup_finish_date END) AS last_log_backup
    FROM msdb.dbo.backupset bs
    GROUP BY bs.database_name
)
SELECT
    d.name AS database_name,
    d.recovery_model_desc,
    p.require_full,
    p.full_max_hours,
    p.require_log,
    p.log_max_minutes,
    b.last_full_backup,
    b.last_diff_backup,
    b.last_log_backup,
    DATEDIFF(HOUR,b.last_full_backup,GETDATE()) AS full_backup_age_hours,
    CASE WHEN p.require_log=1 THEN DATEDIFF(MINUTE,b.last_log_backup,GETDATE()) END AS log_backup_age_minutes,
    CASE
      WHEN p.require_full=1 AND
           (b.last_full_backup IS NULL OR DATEDIFF(HOUR,b.last_full_backup,GETDATE())>p.full_max_hours)
        THEN 'CRITICAL'
      WHEN p.require_log=1 AND
           (b.last_log_backup IS NULL OR DATEDIFF(MINUTE,b.last_log_backup,GETDATE())>p.log_max_minutes)
        THEN 'CRITICAL'
      ELSE 'OK'
    END AS backup_status
FROM sys.databases d
JOIN dbo.CT_Monitored_Database m
  ON m.database_name=d.name
 AND m.is_production=1
 AND m.monitor_backup=1
JOIN dbo.CT_Backup_Policy p
  ON p.database_name=d.name
 AND p.is_enabled=1
LEFT JOIN b ON b.database_name=d.name
WHERE d.database_id>4;
GO

/* --------------------------------------------------------------------------
   4. INTERVAL I/O LATENCY
   sys.dm_io_virtual_file_stats is cumulative since SQL Server startup.
   A live dashboard should use DELTAS between snapshots.
   -------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.CT_IO_Counter_Snapshot','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_IO_Counter_Snapshot
    (
        snapshot_id       bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
        snapshot_time     datetime2(0) NOT NULL,
        database_id       int NOT NULL,
        file_id           int NOT NULL,
        num_of_reads      bigint NOT NULL,
        num_of_writes     bigint NOT NULL,
        io_stall_read_ms  bigint NOT NULL,
        io_stall_write_ms bigint NOT NULL
    );
    CREATE INDEX IX_CT_IO_Counter_Lookup
      ON dbo.CT_IO_Counter_Snapshot(database_id,file_id,snapshot_time DESC);
END;
GO

IF OBJECT_ID('dbo.CT_IO_Interval_History','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_IO_Interval_History
    (
        interval_id          bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
        snapshot_time        datetime2(0) NOT NULL,
        database_name        sysname NOT NULL,
        type_desc            nvarchar(60) NOT NULL,
        logical_file_name    sysname NOT NULL,
        physical_name        nvarchar(260) NOT NULL,
        sample_reads         bigint NOT NULL,
        sample_writes        bigint NOT NULL,
        sample_ops           bigint NOT NULL,
        avg_read_latency_ms  decimal(18,2) NULL,
        avg_write_latency_ms decimal(18,2) NULL,
        avg_io_latency_ms    decimal(18,2) NULL
    );
    CREATE INDEX IX_CT_IO_Interval_Time
      ON dbo.CT_IO_Interval_History(snapshot_time DESC,database_name);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CT_Collect_IO_Delta
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(0)=SYSDATETIME();

    CREATE TABLE #current
    (
        database_id int NOT NULL,
        file_id int NOT NULL,
        database_name sysname NOT NULL,
        type_desc nvarchar(60) NOT NULL,
        logical_file_name sysname NOT NULL,
        physical_name nvarchar(260) NOT NULL,
        num_of_reads bigint NOT NULL,
        num_of_writes bigint NOT NULL,
        io_stall_read_ms bigint NOT NULL,
        io_stall_write_ms bigint NOT NULL
    );

    INSERT #current
    SELECT
        v.database_id,
        v.file_id,
        DB_NAME(v.database_id),
        mf.type_desc,
        mf.name,
        mf.physical_name,
        v.num_of_reads,
        v.num_of_writes,
        v.io_stall_read_ms,
        v.io_stall_write_ms
    FROM sys.dm_io_virtual_file_stats(NULL,NULL) v
    JOIN sys.master_files mf
      ON mf.database_id=v.database_id
     AND mf.file_id=v.file_id
    JOIN dbo.CT_Monitored_Database m
      ON m.database_name=DB_NAME(v.database_id)
     AND m.is_production=1;

    ;WITH previous AS
    (
        SELECT
            c.*,
            p.num_of_reads AS prev_reads,
            p.num_of_writes AS prev_writes,
            p.io_stall_read_ms AS prev_read_stall,
            p.io_stall_write_ms AS prev_write_stall
        FROM #current c
        OUTER APPLY
        (
            SELECT TOP(1)
                s.num_of_reads,
                s.num_of_writes,
                s.io_stall_read_ms,
                s.io_stall_write_ms
            FROM dbo.CT_IO_Counter_Snapshot s
            WHERE s.database_id=c.database_id
              AND s.file_id=c.file_id
            ORDER BY s.snapshot_time DESC
        ) p
    ),
    delta AS
    (
        SELECT *,
            num_of_reads-ISNULL(prev_reads,num_of_reads) AS d_reads,
            num_of_writes-ISNULL(prev_writes,num_of_writes) AS d_writes,
            io_stall_read_ms-ISNULL(prev_read_stall,io_stall_read_ms) AS d_read_stall,
            io_stall_write_ms-ISNULL(prev_write_stall,io_stall_write_ms) AS d_write_stall
        FROM previous
    )
    INSERT dbo.CT_IO_Interval_History
    (
        snapshot_time,database_name,type_desc,logical_file_name,physical_name,
        sample_reads,sample_writes,sample_ops,
        avg_read_latency_ms,avg_write_latency_ms,avg_io_latency_ms
    )
    SELECT
        @now,
        database_name,
        type_desc,
        logical_file_name,
        physical_name,
        d_reads,
        d_writes,
        d_reads+d_writes,
        CAST(1.0*d_read_stall/NULLIF(d_reads,0) AS decimal(18,2)),
        CAST(1.0*d_write_stall/NULLIF(d_writes,0) AS decimal(18,2)),
        CAST(1.0*(d_read_stall+d_write_stall)/NULLIF(d_reads+d_writes,0) AS decimal(18,2))
    FROM delta
    WHERE prev_reads IS NOT NULL
      AND d_reads>=0
      AND d_writes>=0
      AND (d_reads+d_writes)>=10;  -- ignore tiny one-minute samples

    INSERT dbo.CT_IO_Counter_Snapshot
    (snapshot_time,database_id,file_id,num_of_reads,num_of_writes,io_stall_read_ms,io_stall_write_ms)
    SELECT @now,database_id,file_id,num_of_reads,num_of_writes,io_stall_read_ms,io_stall_write_ms
    FROM #current;

    DELETE dbo.CT_IO_Counter_Snapshot
    WHERE snapshot_time<DATEADD(DAY,-2,@now);

    DELETE dbo.CT_IO_Interval_History
    WHERE snapshot_time<DATEADD(DAY,-30,@now);
END;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_IO_Stable
AS
WITH x AS
(
    SELECT *,
           DENSE_RANK() OVER(ORDER BY snapshot_time DESC) AS snapshot_rank
    FROM dbo.CT_IO_Interval_History
)
SELECT
    snapshot_time,
    database_name,
    type_desc,
    logical_file_name,
    physical_name,
    sample_reads AS num_of_reads,
    sample_writes AS num_of_writes,
    avg_read_latency_ms,
    avg_write_latency_ms,
    avg_io_latency_ms,
    CASE
      WHEN avg_io_latency_ms>50 THEN 'CRITICAL'
      WHEN avg_io_latency_ms>20 THEN 'WARNING'
      ELSE 'OK'
    END AS io_status,
    sample_ops
FROM x
WHERE snapshot_rank=1;
GO

/* --------------------------------------------------------------------------
   5. STABLE SUMMARY
   Uses:
     - current/latest status of health-relevant jobs
     - policy-scoped backup compliance
     - interval I/O
     - memory pressure flags + absolute free-memory floor
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_CT_Portal_Summary_Stable
AS
WITH latest_health AS
(
    SELECT TOP(1) *
    FROM dbo.CT_System_Health_History
    ORDER BY snapshot_time DESC
),
latest_sla AS
(
    SELECT TOP(1) *
    FROM dbo.CT_SLA_History
    ORDER BY snapshot_time DESC
),
u AS
(
    SELECT
        AVG(uptime_pct) AS avg_uptime_pct,
        MIN(uptime_pct) AS worst_database_uptime_pct,
        COUNT(*) AS production_databases
    FROM dbo.vw_CT_Portal_Uptime_CurrentMonth
),
j AS
(
    SELECT
        SUM(CASE WHEN enabled=1 AND health_relevant=1 AND last_status='FAILED' THEN 1 ELSE 0 END) AS failed_critical_jobs_current
    FROM dbo.vw_CT_Portal_Jobs_Stable
),
b AS
(
    SELECT
        SUM(CASE WHEN backup_status='CRITICAL' THEN 1 ELSE 0 END) AS backup_exceptions
    FROM dbo.vw_CT_Portal_Backups_Stable
),
io AS
(
    SELECT MAX(avg_io_latency_ms) AS max_io_latency_ms
    FROM dbo.vw_CT_Portal_IO_Stable
),
mem AS
(
    SELECT
        total_physical_memory_mb,
        available_physical_memory_mb,
        available_memory_pct,
        process_physical_memory_low,
        process_virtual_memory_low,
        CASE
          WHEN process_physical_memory_low=1 OR process_virtual_memory_low=1 THEN 'CRITICAL'
          WHEN available_physical_memory_mb<2048 THEN 'CRITICAL'
          WHEN available_physical_memory_mb<6144 THEN 'WARNING'
          ELSE 'OK'
        END AS memory_status
    FROM dbo.vw_CT_Portal_Memory
)
SELECT
    h.server_name,
    h.snapshot_time AS last_refresh,
    u.production_databases,
    CAST(u.avg_uptime_pct AS decimal(6,2)) AS avg_uptime_pct,
    CAST(u.worst_database_uptime_pct AS decimal(6,2)) AS worst_database_uptime_pct,
    s.pct_within_sla,
    h.failed_jobs_24h,
    ISNULL(j.failed_critical_jobs_current,0) AS failed_critical_jobs_current,
    ISNULL(b.backup_exceptions,0) AS backup_exceptions,
    h.blocking_sessions,
    mem.available_memory_pct,
    mem.available_physical_memory_mb,
    mem.memory_status,
    CAST(io.max_io_latency_ms AS decimal(18,2)) AS max_io_latency_ms,
    CASE
      WHEN io.max_io_latency_ms IS NULL THEN 'NO SAMPLE'
      WHEN io.max_io_latency_ms>50 THEN 'CRITICAL'
      WHEN io.max_io_latency_ms>20 THEN 'WARNING'
      ELSE 'OK'
    END AS io_status,
    CAST(
        (CASE WHEN ISNULL(u.worst_database_uptime_pct,0)>=95 THEN 25 ELSE 0 END)
      + (CASE WHEN ISNULL(s.pct_within_sla,0)>=95 THEN 20 ELSE 0 END)
      + (CASE WHEN ISNULL(j.failed_critical_jobs_current,0)=0 THEN 15 ELSE 0 END)
      + (CASE WHEN ISNULL(b.backup_exceptions,0)=0 THEN 15 ELSE 0 END)
      + (CASE WHEN mem.memory_status<>'CRITICAL' THEN 10 ELSE 0 END)
      + (CASE WHEN io.max_io_latency_ms IS NULL OR io.max_io_latency_ms<=50 THEN 10 ELSE 0 END)
      + (CASE WHEN h.blocking_sessions=0 THEN 5 ELSE 0 END)
      AS int
    ) AS health_score
FROM latest_health h
CROSS JOIN latest_sla s
CROSS JOIN u
CROSS JOIN j
CROSS JOIN b
CROSS JOIN io
CROSS JOIN mem;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Health_Drivers
AS
WITH s AS (SELECT * FROM dbo.vw_CT_Portal_Summary_Stable)
SELECT 1 AS display_order,'Database uptime' AS component,25 AS weight,
       CASE WHEN worst_database_uptime_pct>=95 THEN 25 ELSE 0 END AS points,
       CAST(worst_database_uptime_pct AS varchar(40))+'%' AS current_value,
       '>=95%' AS target,
       CASE WHEN worst_database_uptime_pct>=95 THEN 'OK' ELSE 'CRITICAL' END AS status
FROM s
UNION ALL
SELECT 2,'SLA response time',20,CASE WHEN pct_within_sla>=95 THEN 20 ELSE 0 END,
       CAST(pct_within_sla AS varchar(40))+'%','>=95%',
       CASE WHEN pct_within_sla>=95 THEN 'OK' ELSE 'CRITICAL' END
FROM s
UNION ALL
SELECT 3,'Critical SQL Agent jobs',15,CASE WHEN failed_critical_jobs_current=0 THEN 15 ELSE 0 END,
       CAST(failed_critical_jobs_current AS varchar(40)),'0',
       CASE WHEN failed_critical_jobs_current=0 THEN 'OK' ELSE 'CRITICAL' END
FROM s
UNION ALL
SELECT 4,'Backup compliance',15,CASE WHEN backup_exceptions=0 THEN 15 ELSE 0 END,
       CAST(backup_exceptions AS varchar(40)),'0',
       CASE WHEN backup_exceptions=0 THEN 'OK' ELSE 'CRITICAL' END
FROM s
UNION ALL
SELECT 5,'Memory pressure',10,CASE WHEN memory_status<>'CRITICAL' THEN 10 ELSE 0 END,
       CAST(available_memory_pct AS varchar(40))+'% / '+memory_status,'No critical pressure',
       memory_status
FROM s
UNION ALL
SELECT 6,'I/O latency',10,CASE WHEN io_status<>'CRITICAL' THEN 10 ELSE 0 END,
       COALESCE(CAST(max_io_latency_ms AS varchar(40))+' ms','NO SAMPLE'),'<=50 ms',
       io_status
FROM s
UNION ALL
SELECT 7,'Blocking sessions',5,CASE WHEN blocking_sessions=0 THEN 5 ELSE 0 END,
       CAST(blocking_sessions AS varchar(40)),'0',
       CASE WHEN blocking_sessions=0 THEN 'OK' ELSE 'WARNING' END
FROM s;
GO

/* --------------------------------------------------------------------------
   6. VERIFY AFTER INSTALL
   Run the I/O delta twice, at least ~60 seconds apart, before judging I/O.
   -------------------------------------------------------------------------- */
EXEC dbo.usp_CT_Collect_IO_Delta;
GO

SELECT * FROM dbo.vw_CT_Portal_Summary_Stable;
SELECT * FROM dbo.vw_CT_Portal_Health_Drivers ORDER BY display_order;
SELECT * FROM dbo.vw_CT_Portal_Jobs_Stable
WHERE enabled=1 AND health_relevant=1
ORDER BY CASE WHEN last_status='FAILED' THEN 0 ELSE 1 END, job_name;
SELECT * FROM dbo.vw_CT_Portal_Backups_Stable
ORDER BY CASE WHEN backup_status='CRITICAL' THEN 0 ELSE 1 END, database_name;
GO

/* --------------------------------------------------------------------------
   7. DIAGNOSTIC: EXACT FAILURE MESSAGES FOR CURRENT FAILED JOBS
   -------------------------------------------------------------------------- */
;WITH x AS
(
    SELECT
        j.name AS job_name,
        h.step_id,
        h.step_name,
        h.run_status,
        msdb.dbo.agent_datetime(h.run_date,h.run_time) AS run_datetime,
        h.message,
        ROW_NUMBER() OVER
        (
            PARTITION BY j.job_id,h.step_id
            ORDER BY h.instance_id DESC
        ) AS rn
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobhistory h ON h.job_id=j.job_id
    WHERE h.run_status=0
)
SELECT job_name,step_id,step_name,run_datetime,message
FROM x
WHERE rn=1
ORDER BY run_datetime DESC;
GO

/* --------------------------------------------------------------------------
   8. MEMORY CONFIGURATION REVIEW - DO NOT AUTO-CHANGE
   -------------------------------------------------------------------------- */
SELECT
    name,
    value,
    value_in_use
FROM sys.configurations
WHERE name IN ('max server memory (MB)','min server memory (MB)');
GO

SELECT * FROM dbo.vw_CT_Portal_Memory;
GO

/*
If this is a dedicated 64-GB SQL Server and infrastructure monitoring confirms
the OS needs more headroom, a staged cap can be considered after change approval.
Do NOT run blindly:

EXEC sp_configure 'show advanced options',1;
RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 53248; -- example 52 GB cap
RECONFIGURE;
*/
