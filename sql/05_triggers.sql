/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 05 – Triggers                              (RF08, RT04, RT06, item 7)
   ---------------------------------------------------------------------
   staging.trg_censo_escolar_auditoria   AFTER INSERT   -> dw.auditoria
   staging.trg_censo_escolar_validacao   AFTER INSERT   -> dw.log_inconsistencia
   dw.trg_fact_matricula_rt06            INSTEAD OF INSERT -> RT06
   Todos os triggers são orientados a conjunto (tratam a tabela inserted
   inteira de uma vez), pois a carga insere ~215 mil linhas num único
   comando INSERT ... SELECT.
   O id da execução do pipeline é lido de SESSION_CONTEXT('id_execucao'),
   definido pela procedure orquestradora (rastreabilidade).
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

/* ---------------------------------------------------------------------
   Item 7 – Auditoria de toda carga na staging: usuário, data, ano de
   referência e quantidade de registros. Por estar em trigger, também
   audita inserções feitas fora do pipeline.
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER staging.trg_censo_escolar_auditoria
ON staging.censo_escolar
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    INSERT INTO dw.auditoria
        (no_usuario, dt_carga, nu_ano_referencia, qt_registros,
         no_tabela_destino, no_arquivo_origem, id_execucao)
    SELECT SUSER_SNAME(),
           SYSDATETIME(),
           i.nu_ano_referencia,
           COUNT(*),
           'staging.censo_escolar',
           MAX(i.no_arquivo_origem),
           TRY_CAST(SESSION_CONTEXT(N'id_execucao') AS UNIQUEIDENTIFIER)
    FROM inserted AS i
    GROUP BY i.nu_ano_referencia;
END;
GO

/* ---------------------------------------------------------------------
   RF08 – Validação dos dados recebidos na staging.
   ERRO   -> o registro não segue para o DW (filtrado pela view
             staging.vw_censo_escolar_valido)
   ALERTA -> o registro segue, com correção aplicada pelas functions
   Regras:
     V01 ERRO   co_entidade ausente ou não numérico
     V02 ERRO   nome da escola vazio
     V03 ERRO   código IBGE do município ausente ou inválido
     V04 ALERTA nome do município vazio (obtido de outra escola do mesmo código)
     V05 ALERTA UF inválida (corrigida pelo código IBGE – RT04)
     V06 ALERTA UF diverge do código IBGE do município
     V07 ERRO   rede de ensino (TP_DEPENDENCIA) fora do domínio 1–4
     V08 ERRO   ano do arquivo diferente do ano de referência da carga
     V09 ERRO   quantidade de matrícula não numérica ou negativa
     V10 ALERTA QT_MAT_BAS diferente da soma das etapas
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER staging.trg_censo_escolar_validacao
ON staging.censo_escolar
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    DECLARE @id_execucao UNIQUEIDENTIFIER = TRY_CAST(SESSION_CONTEXT(N'id_execucao') AS UNIQUEIDENTIFIER),
            @objeto      VARCHAR(128)     = 'staging.trg_censo_escolar_validacao';

    /* Regras de registro (uma avaliação por linha) */
    INSERT INTO dw.log_inconsistencia
        (nu_ano_referencia, no_objeto_origem, cd_regra, tp_severidade, id_staging,
         co_entidade, no_campo, vl_campo, ds_inconsistencia, id_execucao)
    SELECT i.nu_ano_referencia, @objeto, r.cd_regra, r.tp_severidade, i.id_staging,
           i.co_entidade, r.no_campo, LEFT(r.vl_campo, 400), r.ds_inconsistencia, @id_execucao
    FROM inserted AS i
    CROSS APPLY (SELECT uf_informada = UPPER(TRIM(i.sg_uf)),
                        uf_ibge      = dw.fn_uf_por_codigo_ibge(TRY_CAST(LEFT(TRIM(i.co_municipio), 2) AS INT)),
                        soma_etapas  = ISNULL(dw.fn_converter_inteiro(i.qt_mat_inf_cre), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_inf_pre), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_fund_ai), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_fund_af), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_med), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_prof_tec_conc), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_prof_tec_subs), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_prof_fic_conc), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_prof_tec_iftp_ct), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_prof_iftp_qp), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_eja_fund), 0)
                                     + ISNULL(dw.fn_converter_inteiro(i.qt_mat_eja_med), 0)) AS c
    CROSS APPLY (VALUES
        ('V01', 'ERRO',   'CO_ENTIDADE',    i.co_entidade,
            CASE WHEN TRY_CAST(TRIM(i.co_entidade) AS BIGINT) IS NULL
                 THEN 'Código da escola ausente ou não numérico' END),
        ('V02', 'ERRO',   'NO_ENTIDADE',    i.no_entidade,
            CASE WHEN NULLIF(TRIM(i.no_entidade), '') IS NULL
                 THEN 'Nome da escola vazio' END),
        ('V03', 'ERRO',   'CO_MUNICIPIO',   i.co_municipio,
            CASE WHEN TRY_CAST(TRIM(i.co_municipio) AS INT) IS NULL
                      OR LEN(TRIM(i.co_municipio)) <> 7
                      OR c.uf_ibge IS NULL
                 THEN 'Código IBGE do município ausente ou inválido' END),
        ('V04', 'ALERTA', 'NO_MUNICIPIO',   i.no_municipio,
            CASE WHEN NULLIF(TRIM(i.no_municipio), '') IS NULL
                 THEN 'Nome do município vazio – obtido de outro registro com o mesmo código IBGE' END),
        ('V05', 'ALERTA', 'SG_UF',          i.sg_uf,
            CASE WHEN dw.fn_uf_valida(i.sg_uf) = 0
                 THEN 'UF inválida – corrigida para ' + ISNULL(c.uf_ibge, '??') + ' pelo código IBGE (RT04)' END),
        ('V06', 'ALERTA', 'SG_UF',          i.sg_uf,
            CASE WHEN dw.fn_uf_valida(i.sg_uf) = 1 AND c.uf_informada <> c.uf_ibge
                 THEN 'UF diverge do código IBGE do município (' + c.uf_ibge + ')' END),
        ('V07', 'ERRO',   'TP_DEPENDENCIA', i.tp_dependencia,
            CASE WHEN ISNULL(dw.fn_converter_inteiro(i.tp_dependencia), 0) NOT BETWEEN 1 AND 4
                 THEN 'Rede de ensino fora do domínio (1 a 4)' END),
        ('V08', 'ERRO',   'NU_ANO_CENSO',   i.nu_ano_censo,
            CASE WHEN ISNULL(dw.fn_converter_inteiro(i.nu_ano_censo), 0) <> i.nu_ano_referencia
                 THEN 'Ano do arquivo diferente do ano de referência da carga' END),
        ('V10', 'ALERTA', 'QT_MAT_BAS',     i.qt_mat_bas,
            CASE WHEN dw.fn_converter_inteiro(i.qt_mat_bas) <> c.soma_etapas
                 THEN 'Total de matrículas (' + i.qt_mat_bas + ') difere da soma das etapas ('
                      + CAST(c.soma_etapas AS VARCHAR(20)) + ')' END)
    ) AS r (cd_regra, tp_severidade, no_campo, vl_campo, ds_inconsistencia)
    WHERE r.ds_inconsistencia IS NOT NULL;

    /* V09 – cada coluna de quantidade é avaliada individualmente */
    INSERT INTO dw.log_inconsistencia
        (nu_ano_referencia, no_objeto_origem, cd_regra, tp_severidade, id_staging,
         co_entidade, no_campo, vl_campo, ds_inconsistencia, id_execucao)
    SELECT i.nu_ano_referencia, @objeto, 'V09', 'ERRO', i.id_staging,
           i.co_entidade, q.no_campo, q.vl_campo,
           'Quantidade de matrícula não numérica ou negativa', @id_execucao
    FROM inserted AS i
    CROSS APPLY (VALUES
        ('QT_MAT_BAS',              i.qt_mat_bas),
        ('QT_MAT_INF_CRE',          i.qt_mat_inf_cre),
        ('QT_MAT_INF_PRE',          i.qt_mat_inf_pre),
        ('QT_MAT_FUND_AI',          i.qt_mat_fund_ai),
        ('QT_MAT_FUND_AF',          i.qt_mat_fund_af),
        ('QT_MAT_MED',              i.qt_mat_med),
        ('QT_MAT_PROF_TEC_CONC',    i.qt_mat_prof_tec_conc),
        ('QT_MAT_PROF_TEC_SUBS',    i.qt_mat_prof_tec_subs),
        ('QT_MAT_PROF_FIC_CONC',    i.qt_mat_prof_fic_conc),
        ('QT_MAT_PROF_TEC_IFTP_CT', i.qt_mat_prof_tec_iftp_ct),
        ('QT_MAT_PROF_IFTP_QP',     i.qt_mat_prof_iftp_qp),
        ('QT_MAT_EJA_FUND',         i.qt_mat_eja_fund),
        ('QT_MAT_EJA_MED',          i.qt_mat_eja_med)
    ) AS q (no_campo, vl_campo)
    WHERE NULLIF(TRIM(q.vl_campo), '') IS NOT NULL
      AND (dw.fn_converter_inteiro(q.vl_campo) IS NULL OR dw.fn_converter_inteiro(q.vl_campo) < 0);
END;
GO

/* ---------------------------------------------------------------------
   RT06 – Registros com qt_matricula <= 0 são enviados ao log e não
   entram na fato. O INSTEAD OF garante a regra para qualquer INSERT
   na fato, venha ele do pipeline ou não.
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dw.trg_fact_matricula_rt06
ON dw.fact_matricula
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    INSERT INTO dw.log_inconsistencia
        (nu_ano_referencia, no_objeto_origem, cd_regra, tp_severidade, id_staging,
         co_entidade, no_campo, vl_campo, ds_inconsistencia, id_execucao)
    SELECT t.ano,
           'dw.trg_fact_matricula_rt06',
           'RT06',
           'ALERTA',
           NULL,
           CAST(e.co_entidade AS VARCHAR(20)),
           'qt_matricula',
           ISNULL(CAST(i.qt_matricula AS VARCHAR(20)), 'NULL'),
           CASE WHEN i.sk_etapa_ensino = -1
                THEN 'Escola sem matrícula no ano – nenhum registro carregado na fato'
                ELSE 'qt_matricula <= 0 na etapa "' + ISNULL(et.ds_etapa_ensino, '?') + '" – registro não carregado'
           END,
           TRY_CAST(SESSION_CONTEXT(N'id_execucao') AS UNIQUEIDENTIFIER)
    FROM inserted AS i
    LEFT JOIN dw.dim_tempo        AS t  ON t.sk_tempo         = i.sk_tempo
    LEFT JOIN dw.dim_escola       AS e  ON e.sk_escola        = i.sk_escola
    LEFT JOIN dw.dim_etapa_ensino AS et ON et.sk_etapa_ensino = i.sk_etapa_ensino
    WHERE ISNULL(i.qt_matricula, 0) <= 0;

    INSERT INTO dw.fact_matricula
        (sk_tempo, sk_escola, sk_municipio, sk_etapa_ensino, qt_matricula, dt_carga)
    SELECT i.sk_tempo, i.sk_escola, i.sk_municipio, i.sk_etapa_ensino, i.qt_matricula,
           ISNULL(i.dt_carga, SYSDATETIME())
    FROM inserted AS i
    WHERE i.qt_matricula > 0;
END;
GO
