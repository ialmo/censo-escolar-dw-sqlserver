/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 02 – Esquema staging                                  (RF03)
   ---------------------------------------------------------------------
   staging.arquivo_fonte  : configuração dos arquivos CSV de cada ano
                            (camada raw) e dos arquivos de formato.
   staging.censo_escolar  : recepção direta dos dados do CSV, SOMENTE
                            com as colunas necessárias ao modelo
                            dimensional. Todas as colunas de dados são
                            VARCHAR: a carga nunca falha por tipo e a
                            validação fica centralizada no banco
                            (trigger de validação – script 05).
   ATENÇÃO: o script recria as tabelas (apaga os dados da staging).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

DROP TABLE IF EXISTS staging.censo_escolar;
DROP TABLE IF EXISTS staging.arquivo_fonte;
GO

/* ---------------------------------------------------------------------
   Configuração da ingestão anual.
   Layout UNICO    : um único CSV com cadastro e matrículas
                     (microdados_ed_basica_AAAA.csv – até 2024).
   Layout SEPARADO : cadastro e matrículas em arquivos distintos
                     (Tabela_Escola / Tabela_Matricula – a partir de 2025).
   --------------------------------------------------------------------- */
CREATE TABLE staging.arquivo_fonte (
    nu_ano_referencia     INT           NOT NULL,
    tp_layout             VARCHAR(10)   NOT NULL,
    ds_caminho_escola     VARCHAR(400)  NOT NULL,  -- CSV de cadastro (no UNICO, também traz as matrículas)
    ds_formato_escola     VARCHAR(400)  NOT NULL,  -- arquivo de formato XML do CSV acima
    ds_caminho_matricula  VARCHAR(400)  NULL,      -- somente layout SEPARADO
    ds_formato_matricula  VARCHAR(400)  NULL,
    CONSTRAINT pk_arquivo_fonte PRIMARY KEY (nu_ano_referencia),
    CONSTRAINT ck_arquivo_fonte_layout CHECK (tp_layout IN ('UNICO', 'SEPARADO')),
    CONSTRAINT ck_arquivo_fonte_separado CHECK (
        tp_layout = 'UNICO'
        OR (ds_caminho_matricula IS NOT NULL AND ds_formato_matricula IS NOT NULL))
);
GO

/* ---------------------------------------------------------------------
   Tabela de recepção dos microdados (1 linha = 1 escola no ano).
   Nomes de coluna iguais aos do dicionário do INEP, em minúsculas.
   --------------------------------------------------------------------- */
CREATE TABLE staging.censo_escolar (
    -- controle da carga
    id_staging                 BIGINT IDENTITY(1,1) NOT NULL,
    nu_ano_referencia          INT           NOT NULL,
    no_arquivo_origem          VARCHAR(400)  NOT NULL,
    dt_carga_staging           DATETIME2(0)  NOT NULL CONSTRAINT df_censo_escolar_dt DEFAULT (SYSDATETIME()),
    -- identificação e localização
    nu_ano_censo               VARCHAR(10)   NULL,
    sg_uf                      VARCHAR(10)   NULL,
    co_uf                      VARCHAR(10)   NULL,
    no_municipio               VARCHAR(200)  NULL,
    co_municipio               VARCHAR(20)   NULL,
    no_entidade                VARCHAR(400)  NULL,
    co_entidade                VARCHAR(20)   NULL,
    tp_dependencia             VARCHAR(10)   NULL,  -- 1 Federal, 2 Estadual, 3 Municipal, 4 Privada
    tp_situacao_funcionamento  VARCHAR(10)   NULL,  -- 1 Em atividade, 2 Paralisada, 3 Extinta
    -- matrículas (contagens por etapa)
    qt_mat_bas                 VARCHAR(20)   NULL,  -- total da educação básica (conferência)
    qt_mat_inf_cre             VARCHAR(20)   NULL,
    qt_mat_inf_pre             VARCHAR(20)   NULL,
    qt_mat_fund_ai             VARCHAR(20)   NULL,
    qt_mat_fund_af             VARCHAR(20)   NULL,
    qt_mat_med                 VARCHAR(20)   NULL,
    qt_mat_prof_tec_conc       VARCHAR(20)   NULL,
    qt_mat_prof_tec_subs       VARCHAR(20)   NULL,
    qt_mat_prof_fic_conc       VARCHAR(20)   NULL,
    qt_mat_prof_tec_iftp_ct    VARCHAR(20)   NULL,  -- existe a partir de 2025
    qt_mat_prof_iftp_qp        VARCHAR(20)   NULL,  -- existe a partir de 2025
    qt_mat_eja_fund            VARCHAR(20)   NULL,
    qt_mat_eja_med             VARCHAR(20)   NULL,
    CONSTRAINT pk_censo_escolar PRIMARY KEY (id_staging)
);
GO

CREATE INDEX ix_censo_escolar_ano
    ON staging.censo_escolar (nu_ano_referencia)
    INCLUDE (co_entidade, co_municipio);
GO
