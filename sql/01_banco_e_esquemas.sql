/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 01 – Banco de dados e esquemas                       (RF02)
   ---------------------------------------------------------------------
   Cria o banco db_educacional com dois esquemas:
     staging : área de recepção dos dados brutos do CSV
     dw      : modelo dimensional (estrela) + tabelas de controle
   Script reexecutável.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE master;
GO

IF DB_ID('db_educacional') IS NULL
BEGIN
    -- Latin1_General (página de código 1252) é compatível com o
    -- ISO-8859-1 dos arquivos do INEP, preservando os acentos na carga.
    CREATE DATABASE db_educacional COLLATE Latin1_General_CI_AS;
END;
GO

-- Carga anual em lote: o modelo SIMPLE evita crescimento do log.
ALTER DATABASE db_educacional SET RECOVERY SIMPLE;
GO

USE db_educacional;
GO

IF SCHEMA_ID('staging') IS NULL EXEC ('CREATE SCHEMA staging AUTHORIZATION dbo;');
GO
IF SCHEMA_ID('dw') IS NULL EXEC ('CREATE SCHEMA dw AUTHORIZATION dbo;');
GO

SELECT name AS esquema FROM sys.schemas WHERE name IN ('staging', 'dw');
GO
