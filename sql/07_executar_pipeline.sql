/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 07 – Configuração dos arquivos e execução do pipeline
   ---------------------------------------------------------------------
   Pré-requisito: a pasta do projeto copiada para dentro do container
   do SQL Server (ver LEIA-ME.md). Ajuste @base se usar outro caminho.
   Ordem obrigatória dos anos: do mais antigo para o mais recente
   (o histórico SCD2 da dim_escola depende disso).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

DECLARE @base VARCHAR(300) = '/var/opt/mssql/projeto/';

MERGE staging.arquivo_fonte AS d
USING (VALUES
    (2024, 'UNICO',
     @base + 'microdados_censo_escolar_2024_defeso/dados/microdados_ed_basica_2024.csv',
     @base + 'formatos/fmt_ed_basica_2024.xml',
     NULL, NULL),
    (2025, 'SEPARADO',
     @base + 'microdados_censo_escolar_2025_v2/dados/Tabela_Escola_2025_V2.csv',
     @base + 'formatos/fmt_escola_2025.xml',
     @base + 'microdados_censo_escolar_2025_v2/dados/Tabela_Matricula_2025_V2.csv',
     @base + 'formatos/fmt_matricula_2025.xml')
) AS s (nu_ano_referencia, tp_layout, ds_caminho_escola, ds_formato_escola,
        ds_caminho_matricula, ds_formato_matricula)
   ON d.nu_ano_referencia = s.nu_ano_referencia
WHEN MATCHED THEN UPDATE SET
    tp_layout = s.tp_layout,
    ds_caminho_escola = s.ds_caminho_escola,       ds_formato_escola = s.ds_formato_escola,
    ds_caminho_matricula = s.ds_caminho_matricula, ds_formato_matricula = s.ds_formato_matricula
WHEN NOT MATCHED THEN INSERT
    (nu_ano_referencia, tp_layout, ds_caminho_escola, ds_formato_escola, ds_caminho_matricula, ds_formato_matricula)
    VALUES (s.nu_ano_referencia, s.tp_layout, s.ds_caminho_escola, s.ds_formato_escola,
            s.ds_caminho_matricula, s.ds_formato_matricula);

SELECT * FROM staging.arquivo_fonte;
GO

/* ---- Ano 2024 (layout único) -------------------------------------- */
EXEC dw.usp_executar_pipeline @nu_ano_referencia = 2024;
GO

/* ---- Ano 2025 (layout separado: escola + matrícula) ---------------- */
EXEC dw.usp_executar_pipeline @nu_ano_referencia = 2025;
GO
