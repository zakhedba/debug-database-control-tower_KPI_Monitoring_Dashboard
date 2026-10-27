/*
 Debug Oracle KPI Evidence Query Pack
 Run with a read-only monitoring account granted only the catalogue/dynamic view access approved by your organisation.
 IMPORTANT: AWR/ASH/DBA_HIST_* use may require Oracle Diagnostic Pack licensing. Use only where licensed/approved.
*/
SET PAGESIZE 500 LINESIZE 220 TRIMSPOOL ON VERIFY OFF FEEDBACK ON

PROMPT === 1. INSTANCE / DATABASE AVAILABILITY ===
SELECT instance_name,host_name,version,status,database_status,startup_time,logins
FROM v$instance;
SELECT name,open_mode,database_role,log_mode,force_logging
FROM v$database;
SELECT name,network_name FROM v$services ORDER BY name;

PROMPT === 2. CURRENT SQL RESPONSE / TOP SQL ===
SELECT * FROM (
  SELECT sql_id,executions,
         ROUND(elapsed_time/NULLIF(executions,0)/1000,2) avg_elapsed_ms,
         ROUND(cpu_time/NULLIF(executions,0)/1000,2) avg_cpu_ms,
         ROUND(buffer_gets/NULLIF(executions,0),2) avg_buffer_gets,
         ROUND(disk_reads/NULLIF(executions,0),2) avg_disk_reads,
         SUBSTR(sql_text,1,120) sql_text
  FROM v$sql
  WHERE executions>0
  ORDER BY elapsed_time/NULLIF(executions,0) DESC
) WHERE ROWNUM<=50;

PROMPT === 3. NON-IDLE WAIT PROFILE ===
SELECT * FROM (
  SELECT event,total_waits,ROUND(time_waited_micro/1000000,2) time_waited_s,
         ROUND(time_waited_micro/NULLIF(total_waits,0)/1000,2) avg_wait_ms
  FROM v$system_event
  WHERE wait_class<>'Idle'
  ORDER BY time_waited_micro DESC
) WHERE ROWNUM<=30;

PROMPT === 4. DATABASE ALERTS / THRESHOLDS ===
SELECT reason,metric_value,message_type,message_level,hosting_client_id,creation_time
FROM dba_outstanding_alerts
ORDER BY creation_time DESC;
SELECT metrics_name,warning_value,critical_value,observation_period,consecutive_occurrences,
       object_type,object_name,status
FROM dba_thresholds
ORDER BY object_type,object_name,metrics_name;

PROMPT === 5. TABLESPACE CAPACITY ===
WITH df AS (
 SELECT tablespace_name,SUM(bytes) bytes,SUM(maxbytes) maxbytes
 FROM dba_data_files GROUP BY tablespace_name
), fs AS (
 SELECT tablespace_name,SUM(bytes) free_bytes FROM dba_free_space GROUP BY tablespace_name
)
SELECT df.tablespace_name,
       ROUND(df.bytes/1024/1024,2) allocated_mb,
       ROUND((df.bytes-NVL(fs.free_bytes,0))/1024/1024,2) used_mb,
       ROUND(NVL(fs.free_bytes,0)/1024/1024,2) free_mb,
       ROUND(100*(df.bytes-NVL(fs.free_bytes,0))/NULLIF(df.bytes,0),2) used_pct,
       ROUND(df.maxbytes/1024/1024,2) max_mb
FROM df LEFT JOIN fs ON fs.tablespace_name=df.tablespace_name
ORDER BY used_pct DESC;

PROMPT === 6. PHYSICAL READS / WRITES BY DATAFILE ===
SELECT d.name datafile,f.phyrds reads,f.phywrts writes,(f.phyrds+f.phywrts) total_io
FROM v$filestat f JOIN v$datafile d ON d.file#=f.file#
ORDER BY total_io DESC;

PROMPT === 7. PHYSICAL I/O BY TABLESPACE ===
SELECT ts.name tablespace_name,
       SUM(fs.phyrds) reads,SUM(fs.phywrts) writes,SUM(fs.phyrds+fs.phywrts) total_io
FROM v$filestat fs
JOIN v$datafile df ON df.file#=fs.file#
JOIN v$tablespace ts ON ts.ts#=df.ts#
GROUP BY ts.name
ORDER BY total_io DESC;

PROMPT === 8. PGA / SGA ===
SELECT name,value,unit FROM v$pgastat ORDER BY name;
SELECT name,bytes,resizeable FROM v$sgainfo ORDER BY name;

PROMPT === 9. RMAN JOB HISTORY ===
SELECT session_key,input_type,status,start_time,end_time,
       ROUND(elapsed_seconds/60,2) elapsed_minutes,
       ROUND(input_bytes/1024/1024,2) input_mb,
       ROUND(output_bytes/1024/1024,2) output_mb
FROM v$rman_backup_job_details
ORDER BY start_time DESC FETCH FIRST 100 ROWS ONLY;

PROMPT === 10. ARCHIVELOG BACKUP / DELETION EVIDENCE ===
SELECT thread#,sequence#,first_time,next_time,archived,deleted,backup_count
FROM v$archived_log
ORDER BY first_time DESC FETCH FIRST 100 ROWS ONLY;

PROMPT === 11. AUDIT ACTIVITY SUMMARY ===
SELECT username,action_name,returncode,COUNT(*) audit_count
FROM dba_audit_trail
WHERE timestamp>=SYSDATE-30
GROUP BY username,action_name,returncode
ORDER BY audit_count DESC;

PROMPT === 12. OPTIONAL AWR TREND - RUN ONLY IF LICENSED/APPROVED ===
-- SELECT ... FROM dba_hist_sqlstat / dba_hist_snapshot as approved by your organisation licensing/governance.
