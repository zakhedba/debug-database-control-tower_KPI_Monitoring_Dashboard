/*
  Debug SQL Server Control Tower - Live Portal Support
  Database: DEBUG_CONTROL_TOWER
  Purpose:
    - Reuse the existing DEBUG_CONTROL_TOWER database.
    - Optionally integrate with existing collector/health-check jobs if present.
    - Add low-overhead 1-minute KPI collection for the portal.
    - Add an hourly collector for heavier index-fragmentation evidence.
    - Expose stable views for CSV/Excel/portal consumption.

  IMPORTANT
    1. Review dbo.CT_Monitored_Database after install and mark only true production DBs as is_production = 1.
    2. The portal refreshes every minute; heavyweight fragmentation collection remains hourly.
    3. SQL cache/DMV statistics reset after SQL Server restart. Historical tables below preserve KPI evidence.
*/

USE [DEBUG_CONTROL_TOWER];
GO
SET NOCOUNT ON;
GO

/* ============================================================
   1. CONFIGURATION
   ============================================================ */
IF OBJECT_ID('dbo.CT_Portal_Config','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_Portal_Config
    (
        config_key   sysname        NOT NULL PRIMARY KEY,
        config_value nvarchar(4000) NOT NULL,
        description  nvarchar(1000) NULL,
        updated_at   datetime2(0)   NOT NULL CONSTRAINT DF_CT_Portal_Config_Updated DEFAULT SYSDATETIME()
    );
END;
GO

MERGE dbo.CT_Portal_Config AS T
USING (VALUES
   ('UPTIME_TARGET_PCT','95','Production database uptime target percentage'),
   ('SLA_DEFAULT_MS','2000','Default query response-time SLA in milliseconds'),
   ('SLA_TARGET_PCT','95','Target percentage of measured statements within SLA'),
   ('FULL_BACKUP_MAX_HOURS','26','Maximum age of latest full database backup'),
   ('LOG_BACKUP_MAX_MINUTES','120','Maximum age of latest log backup for FULL/BULK_LOGGED databases'),
   ('IO_WARNING_MS','20','Average file I/O latency warning threshold'),
   ('IO_CRITICAL_MS','50','Average file I/O latency critical threshold'),
   ('MEMORY_WARNING_PCT','15','Available physical memory warning threshold'),
   ('MEMORY_CRITICAL_PCT','10','Available physical memory critical threshold')
) AS S(config_key,config_value,description)
ON T.config_key=S.config_key
WHEN MATCHED THEN UPDATE SET T.description=S.description
WHEN NOT MATCHED THEN INSERT(config_key,config_value,description)
VALUES(S.config_key,S.config_value,S.description);
GO

IF OBJECT_ID('dbo.CT_Monitored_Database','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_Monitored_Database
    (
        database_name  sysname      NOT NULL PRIMARY KEY,
        is_production  bit          NOT NULL CONSTRAINT DF_CT_MonitoredDB_Prod DEFAULT (1),
        monitor_uptime bit          NOT NULL CONSTRAINT DF_CT_MonitoredDB_Uptime DEFAULT (1),
        monitor_sla    bit          NOT NULL CONSTRAINT DF_CT_MonitoredDB_SLA DEFAULT (1),
        monitor_backup bit          NOT NULL CONSTRAINT DF_CT_MonitoredDB_Backup DEFAULT (1),
        notes          nvarchar(500) NULL,
        updated_at     datetime2(0) NOT NULL CONSTRAINT DF_CT_MonitoredDB_Updated DEFAULT SYSDATETIME()
    );
END;
GO

INSERT INTO dbo.CT_Monitored_Database(database_name)
SELECT d.name
FROM sys.databases AS d
WHERE d.database_id > 4
  AND NOT EXISTS (SELECT 1 FROM dbo.CT_Monitored_Database m WHERE m.database_name=d.name);
GO

IF OBJECT_ID('dbo.CT_SLA_Config','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_SLA_Config
    (
        database_name sysname        NOT NULL PRIMARY KEY,
        application_name nvarchar(200) NULL,
        sla_ms        decimal(18,2)  NOT NULL,
        is_enabled    bit            NOT NULL CONSTRAINT DF_CT_SLA_Config_Enabled DEFAULT (1),
        owner_name    nvarchar(200)  NULL,
        notes         nvarchar(1000) NULL,
        updated_at    datetime2(0)   NOT NULL CONSTRAINT DF_CT_SLA_Config_Updated DEFAULT SYSDATETIME()
    );
END;
GO

/* ============================================================
   2. HISTORY / EVIDENCE TABLES
   ============================================================ */
IF OBJECT_ID('dbo.DBA_KPI_DB_Availability_Log','U') IS NULL
BEGIN
    CREATE TABLE dbo.DBA_KPI_DB_Availability_Log
    (
        snapshot_time datetime2(0) NOT NULL CONSTRAINT DF_DBA_KPI_Avail_Time DEFAULT SYSDATETIME(),
        server_name   sysname      NOT NULL,
        database_name sysname      NOT NULL,
        state_desc    nvarchar(60) NOT NULL,
        is_available  bit          NOT NULL,
        CONSTRAINT PK_DBA_KPI_DB_Availability_Log PRIMARY KEY CLUSTERED(snapshot_time,server_name,database_name)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.DBA_KPI_DB_Availability_Log') AND name='IX_DBA_KPI_Avail_DB_Time')
    CREATE INDEX IX_DBA_KPI_Avail_DB_Time ON dbo.DBA_KPI_DB_Availability_Log(database_name,snapshot_time) INCLUDE(is_available,state_desc);
GO

IF OBJECT_ID('dbo.CT_SLA_History','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_SLA_History
    (
        snapshot_time         datetime2(0)  NOT NULL CONSTRAINT DF_CT_SLA_History_Time DEFAULT SYSDATETIME(),
        server_name           sysname       NOT NULL,
        statements_measured   int           NOT NULL,
        statements_within_sla int           NOT NULL,
        pct_within_sla        decimal(6,2)  NULL,
        CONSTRAINT PK_CT_SLA_History PRIMARY KEY CLUSTERED(snapshot_time,server_name)
    );
END;
GO

IF OBJECT_ID('dbo.CT_System_Health_History','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_System_Health_History
    (
        snapshot_time          datetime2(0)  NOT NULL CONSTRAINT DF_CT_SystemHealth_Time DEFAULT SYSDATETIME(),
        server_name            sysname       NOT NULL,
        total_physical_mb      decimal(18,2) NULL,
        available_physical_mb  decimal(18,2) NULL,
        available_memory_pct   decimal(6,2)  NULL,
        sql_physical_memory_mb decimal(18,2) NULL,
        process_memory_low     bit           NULL,
        process_virtual_low    bit           NULL,
        blocking_sessions      int           NOT NULL,
        max_io_latency_ms      decimal(18,2) NULL,
        failed_jobs_24h        int           NOT NULL,
        backup_exceptions      int           NOT NULL,
        CONSTRAINT PK_CT_System_Health_History PRIMARY KEY CLUSTERED(snapshot_time,server_name)
    );
END;
GO

IF OBJECT_ID('dbo.CT_Index_Fragmentation_Snapshot','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_Index_Fragmentation_Snapshot
    (
        batch_id           uniqueidentifier NOT NULL,
        snapshot_time      datetime2(0)      NOT NULL,
        database_name      sysname           NOT NULL,
        schema_name        sysname           NOT NULL,
        table_name         sysname           NOT NULL,
        index_name         sysname           NULL,
        index_type_desc    nvarchar(60)      NULL,
        page_count         bigint            NOT NULL,
        fragmentation_pct  decimal(6,2)      NOT NULL,
        recommendation     varchar(40)       NOT NULL
    );
    CREATE INDEX IX_CT_IndexFrag_Batch ON dbo.CT_Index_Fragmentation_Snapshot(batch_id,fragmentation_pct DESC);
END;
GO

IF OBJECT_ID('dbo.CT_Auto_Performance_Events','U') IS NULL
BEGIN
    CREATE TABLE dbo.CT_Auto_Performance_Events
    (
        event_id        bigint IDENTITY(1,1) PRIMARY KEY,
        event_time      datetime2(0)  NOT NULL CONSTRAINT DF_CT_AutoEvent_Time DEFAULT SYSDATETIME(),
        server_name     sysname       NOT NULL,
        category        varchar(60)   NOT NULL,
        severity        varchar(20)   NOT NULL,
        object_name     nvarchar(256) NULL,
        metric_value    decimal(18,2) NULL,
        threshold_value decimal(18,2) NULL,
        detail          nvarchar(2000) NULL,
        source          varchar(30)   NOT NULL CONSTRAINT DF_CT_AutoEvent_Source DEFAULT ('CONTROL_TOWER')
    );
    CREATE INDEX IX_CT_AutoEvents_Time ON dbo.CT_Auto_Performance_Events(event_time DESC,category);
END;
GO

IF OBJECT_ID('dbo.DBA_KPI_Tuning_Actions','U') IS NULL
BEGIN
    CREATE TABLE dbo.DBA_KPI_Tuning_Actions
    (
        tuning_id          bigint IDENTITY(1,1) PRIMARY KEY,
        action_date        datetime2(0) NOT NULL CONSTRAINT DF_DBA_KPI_TuningDate DEFAULT SYSDATETIME(),
        database_name      sysname NULL,
        object_name        nvarchar(256) NULL,
        tuning_type        varchar(50) NOT NULL,
        ticket_change_ref  varchar(100) NULL,
        action_description nvarchar(2000) NOT NULL,
        before_metric_ms   decimal(18,2) NULL,
        after_metric_ms    decimal(18,2) NULL,
        evidence_location  nvarchar(1000) NULL
    );
END;
GO

IF OBJECT_ID('dbo.DBA_Performance_Incidents','U') IS NULL
BEGIN
    CREATE TABLE dbo.DBA_Performance_Incidents
    (
        incident_id      bigint IDENTITY(1,1) PRIMARY KEY,
        incident_date    datetime2(0) NOT NULL,
        ticket_reference varchar(100) NULL,
        database_name    sysname NULL,
        incident_type    varchar(100) NOT NULL,
        severity         varchar(30) NULL,
        duration_minutes int NULL,
        root_cause       nvarchar(2000) NULL,
        resolution_notes nvarchar(2000) NULL,
        status           varchar(30) NOT NULL CONSTRAINT DF_DBA_Incident_Status DEFAULT ('CLOSED')
    );
END;
GO

/* ============================================================
   3. 1-MINUTE LIGHTWEIGHT COLLECTOR
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_CT_Collect_1Min
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(0)=SYSDATETIME();
    DECLARE @default_sla_ms decimal(18,2)=TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='SLA_DEFAULT_MS'));
    DECLARE @sla_target_pct decimal(6,2)=TRY_CONVERT(decimal(6,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='SLA_TARGET_PCT'));
    DECLARE @io_critical_ms decimal(18,2)=TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='IO_CRITICAL_MS'));
    DECLARE @mem_critical_pct decimal(6,2)=TRY_CONVERT(decimal(6,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='MEMORY_CRITICAL_PCT'));
    DECLARE @full_backup_hours int=TRY_CONVERT(int,(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='FULL_BACKUP_MAX_HOURS'));
    DECLARE @log_backup_minutes int=TRY_CONVERT(int,(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='LOG_BACKUP_MAX_MINUTES'));

    /* Availability history - production DBs only */
    INSERT dbo.DBA_KPI_DB_Availability_Log(snapshot_time,server_name,database_name,state_desc,is_available)
    SELECT @now,@@SERVERNAME,d.name,d.state_desc,CONVERT(bit,CASE WHEN d.state_desc='ONLINE' THEN 1 ELSE 0 END)
    FROM sys.databases d
    JOIN dbo.CT_Monitored_Database m ON m.database_name=d.name
    WHERE m.is_production=1 AND m.monitor_uptime=1;

    /* SLA summary - USER/production databases only. Excludes msdb Database Mail WAITFOR and other system activity. */
    DECLARE @measured int=0,@within int=0,@sla_pct decimal(6,2)=NULL;
    ;WITH q AS
    (
        SELECT
            DB_NAME(st.dbid) AS database_name,
            CAST((qs.total_elapsed_time/1000.0)/NULLIF(qs.execution_count,0) AS decimal(18,2)) AS avg_elapsed_ms,
            COALESCE(sc.sla_ms,@default_sla_ms) AS sla_ms
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
        JOIN dbo.CT_Monitored_Database m
          ON m.database_name=DB_NAME(st.dbid)
         AND m.is_production=1
         AND m.monitor_sla=1
        LEFT JOIN dbo.CT_SLA_Config sc
          ON sc.database_name=DB_NAME(st.dbid)
         AND sc.is_enabled=1
        WHERE qs.execution_count>0
          AND st.dbid>4
          AND qs.last_execution_time>=DATEADD(MINUTE,-60,@now)
    )
    SELECT @measured=COUNT(*),
           @within=SUM(CASE WHEN avg_elapsed_ms<=sla_ms THEN 1 ELSE 0 END)
    FROM q;

    SET @sla_pct=CAST(100.0*@within/NULLIF(@measured,0) AS decimal(6,2));
    INSERT dbo.CT_SLA_History(snapshot_time,server_name,statements_measured,statements_within_sla,pct_within_sla)
    VALUES(@now,@@SERVERNAME,@measured,ISNULL(@within,0),@sla_pct);

    /* Memory */
    DECLARE @total_mb decimal(18,2),@avail_mb decimal(18,2),@avail_pct decimal(6,2),@sql_mb decimal(18,2),@proc_low bit,@virt_low bit;
    SELECT @total_mb=total_physical_memory_kb/1024.0,
           @avail_mb=available_physical_memory_kb/1024.0
    FROM sys.dm_os_sys_memory;
    SET @avail_pct=CAST(100.0*@avail_mb/NULLIF(@total_mb,0) AS decimal(6,2));

    SELECT @sql_mb=physical_memory_in_use_kb/1024.0,
           @proc_low=process_physical_memory_low,
           @virt_low=process_virtual_memory_low
    FROM sys.dm_os_process_memory;

    /* Blocking */
    DECLARE @blocking int;
    SELECT @blocking=COUNT(DISTINCT session_id)
    FROM sys.dm_exec_requests
    WHERE blocking_session_id>0 AND session_id<>@@SPID;

    /* File I/O - user DBs only */
    DECLARE @max_io decimal(18,2);
    SELECT @max_io=MAX(CAST(vfs.io_stall*1.0/NULLIF(vfs.num_of_reads+vfs.num_of_writes,0) AS decimal(18,2)))
    FROM sys.dm_io_virtual_file_stats(NULL,NULL) vfs
    JOIN sys.master_files mf ON mf.database_id=vfs.database_id AND mf.file_id=vfs.file_id
    JOIN dbo.CT_Monitored_Database m ON m.database_name=DB_NAME(vfs.database_id)
    WHERE m.is_production=1;

    /* Failed SQL Agent job outcomes in the last 24 hours */
    DECLARE @failed_jobs int;
    SELECT @failed_jobs=COUNT(*)
    FROM msdb.dbo.sysjobhistory h
    WHERE h.step_id=0
      AND h.run_status=0
      AND h.run_date>0
      AND msdb.dbo.agent_datetime(h.run_date,h.run_time)>=DATEADD(HOUR,-24,@now);

    /* Backup compliance - production monitored databases */
    DECLARE @backup_exceptions int;
    ;WITH b AS
    (
        SELECT bs.database_name,
               MAX(CASE WHEN bs.type='D' THEN bs.backup_finish_date END) AS last_full_backup,
               MAX(CASE WHEN bs.type='L' THEN bs.backup_finish_date END) AS last_log_backup
        FROM msdb.dbo.backupset bs
        WHERE bs.backup_finish_date>=DATEADD(DAY,-35,@now)
        GROUP BY bs.database_name
    )
    SELECT @backup_exceptions=SUM(CASE
             WHEN b.last_full_backup IS NULL OR DATEDIFF(HOUR,b.last_full_backup,@now)>@full_backup_hours THEN 1
             WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED')
                  AND (b.last_log_backup IS NULL OR DATEDIFF(MINUTE,b.last_log_backup,@now)>@log_backup_minutes) THEN 1
             ELSE 0 END)
    FROM sys.databases d
    JOIN dbo.CT_Monitored_Database m ON m.database_name=d.name AND m.is_production=1 AND m.monitor_backup=1
    LEFT JOIN b ON b.database_name=d.name
    WHERE d.database_id>4 AND d.state_desc='ONLINE';

    INSERT dbo.CT_System_Health_History
    (
        snapshot_time,server_name,total_physical_mb,available_physical_mb,available_memory_pct,
        sql_physical_memory_mb,process_memory_low,process_virtual_low,blocking_sessions,
        max_io_latency_ms,failed_jobs_24h,backup_exceptions
    )
    VALUES
    (@now,@@SERVERNAME,@total_mb,@avail_mb,@avail_pct,@sql_mb,@proc_low,@virt_low,
     ISNULL(@blocking,0),@max_io,ISNULL(@failed_jobs,0),ISNULL(@backup_exceptions,0));

    /* Auto evidence events. Dedupe identical category/object for 60 minutes. */
    INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
    SELECT @@SERVERNAME,'DATABASE_OFFLINE','CRITICAL',d.name,0,1,CONCAT('Database state = ',d.state_desc)
    FROM sys.databases d
    JOIN dbo.CT_Monitored_Database m ON m.database_name=d.name AND m.is_production=1
    WHERE d.state_desc<>'ONLINE'
      AND NOT EXISTS
          (SELECT 1 FROM dbo.CT_Auto_Performance_Events e
           WHERE e.category='DATABASE_OFFLINE' AND e.object_name=d.name AND e.event_time>=DATEADD(MINUTE,-60,@now));

    IF @sla_pct IS NOT NULL AND @sla_pct<@sla_target_pct
       AND NOT EXISTS (SELECT 1 FROM dbo.CT_Auto_Performance_Events WHERE category='SLA_SUMMARY' AND event_time>=DATEADD(MINUTE,-60,@now))
        INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
        VALUES(@@SERVERNAME,'SLA_SUMMARY','WARNING','Production query cache',@sla_pct,@sla_target_pct,'Percentage of measured production statements within SLA is below target.');

    IF @avail_pct IS NOT NULL AND @avail_pct<@mem_critical_pct
       AND NOT EXISTS (SELECT 1 FROM dbo.CT_Auto_Performance_Events WHERE category='MEMORY_LOW' AND event_time>=DATEADD(MINUTE,-60,@now))
        INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
        VALUES(@@SERVERNAME,'MEMORY_LOW','CRITICAL','Physical memory',@avail_pct,@mem_critical_pct,'Available physical memory percentage below critical threshold.');

    IF @max_io IS NOT NULL AND @max_io>@io_critical_ms
       AND NOT EXISTS (SELECT 1 FROM dbo.CT_Auto_Performance_Events WHERE category='IO_HIGH' AND event_time>=DATEADD(MINUTE,-60,@now))
        INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
        VALUES(@@SERVERNAME,'IO_HIGH','CRITICAL','Maximum production file latency',@max_io,@io_critical_ms,'Maximum average file I/O latency exceeds threshold.');

    IF ISNULL(@blocking,0)>0
       AND NOT EXISTS (SELECT 1 FROM dbo.CT_Auto_Performance_Events WHERE category='BLOCKING' AND event_time>=DATEADD(MINUTE,-60,@now))
        INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
        VALUES(@@SERVERNAME,'BLOCKING','WARNING','Blocking sessions',@blocking,0,'One or more blocked requests detected.');

    IF ISNULL(@failed_jobs,0)>0
       AND NOT EXISTS (SELECT 1 FROM dbo.CT_Auto_Performance_Events WHERE category='JOB_FAILURE' AND event_time>=DATEADD(MINUTE,-60,@now))
        INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
        VALUES(@@SERVERNAME,'JOB_FAILURE','CRITICAL','SQL Agent',@failed_jobs,0,'Failed SQL Agent job outcomes detected in the last 24 hours.');

    IF ISNULL(@backup_exceptions,0)>0
       AND NOT EXISTS (SELECT 1 FROM dbo.CT_Auto_Performance_Events WHERE category='BACKUP_EXCEPTION' AND event_time>=DATEADD(MINUTE,-60,@now))
        INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,metric_value,threshold_value,detail)
        VALUES(@@SERVERNAME,'BACKUP_EXCEPTION','CRITICAL','Backup compliance',@backup_exceptions,0,'One or more production databases are outside backup-age thresholds.');
END;
GO

/* ============================================================
   4. HOURLY HEAVY COLLECTOR - INDEX FRAGMENTATION ACROSS ALL
      MONITORED PRODUCTION DATABASES
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_CT_Collect_60Min
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @batch uniqueidentifier=NEWID(),@db sysname,@sql nvarchar(max);

    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases d
        JOIN dbo.CT_Monitored_Database m ON m.database_name=d.name
        WHERE d.database_id>4
          AND d.state_desc='ONLINE'
          AND d.is_read_only=0
          AND m.is_production=1;

    OPEN dbs;
    FETCH NEXT FROM dbs INTO @db;
    WHILE @@FETCH_STATUS=0
    BEGIN
        BEGIN TRY
            SET @sql=N'USE '+QUOTENAME(@db)+N';
              INSERT INTO DEBUG_CONTROL_TOWER.dbo.CT_Index_Fragmentation_Snapshot
              (batch_id,snapshot_time,database_name,schema_name,table_name,index_name,index_type_desc,page_count,fragmentation_pct,recommendation)
              SELECT @batch,SYSDATETIME(),DB_NAME(),s.name,t.name,i.name,ips.index_type_desc,ips.page_count,
                     CAST(ips.avg_fragmentation_in_percent AS decimal(6,2)),
                     CASE WHEN ips.avg_fragmentation_in_percent>=30 THEN ''REBUILD CANDIDATE''
                          WHEN ips.avg_fragmentation_in_percent>=10 THEN ''REORGANIZE CANDIDATE''
                          ELSE ''OK'' END
              FROM sys.dm_db_index_physical_stats(DB_ID(),NULL,NULL,NULL,''LIMITED'') ips
              JOIN sys.indexes i ON ips.object_id=i.object_id AND ips.index_id=i.index_id
              JOIN sys.tables t ON i.object_id=t.object_id
              JOIN sys.schemas s ON t.schema_id=s.schema_id
              WHERE i.index_id>0
                AND ips.page_count>=1000
                AND ips.avg_fragmentation_in_percent>=10;';
            EXEC sys.sp_executesql @sql,N'@batch uniqueidentifier',@batch=@batch;
        END TRY
        BEGIN CATCH
            INSERT dbo.CT_Auto_Performance_Events(server_name,category,severity,object_name,detail)
            VALUES(@@SERVERNAME,'FRAGMENTATION_COLLECTOR','WARNING',@db,ERROR_MESSAGE());
        END CATCH;
        FETCH NEXT FROM dbs INTO @db;
    END
    CLOSE dbs;
    DEALLOCATE dbs;

    DELETE dbo.CT_Index_Fragmentation_Snapshot WHERE snapshot_time<DATEADD(DAY,-30,SYSDATETIME());
END;
GO

/* ============================================================
   5. PORTAL VIEWS
   ============================================================ */
CREATE OR ALTER VIEW dbo.vw_CT_Portal_Uptime_CurrentMonth
AS
SELECT
    a.server_name,
    a.database_name,
    COUNT_BIG(*) AS checks_captured,
    SUM(CONVERT(bigint,CASE WHEN a.is_available=1 THEN 1 ELSE 0 END)) AS successful_checks,
    CAST(100.0*AVG(CAST(a.is_available AS decimal(10,4))) AS decimal(6,2)) AS uptime_pct,
    CASE WHEN 100.0*AVG(CAST(a.is_available AS decimal(10,4)))>=95.0 THEN 'PASS' ELSE 'BELOW 95%' END AS kpi_status,
    MAX(a.snapshot_time) AS last_check
FROM dbo.DBA_KPI_DB_Availability_Log a
JOIN dbo.CT_Monitored_Database m ON m.database_name=a.database_name AND m.is_production=1 AND m.monitor_uptime=1
WHERE a.snapshot_time>=DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1)
GROUP BY a.server_name,a.database_name;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_SLA_Current
AS
SELECT TOP (100)
    DB_NAME(st.dbid) AS database_name,
    qs.execution_count,
    qs.last_execution_time,
    CAST((qs.total_elapsed_time/1000.0)/NULLIF(qs.execution_count,0) AS decimal(18,2)) AS avg_elapsed_ms,
    CAST((qs.total_worker_time/1000.0)/NULLIF(qs.execution_count,0) AS decimal(18,2)) AS avg_cpu_ms,
    CAST(qs.total_logical_reads*1.0/NULLIF(qs.execution_count,0) AS decimal(18,2)) AS avg_logical_reads,
    CAST(qs.total_logical_writes*1.0/NULLIF(qs.execution_count,0) AS decimal(18,2)) AS avg_logical_writes,
    COALESCE(sc.sla_ms,TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='SLA_DEFAULT_MS'))) AS sla_ms,
    CASE WHEN (qs.total_elapsed_time/1000.0)/NULLIF(qs.execution_count,0)
                   <=COALESCE(sc.sla_ms,TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='SLA_DEFAULT_MS')))
         THEN 'WITHIN SLA' ELSE 'SLA BREACH' END AS sla_status,
    REPLACE(REPLACE(SUBSTRING(st.text,(qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END-qs.statement_start_offset)/2)+1),CHAR(13),' '),CHAR(10),' ') AS sql_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
JOIN dbo.CT_Monitored_Database m ON m.database_name=DB_NAME(st.dbid) AND m.is_production=1 AND m.monitor_sla=1
LEFT JOIN dbo.CT_SLA_Config sc ON sc.database_name=DB_NAME(st.dbid) AND sc.is_enabled=1
WHERE qs.execution_count>0
  AND st.dbid>4
  AND qs.last_execution_time>=DATEADD(HOUR,-24,GETDATE())
ORDER BY avg_elapsed_ms DESC;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Jobs
AS
WITH h AS
(
    SELECT j.job_id,j.name AS job_name,j.enabled,
           h.instance_id,h.run_status,h.run_date,h.run_time,h.run_duration,h.message,
           ROW_NUMBER() OVER(PARTITION BY j.job_id ORDER BY h.instance_id DESC) AS rn
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.sysjobhistory h ON h.job_id=j.job_id AND h.step_id=0
)
SELECT job_name,enabled,
       CASE WHEN run_date>0 THEN msdb.dbo.agent_datetime(run_date,run_time) END AS last_run,
       CASE run_status WHEN 0 THEN 'FAILED' WHEN 1 THEN 'SUCCEEDED' WHEN 2 THEN 'RETRY' WHEN 3 THEN 'CANCELED' WHEN 4 THEN 'IN PROGRESS' ELSE 'NEVER/UNKNOWN' END AS last_status,
       run_duration,message
FROM h
WHERE rn=1;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Backups
AS
WITH b AS
(
    SELECT bs.database_name,
           MAX(CASE WHEN bs.type='D' THEN bs.backup_finish_date END) AS last_full_backup,
           MAX(CASE WHEN bs.type='I' THEN bs.backup_finish_date END) AS last_diff_backup,
           MAX(CASE WHEN bs.type='L' THEN bs.backup_finish_date END) AS last_log_backup
    FROM msdb.dbo.backupset bs
    GROUP BY bs.database_name
)
SELECT d.name AS database_name,d.recovery_model_desc,b.last_full_backup,b.last_diff_backup,b.last_log_backup,
       DATEDIFF(HOUR,b.last_full_backup,GETDATE()) AS full_backup_age_hours,
       CASE WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED') THEN DATEDIFF(MINUTE,b.last_log_backup,GETDATE()) END AS log_backup_age_minutes,
       CASE
          WHEN b.last_full_backup IS NULL OR DATEDIFF(HOUR,b.last_full_backup,GETDATE())>TRY_CONVERT(int,(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='FULL_BACKUP_MAX_HOURS')) THEN 'CRITICAL'
          WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED') AND (b.last_log_backup IS NULL OR DATEDIFF(MINUTE,b.last_log_backup,GETDATE())>TRY_CONVERT(int,(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='LOG_BACKUP_MAX_MINUTES')) ) THEN 'CRITICAL'
          ELSE 'OK' END AS backup_status
FROM sys.databases d
JOIN dbo.CT_Monitored_Database m ON m.database_name=d.name AND m.is_production=1 AND m.monitor_backup=1
LEFT JOIN b ON b.database_name=d.name
WHERE d.database_id>4;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Memory
AS
SELECT
    CAST(sm.total_physical_memory_kb/1024.0 AS decimal(18,2)) AS total_physical_memory_mb,
    CAST(sm.available_physical_memory_kb/1024.0 AS decimal(18,2)) AS available_physical_memory_mb,
    CAST(100.0*sm.available_physical_memory_kb/NULLIF(sm.total_physical_memory_kb,0) AS decimal(6,2)) AS available_memory_pct,
    sm.system_memory_state_desc,
    CAST(pm.physical_memory_in_use_kb/1024.0 AS decimal(18,2)) AS sql_physical_memory_mb,
    CAST(pm.locked_page_allocations_kb/1024.0 AS decimal(18,2)) AS locked_pages_mb,
    pm.process_physical_memory_low,
    pm.process_virtual_memory_low
FROM sys.dm_os_sys_memory sm
CROSS JOIN sys.dm_os_process_memory pm;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_IO
AS
SELECT
    DB_NAME(vfs.database_id) AS database_name,mf.type_desc,mf.name AS logical_file_name,mf.physical_name,
    vfs.num_of_reads,vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms*1.0/NULLIF(vfs.num_of_reads,0) AS decimal(18,2)) AS avg_read_latency_ms,
    CAST(vfs.io_stall_write_ms*1.0/NULLIF(vfs.num_of_writes,0) AS decimal(18,2)) AS avg_write_latency_ms,
    CAST(vfs.io_stall*1.0/NULLIF(vfs.num_of_reads+vfs.num_of_writes,0) AS decimal(18,2)) AS avg_io_latency_ms,
    CASE WHEN vfs.io_stall*1.0/NULLIF(vfs.num_of_reads+vfs.num_of_writes,0) >= TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='IO_CRITICAL_MS')) THEN 'CRITICAL'
         WHEN vfs.io_stall*1.0/NULLIF(vfs.num_of_reads+vfs.num_of_writes,0) >= TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='IO_WARNING_MS')) THEN 'WARNING'
         ELSE 'OK' END AS io_status
FROM sys.dm_io_virtual_file_stats(NULL,NULL) vfs
JOIN sys.master_files mf ON mf.database_id=vfs.database_id AND mf.file_id=vfs.file_id
JOIN dbo.CT_Monitored_Database m ON m.database_name=DB_NAME(vfs.database_id) AND m.is_production=1;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Missing_Indexes
AS
SELECT TOP (100)
    DB_NAME(mid.database_id) AS database_name,
    OBJECT_SCHEMA_NAME(mid.object_id,mid.database_id) AS schema_name,
    OBJECT_NAME(mid.object_id,mid.database_id) AS table_name,
    migs.user_seeks,migs.user_scans,
    CAST(migs.avg_user_impact AS decimal(10,2)) AS avg_user_impact_pct,
    CAST(migs.avg_total_user_cost*migs.avg_user_impact*(migs.user_seeks+migs.user_scans) AS decimal(18,2)) AS improvement_measure,
    mid.equality_columns,mid.inequality_columns,mid.included_columns
FROM sys.dm_db_missing_index_group_stats migs
JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle=mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle=mid.index_handle
JOIN dbo.CT_Monitored_Database m ON m.database_name=DB_NAME(mid.database_id) AND m.is_production=1
ORDER BY improvement_measure DESC;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Index_Fragmentation
AS
SELECT batch_id,snapshot_time,database_name,schema_name,table_name,index_name,index_type_desc,page_count,fragmentation_pct,recommendation
FROM dbo.CT_Index_Fragmentation_Snapshot
WHERE batch_id=(SELECT TOP (1) batch_id FROM dbo.CT_Index_Fragmentation_Snapshot ORDER BY snapshot_time DESC);
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Recent_Events
AS
SELECT TOP (200) event_time,server_name,category,severity,object_name,metric_value,threshold_value,detail,source
FROM dbo.CT_Auto_Performance_Events
ORDER BY event_time DESC;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Incident_Monthly
AS
WITH n AS
(
  SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11))v(n)
),
months AS
(
  SELECT DATEFROMPARTS(YEAR(DATEADD(MONTH,-n,GETDATE())),MONTH(DATEADD(MONTH,-n,GETDATE())),1) AS month_start FROM n
),
manual_i AS
(
  SELECT DATEFROMPARTS(YEAR(incident_date),MONTH(incident_date),1) month_start,COUNT(*) cnt
  FROM dbo.DBA_Performance_Incidents
  WHERE incident_date>=DATEADD(MONTH,-11,DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1))
  GROUP BY DATEFROMPARTS(YEAR(incident_date),MONTH(incident_date),1)
),
auto_i AS
(
  SELECT DATEFROMPARTS(YEAR(event_time),MONTH(event_time),1) month_start,COUNT(*) cnt
  FROM dbo.CT_Auto_Performance_Events
  WHERE event_time>=DATEADD(MONTH,-11,DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1))
  GROUP BY DATEFROMPARTS(YEAR(event_time),MONTH(event_time),1)
),
s AS
(
  SELECT m.month_start,ISNULL(mi.cnt,0) AS manual_incidents,ISNULL(ai.cnt,0) AS control_tower_events
  FROM months m LEFT JOIN manual_i mi ON mi.month_start=m.month_start LEFT JOIN auto_i ai ON ai.month_start=m.month_start
)
SELECT month_start,manual_incidents,control_tower_events,
       LAG(manual_incidents) OVER(ORDER BY month_start) AS previous_manual_incidents,
       CASE WHEN LAG(manual_incidents) OVER(ORDER BY month_start) IS NULL THEN 'BASELINE'
            WHEN manual_incidents<LAG(manual_incidents) OVER(ORDER BY month_start) THEN 'REDUCED'
            WHEN manual_incidents=LAG(manual_incidents) OVER(ORDER BY month_start) THEN 'NO CHANGE'
            ELSE 'INCREASED' END AS manual_mom_trend
FROM s;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Tuning_Actions
AS
SELECT tuning_id,action_date,database_name,object_name,tuning_type,ticket_change_ref,before_metric_ms,after_metric_ms,
       CASE WHEN before_metric_ms>0 AND after_metric_ms IS NOT NULL THEN CAST(100.0*(before_metric_ms-after_metric_ms)/before_metric_ms AS decimal(6,2)) END AS improvement_pct,
       action_description,evidence_location
FROM dbo.DBA_KPI_Tuning_Actions;
GO

CREATE OR ALTER VIEW dbo.vw_CT_Portal_Summary
AS
WITH latest_health AS
(
  SELECT TOP (1) * FROM dbo.CT_System_Health_History ORDER BY snapshot_time DESC
),
latest_sla AS
(
  SELECT TOP (1) * FROM dbo.CT_SLA_History ORDER BY snapshot_time DESC
),
u AS
(
  SELECT AVG(uptime_pct) AS avg_uptime_pct,MIN(uptime_pct) AS worst_database_uptime_pct,COUNT(*) AS production_databases
  FROM dbo.vw_CT_Portal_Uptime_CurrentMonth
)
SELECT
  h.server_name,
  h.snapshot_time AS last_refresh,
  u.production_databases,
  CAST(u.avg_uptime_pct AS decimal(6,2)) AS avg_uptime_pct,
  CAST(u.worst_database_uptime_pct AS decimal(6,2)) AS worst_database_uptime_pct,
  s.pct_within_sla,
  h.failed_jobs_24h,
  h.backup_exceptions,
  h.blocking_sessions,
  h.available_memory_pct,
  h.max_io_latency_ms,
  CAST(
      (CASE WHEN ISNULL(u.worst_database_uptime_pct,0)>=TRY_CONVERT(decimal(6,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='UPTIME_TARGET_PCT')) THEN 25 ELSE 0 END)
    + (CASE WHEN ISNULL(s.pct_within_sla,0)>=TRY_CONVERT(decimal(6,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='SLA_TARGET_PCT')) THEN 20 ELSE 0 END)
    + (CASE WHEN h.failed_jobs_24h=0 THEN 15 ELSE 0 END)
    + (CASE WHEN h.backup_exceptions=0 THEN 15 ELSE 0 END)
    + (CASE WHEN ISNULL(h.available_memory_pct,0)>=TRY_CONVERT(decimal(6,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='MEMORY_CRITICAL_PCT')) THEN 10 ELSE 0 END)
    + (CASE WHEN ISNULL(h.max_io_latency_ms,0)<TRY_CONVERT(decimal(18,2),(SELECT config_value FROM dbo.CT_Portal_Config WHERE config_key='IO_CRITICAL_MS')) THEN 10 ELSE 0 END)
    + (CASE WHEN h.blocking_sessions=0 THEN 5 ELSE 0 END)
    AS int) AS health_score
FROM latest_health h
CROSS JOIN latest_sla s
CROSS JOIN u;
GO

/* ============================================================
   6. MANUAL TEST / SEED COMMANDS
   ============================================================ */
-- Run once after installation:
-- EXEC dbo.usp_CT_Collect_1Min;
-- EXEC dbo.usp_CT_Collect_60Min; -- Run during a suitable window; may scan indexes across production DBs.
-- SELECT * FROM dbo.vw_CT_Portal_Summary;
-- SELECT * FROM dbo.vw_CT_Portal_Uptime_CurrentMonth ORDER BY database_name;
-- SELECT * FROM dbo.vw_CT_Portal_SLA_Current;
-- SELECT * FROM dbo.vw_CT_Portal_Jobs ORDER BY last_status,job_name;
-- SELECT * FROM dbo.vw_CT_Portal_Backups ORDER BY backup_status DESC,database_name;
-- SELECT * FROM dbo.vw_CT_Portal_Memory;
-- SELECT * FROM dbo.vw_CT_Portal_IO ORDER BY avg_io_latency_ms DESC;
-- SELECT * FROM dbo.vw_CT_Portal_Missing_Indexes;
-- SELECT * FROM dbo.vw_CT_Portal_Index_Fragmentation ORDER BY fragmentation_pct DESC;
-- SELECT * FROM dbo.vw_CT_Portal_Incident_Monthly ORDER BY month_start;
GO

/* ============================================================
   7. EXISTING JOBS
   ============================================================ */
/*
   If your environment already has DBA health-check or collector jobs, leave
   them unchanged until you have validated overlap and ownership.

   The DEBUG_Control_Tower_Portal_Refresh and DEBUG_Control_Tower_Heavy_Collector
   jobs supplied with this package provide the public reference scheduling model.
*/
GO
