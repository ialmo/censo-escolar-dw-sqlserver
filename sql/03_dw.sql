/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 03 – Esquema dw: modelo dimensional e tabelas de controle
                                                               (RF04)
   ---------------------------------------------------------------------
   Modelo estrela (item 5 do enunciado):
     dw.dim_tempo, dw.dim_municipio, dw.dim_etapa_ensino,
     dw.dim_escola (SCD tipo 2), dw.fact_matricula
   Controle (itens 3, 7 e RF08):
     dw.auditoria           – cargas realizadas na staging (item 7)
     dw.log_inconsistencia  – dados inválidos / inconsistências (RF08, RT06)
     dw.log_execucao        – monitoramento de cada etapa do pipeline
   ATENÇÃO: o script recria as tabelas (apaga os dados do DW).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

DROP TABLE IF EXISTS dw.fact_matricula;
DROP TABLE IF EXISTS dw.dim_escola;
DROP TABLE IF EXISTS dw.dim_municipio;
DROP TABLE IF EXISTS dw.dim_etapa_ensino;
DROP TABLE IF EXISTS dw.dim_tempo;
DROP TABLE IF EXISTS dw.auditoria;
DROP TABLE IF EXISTS dw.log_inconsistencia;
DROP TABLE IF EXISTS dw.log_execucao;
GO

/* =====================================================================
   DIMENSÕES
   ===================================================================== */

-- Calendário diário. sk_tempo no formato AAAAMMDD (chave inteligente).
-- O Censo tem grão anual: a fato aponta para a data de referência do
-- Censo (última quarta-feira de maio – Dia Nacional do Censo Escolar).
CREATE TABLE dw.dim_tempo (
    sk_tempo       INT      NOT NULL,
    ano            INT      NOT NULL,
    mes            TINYINT  NOT NULL,
    dia            TINYINT  NOT NULL,
    dt_calendario  DATE     NOT NULL,
    CONSTRAINT pk_dim_tempo PRIMARY KEY (sk_tempo),
    CONSTRAINT uq_dim_tempo_data UNIQUE (dt_calendario),
    CONSTRAINT ck_dim_tempo_mes CHECK (mes BETWEEN 1 AND 12),
    CONSTRAINT ck_dim_tempo_dia CHECK (dia BETWEEN 1 AND 31)
);
GO

-- Município (SCD tipo 1: nome/UF corrigidos são sobrescritos).
CREATE TABLE dw.dim_municipio (
    sk_municipio    INT IDENTITY(1,1) NOT NULL,
    co_municipio    INT           NOT NULL,   -- código IBGE (7 dígitos)
    uf              CHAR(2)       NOT NULL,
    nome_municipio  VARCHAR(200)  NOT NULL,
    CONSTRAINT pk_dim_municipio PRIMARY KEY (sk_municipio),
    CONSTRAINT uq_dim_municipio_codigo UNIQUE (co_municipio),
    CONSTRAINT ck_dim_municipio_uf CHECK (uf IN ('AC','AL','AM','AP','BA','CE','DF','ES','GO',
                                               'MA','MG','MS','MT','PA','PB','PE','PI','PR',
                                               'RJ','RN','RO','RR','RS','SC','SE','SP','TO'))
);
GO

-- Etapa de ensino. Os microdados trazem contagens por etapa em colunas
-- (QT_MAT_*); a dimensão é a lista dessas etapas (ver dicionário).
-- sk_etapa_ensino = -1 é o membro "não se aplica" (escola sem matrícula).
CREATE TABLE dw.dim_etapa_ensino (
    sk_etapa_ensino  INT IDENTITY(1,1) NOT NULL,
    tp_etapa_ensino  INT           NOT NULL,
    ds_etapa_ensino  VARCHAR(200)  NOT NULL,
    CONSTRAINT pk_dim_etapa_ensino PRIMARY KEY (sk_etapa_ensino),
    CONSTRAINT uq_dim_etapa_ensino_tp UNIQUE (tp_etapa_ensino)
);
GO

-- Escola (SCD tipo 2). Atributos versionados: nome, município e rede.
--   dt_inicio : 01/01 do ano do Censo em que a versão passou a valer
--   dt_fim    : 31/12 do ano anterior à mudança (NULL = versão aberta)
--   fl_ativo  : 'S' versão vigente | 'N' versão histórica ou escola
--               que deixou de constar no Censo
CREATE TABLE dw.dim_escola (
    sk_escola       INT IDENTITY(1,1) NOT NULL,
    co_entidade     BIGINT        NOT NULL,
    no_entidade     VARCHAR(200)  NOT NULL,
    co_municipio    INT           NOT NULL,
    tp_rede_ensino  TINYINT       NOT NULL,   -- 1 Federal, 2 Estadual, 3 Municipal, 4 Privada
    dt_inicio       DATE          NOT NULL,
    dt_fim          DATE          NULL,
    fl_ativo        CHAR(1)       NOT NULL CONSTRAINT df_dim_escola_ativo DEFAULT ('S'),
    CONSTRAINT pk_dim_escola PRIMARY KEY (sk_escola),
    CONSTRAINT fk_dim_escola_municipio FOREIGN KEY (co_municipio)
        REFERENCES dw.dim_municipio (co_municipio),
    CONSTRAINT ck_dim_escola_rede CHECK (tp_rede_ensino BETWEEN 1 AND 4),
    CONSTRAINT ck_dim_escola_ativo CHECK (fl_ativo IN ('S', 'N')),
    CONSTRAINT ck_dim_escola_vigencia CHECK (dt_fim IS NULL OR dt_fim >= dt_inicio)
);
GO

-- Uma única versão por escola e data de início...
CREATE UNIQUE INDEX ux_dim_escola_versao ON dw.dim_escola (co_entidade, dt_inicio);
-- ...e no máximo uma versão vigente por escola.
CREATE UNIQUE INDEX ux_dim_escola_vigente ON dw.dim_escola (co_entidade) WHERE fl_ativo = 'S';
GO

/* =====================================================================
   FATO
   ===================================================================== */

-- Grão: ano (data de referência) x escola x etapa de ensino.
-- RT05: quantidades somadas por ano/escola/município/etapa.
-- RT06: qt_matricula <= 0 é desviado para o log pelo trigger INSTEAD OF
--       (script 05); a CHECK abaixo é a última linha de defesa.
CREATE TABLE dw.fact_matricula (
    sk_tempo         INT           NOT NULL,
    sk_escola        INT           NOT NULL,
    sk_municipio     INT           NOT NULL,
    sk_etapa_ensino  INT           NOT NULL,
    qt_matricula     INT           NOT NULL,
    dt_carga         DATETIME2(0)  NOT NULL CONSTRAINT df_fact_matricula_dt DEFAULT (SYSDATETIME()),
    CONSTRAINT pk_fact_matricula PRIMARY KEY (sk_tempo, sk_escola, sk_etapa_ensino),
    CONSTRAINT fk_fact_matricula_tempo     FOREIGN KEY (sk_tempo)        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fact_matricula_escola    FOREIGN KEY (sk_escola)       REFERENCES dw.dim_escola (sk_escola),
    CONSTRAINT fk_fact_matricula_municipio FOREIGN KEY (sk_municipio)    REFERENCES dw.dim_municipio (sk_municipio),
    CONSTRAINT fk_fact_matricula_etapa     FOREIGN KEY (sk_etapa_ensino) REFERENCES dw.dim_etapa_ensino (sk_etapa_ensino),
    CONSTRAINT ck_fact_matricula_qt CHECK (qt_matricula > 0)
);
GO

CREATE INDEX ix_fact_matricula_municipio ON dw.fact_matricula (sk_municipio) INCLUDE (qt_matricula);
CREATE INDEX ix_fact_matricula_etapa     ON dw.fact_matricula (sk_etapa_ensino) INCLUDE (qt_matricula);
GO

/* =====================================================================
   CONTROLE: auditoria, log de inconsistências e log de execução
   ===================================================================== */

-- Item 7: cargas na staging – usuário, data, ano de referência e
-- quantidade de registros. Preenchida pelo trigger de auditoria.
CREATE TABLE dw.auditoria (
    id_auditoria       INT IDENTITY(1,1) NOT NULL,
    no_usuario         NVARCHAR(128)    NOT NULL,
    dt_carga           DATETIME2(0)     NOT NULL,
    nu_ano_referencia  INT              NOT NULL,
    qt_registros       INT              NOT NULL,
    no_tabela_destino  VARCHAR(128)     NOT NULL,
    no_arquivo_origem  VARCHAR(400)     NULL,
    id_execucao        UNIQUEIDENTIFIER NULL,     -- liga a carga à execução do pipeline
    CONSTRAINT pk_auditoria PRIMARY KEY (id_auditoria)
);
GO

-- RF08 / RT06: dados inválidos e inconsistências registrados pelos triggers.
--   ERRO   : registro descartado do DW
--   ALERTA : registro carregado (com correção) ou apenas sinalizado
CREATE TABLE dw.log_inconsistencia (
    id_log             BIGINT IDENTITY(1,1) NOT NULL,
    dt_registro        DATETIME2(0)     NOT NULL CONSTRAINT df_log_inconsistencia_dt DEFAULT (SYSDATETIME()),
    nu_ano_referencia  INT              NULL,
    no_objeto_origem   VARCHAR(128)     NOT NULL,  -- trigger que registrou
    cd_regra           VARCHAR(10)      NOT NULL,
    tp_severidade      VARCHAR(10)      NOT NULL,
    id_staging         BIGINT           NULL,
    co_entidade        VARCHAR(20)      NULL,
    no_campo           VARCHAR(60)      NULL,
    vl_campo           VARCHAR(400)     NULL,
    ds_inconsistencia  VARCHAR(400)     NOT NULL,
    id_execucao        UNIQUEIDENTIFIER NULL,
    CONSTRAINT pk_log_inconsistencia PRIMARY KEY (id_log),
    CONSTRAINT ck_log_inconsistencia_sev CHECK (tp_severidade IN ('ERRO', 'ALERTA'))
);
GO

CREATE INDEX ix_log_inconsistencia_staging ON dw.log_inconsistencia (id_staging) INCLUDE (tp_severidade);
CREATE INDEX ix_log_inconsistencia_ano     ON dw.log_inconsistencia (nu_ano_referencia, cd_regra);
GO

-- Monitoramento: uma linha por etapa de cada execução do pipeline.
CREATE TABLE dw.log_execucao (
    id_log_execucao    INT IDENTITY(1,1) NOT NULL,
    id_execucao        UNIQUEIDENTIFIER NOT NULL,
    nu_ano_referencia  INT              NOT NULL,
    no_etapa           VARCHAR(100)     NOT NULL,
    no_procedure       VARCHAR(128)     NOT NULL,
    dt_inicio          DATETIME2(3)     NOT NULL,
    dt_fim             DATETIME2(3)     NULL,
    qt_linhas          INT              NULL,
    ds_status          VARCHAR(10)      NOT NULL,   -- EXECUTANDO | SUCESSO | ERRO
    ds_mensagem        NVARCHAR(2000)   NULL,
    no_usuario         NVARCHAR(128)    NOT NULL CONSTRAINT df_log_execucao_usuario DEFAULT (SUSER_SNAME()),
    CONSTRAINT pk_log_execucao PRIMARY KEY (id_log_execucao),
    CONSTRAINT ck_log_execucao_status CHECK (ds_status IN ('EXECUTANDO', 'SUCESSO', 'ERRO'))
);
GO
