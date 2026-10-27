/*
 Debug Database Control Tower - Database Bootstrap
 Public portfolio edition

 Creates the DEBUG_CONTROL_TOWER repository database only when it does not exist.
 Review file locations, sizing, recovery model and backup policy before production use.
*/
USE [master];
GO
IF DB_ID(N'DEBUG_CONTROL_TOWER') IS NULL
BEGIN
    PRINT 'Creating DEBUG_CONTROL_TOWER using SQL Server default database file locations.';
    CREATE DATABASE [DEBUG_CONTROL_TOWER];
END
ELSE
    PRINT 'DEBUG_CONTROL_TOWER already exists; no database created.';
GO
/* Recovery model is intentionally not changed. Choose it according to your organisation's backup/RPO policy. */
USE [DEBUG_CONTROL_TOWER];
GO
SELECT DB_NAME() AS repository_database, recovery_model_desc
FROM sys.databases WHERE name=DB_NAME();
GO
