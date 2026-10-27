USE [msdb];
GO
/*
  Debug Control Tower - SQL Agent Scheduling V3
  Purpose: parameterised install/update of the lightweight 1-minute exporter
           and separate hourly heavy collector.

  REVIEW BEFORE RUNNING:
    @SqlInstance  - SQL Server instance hosting DEBUG_CONTROL_TOWER.
    @RootPath     - local Windows root containing scripts and www\data.
*/
DECLARE @SqlInstance nvarchar(256)=N'localhost';
DECLARE @Database sysname=N'DEBUG_CONTROL_TOWER';
DECLARE @RootPath nvarchar(1000)=N'C:\Debug_ControlTower';
DECLARE @PortalJob sysname=N'DEBUG_Control_Tower_Portal_Refresh';
DECLARE @HeavyJob sysname=N'DEBUG_Control_Tower_Heavy_Collector';
DECLARE @PortalSchedule sysname=N'DEBUG_Control_Tower_Portal_Every_1_Minute';
DECLARE @HeavySchedule sysname=N'DEBUG_Control_Tower_Heavy_Hourly';
DECLARE @Cmd nvarchar(max);

SET @Cmd=N'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
        + @RootPath + N'\scripts\11_DebugCT_Export_Portal_CSV.ps1" -SqlInstance "'
        + @SqlInstance + N'" -Database "' + @Database + N'" -OutputDir "'
        + @RootPath + N'\www\data"';

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=@PortalJob)
BEGIN
    EXEC dbo.sp_update_job @job_name=@PortalJob,@enabled=1;
    IF EXISTS (
        SELECT 1 FROM dbo.sysjobsteps s JOIN dbo.sysjobs j ON j.job_id=s.job_id
        WHERE j.name=@PortalJob AND s.step_id=1)
        EXEC dbo.sp_update_jobstep
             @job_name=@PortalJob,@step_id=1,@step_name=N'Export Portal CSV - Stable',
             @subsystem=N'CmdExec',@command=@Cmd,@retry_attempts=1,@retry_interval=1,
             @on_success_action=1,@on_fail_action=2;
    ELSE
        EXEC dbo.sp_add_jobstep
             @job_name=@PortalJob,@step_name=N'Export Portal CSV - Stable',
             @subsystem=N'CmdExec',@command=@Cmd,@retry_attempts=1,@retry_interval=1,
             @on_success_action=1,@on_fail_action=2;
END
ELSE
BEGIN
    EXEC dbo.sp_add_job @job_name=@PortalJob,@enabled=1,
         @description=N'Debug Database Control Tower lightweight one-minute collection/export.';
    EXEC dbo.sp_add_jobstep @job_name=@PortalJob,@step_name=N'Export Portal CSV - Stable',
         @subsystem=N'CmdExec',@command=@Cmd,@retry_attempts=1,@retry_interval=1,
         @on_success_action=1,@on_fail_action=2;
    EXEC dbo.sp_add_jobserver @job_name=@PortalJob;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.sysschedules WHERE name=@PortalSchedule)
    EXEC dbo.sp_add_schedule @schedule_name=@PortalSchedule,@enabled=1,
         @freq_type=4,@freq_interval=1,@freq_subday_type=4,@freq_subday_interval=1,
         @active_start_time=000000;

IF NOT EXISTS (
    SELECT 1 FROM dbo.sysjobs j
    JOIN dbo.sysjobschedules js ON js.job_id=j.job_id
    JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
    WHERE j.name=@PortalJob AND s.name=@PortalSchedule)
    EXEC dbo.sp_attach_schedule @job_name=@PortalJob,@schedule_name=@PortalSchedule;

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=@HeavyJob)
BEGIN
    EXEC dbo.sp_update_job @job_name=@HeavyJob,@enabled=1;
END
ELSE
BEGIN
    EXEC dbo.sp_add_job @job_name=@HeavyJob,@enabled=1,
         @description=N'Hourly heavy evidence collection kept out of the one-minute path.';
    EXEC dbo.sp_add_jobstep @job_name=@HeavyJob,@step_name=N'Hourly Heavy KPI Evidence',
         @subsystem=N'TSQL',@database_name=@Database,@command=N'EXEC dbo.usp_CT_Collect_60Min;',
         @retry_attempts=0,@on_success_action=1,@on_fail_action=2;
    EXEC dbo.sp_add_jobserver @job_name=@HeavyJob;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.sysschedules WHERE name=@HeavySchedule)
    EXEC dbo.sp_add_schedule @schedule_name=@HeavySchedule,@enabled=1,
         @freq_type=4,@freq_interval=1,@freq_subday_type=8,@freq_subday_interval=1,
         @active_start_time=001500;

IF NOT EXISTS (
    SELECT 1 FROM dbo.sysjobs j
    JOIN dbo.sysjobschedules js ON js.job_id=j.job_id
    JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
    WHERE j.name=@HeavyJob AND s.name=@HeavySchedule)
    EXEC dbo.sp_attach_schedule @job_name=@HeavyJob,@schedule_name=@HeavySchedule;

SELECT j.name AS job_name,j.enabled,s.name AS schedule_name
FROM dbo.sysjobs j
LEFT JOIN dbo.sysjobschedules js ON js.job_id=j.job_id
LEFT JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
WHERE j.name IN (@PortalJob,@HeavyJob)
ORDER BY j.name;
GO
