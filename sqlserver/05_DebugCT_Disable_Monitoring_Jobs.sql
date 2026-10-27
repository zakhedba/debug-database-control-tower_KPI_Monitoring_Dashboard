USE [msdb];
GO
/* Safe rollback: disables only the Control Tower portal jobs. It does NOT drop evidence tables/views. */
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=N'DEBUG_Control_Tower_Portal_Refresh')
    EXEC dbo.sp_update_job @job_name=N'DEBUG_Control_Tower_Portal_Refresh',@enabled=0;
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=N'DEBUG_Control_Tower_Heavy_Collector')
    EXEC dbo.sp_update_job @job_name=N'DEBUG_Control_Tower_Heavy_Collector',@enabled=0;
SELECT name,enabled FROM dbo.sysjobs
WHERE name IN (N'DEBUG_Control_Tower_Portal_Refresh',N'DEBUG_Control_Tower_Heavy_Collector');
GO
