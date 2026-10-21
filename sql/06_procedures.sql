/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 06 – Views e stored procedures do pipeline        (RF05, RF06)
   ---------------------------------------------------------------------
   Pipeline (uma execução por ano de referência):
     dw.usp_executar_pipeline @nu_ano_referencia
       0  dw.usp_validar_ordem_carga         pré-condições (ordem dos anos)
       1  staging.usp_carregar_staging       CSV (raw) -> staging
       2  dw.usp_carregar_dim_tempo          calendário do ano
       3  dw.usp_carregar_dim_etapa_ensino   etapas (carga fixa)
       4  dw.usp_carregar_dim_municipio      SCD1
       5  dw.usp_carregar_dim_escola         SCD2
       6  dw.usp_carregar_fact_matricula     unpivot + soma (RT05) + RT06
   Cada etapa é registrada em dw.log_execucao por dw.usp_executar_etapa.
   Todas as etapas são idempotentes: reexecutar o mesmo ano não duplica.
   Utilitários:
     staging.usp_gerar_arquivo_formato   gera o XML de formato de um CSV
     dw.vw_matricula                     visão analítica para relatórios
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

/* ---------------------------------------------------------------------
   Registros da staging aptos a seguir para o DW: sem inconsistência de
   severidade ERRO registrada pelo trigger de validação.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW staging.vw_censo_escolar_valido
AS
SELECT s.*
FROM staging.censo_escolar AS s
WHERE NOT EXISTS (SELECT 1
                  FROM dw.log_inconsistencia AS l
                  WHERE l.id_staging = s.id_staging
                    AND l.tp_severidade = 'ERRO');
GO

/* =====================================================================
   ETAPA 0 – Pré-condição: os anos devem ser carregados em ordem
   cronológica (o histórico SCD2 depende disso). Reprocessar o último
   ano é permitido; carregar um ano anterior a ele, não.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_validar_ordem_carga
    @nu_ano_referencia INT,
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ultimo_ano INT;

    SELECT @ultimo_ano = MAX(x.ano)
    FROM (SELECT YEAR(dt_inicio) AS ano FROM dw.dim_escola
          UNION ALL
          SELECT YEAR(dt_fim) + 1 FROM dw.dim_escola WHERE dt_fim IS NOT NULL) AS x;

    IF @ultimo_ano > @nu_ano_referencia
        THROW 50020, 'Carga fora de ordem: o DW já possui dados de ano posterior ao informado.', 1;

    IF NOT EXISTS (SELECT 1 FROM staging.arquivo_fonte WHERE nu_ano_referencia = @nu_ano_referencia)
        THROW 50001, 'Ano de referência sem arquivo configurado em staging.arquivo_fonte.', 1;

    SET @qt_linhas = 0;
END;
GO

/* =====================================================================
   ETAPA 1 – Carga da staging a partir do CSV (camada raw)
   ---------------------------------------------------------------------
   Lê o CSV com OPENROWSET(BULK) + arquivo de formato XML, que expõe
   apenas as colunas necessárias. CODEPAGE = 'RAW' é a única opção aceita
   pelo SQL Server 2019 em Linux: os bytes ISO-8859-1 do INEP são
   gravados sem conversão e interpretados corretamente pela collation
   Latin1 (página 1252) do banco.
   Um único INSERT ... SELECT por carga -> os triggers de auditoria e de
   validação disparam uma vez, sobre o lote inteiro.
   ===================================================================== */
CREATE OR ALTER PROCEDURE staging.usp_carregar_staging
    @nu_ano_referencia INT,
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @tp_layout   VARCHAR(10),
            @csv_escola  VARCHAR(400), @fmt_escola    VARCHAR(400),
            @csv_mat     VARCHAR(400), @fmt_mat       VARCHAR(400),
            @sql         NVARCHAR(MAX);

    SELECT @tp_layout  = tp_layout,
           @csv_escola = REPLACE(ds_caminho_escola,    '''', ''''''),
           @fmt_escola = REPLACE(ds_formato_escola,    '''', ''''''),
           @csv_mat    = REPLACE(ds_caminho_matricula, '''', ''''''),
           @fmt_mat    = REPLACE(ds_formato_matricula, '''', '''''')
    FROM staging.arquivo_fonte
    WHERE nu_ano_referencia = @nu_ano_referencia;

    IF @tp_layout IS NULL
        THROW 50001, 'Ano de referência sem arquivo configurado em staging.arquivo_fonte.', 1;

    DECLARE @colunas_destino NVARCHAR(MAX) = N'
        nu_ano_referencia, no_arquivo_origem,
        nu_ano_censo, sg_uf, co_uf, no_municipio, co_municipio, no_entidade, co_entidade,
        tp_dependencia, tp_situacao_funcionamento,
        qt_mat_bas, qt_mat_inf_cre, qt_mat_inf_pre, qt_mat_fund_ai, qt_mat_fund_af, qt_mat_med,
        qt_mat_prof_tec_conc, qt_mat_prof_tec_subs, qt_mat_prof_fic_conc,
        qt_mat_prof_tec_iftp_ct, qt_mat_prof_iftp_qp, qt_mat_eja_fund, qt_mat_eja_med';

    IF @tp_layout = 'UNICO'
        SET @sql = N'
        INSERT INTO staging.censo_escolar (' + @colunas_destino + N')
        SELECT @ano, @arquivo,
               src.NU_ANO_CENSO, src.SG_UF, src.CO_UF, src.NO_MUNICIPIO, src.CO_MUNICIPIO,
               src.NO_ENTIDADE, src.CO_ENTIDADE, src.TP_DEPENDENCIA, src.TP_SITUACAO_FUNCIONAMENTO,
               src.QT_MAT_BAS, src.QT_MAT_INF_CRE, src.QT_MAT_INF_PRE, src.QT_MAT_FUND_AI,
               src.QT_MAT_FUND_AF, src.QT_MAT_MED,
               src.QT_MAT_PROF_TEC_CONC, src.QT_MAT_PROF_TEC_SUBS, src.QT_MAT_PROF_FIC_CONC,
               NULL, NULL,                       -- colunas inexistentes no layout único
               src.QT_MAT_EJA_FUND, src.QT_MAT_EJA_MED
        FROM OPENROWSET(BULK ''' + @csv_escola + N''',
                        FORMATFILE = ''' + @fmt_escola + N''',
                        FIRSTROW = 2, CODEPAGE = ''RAW'', MAXERRORS = 0) AS src;';
    ELSE
        SET @sql = N'
        SELECT * INTO #escola
        FROM OPENROWSET(BULK ''' + @csv_escola + N''',
                        FORMATFILE = ''' + @fmt_escola + N''',
                        FIRSTROW = 2, CODEPAGE = ''RAW'', MAXERRORS = 0) AS e;

        SELECT * INTO #matricula
        FROM OPENROWSET(BULK ''' + @csv_mat + N''',
                        FORMATFILE = ''' + @fmt_mat + N''',
                        FIRSTROW = 2, CODEPAGE = ''RAW'', MAXERRORS = 0) AS m;

        INSERT INTO staging.censo_escolar (' + @colunas_destino + N')
        SELECT @ano, @arquivo,
               e.NU_ANO_CENSO, e.SG_UF, e.CO_UF, e.NO_MUNICIPIO, e.CO_MUNICIPIO,
               e.NO_ENTIDADE, e.CO_ENTIDADE, e.TP_DEPENDENCIA, e.TP_SITUACAO_FUNCIONAMENTO,
               m.QT_MAT_BAS, m.QT_MAT_INF_CRE, m.QT_MAT_INF_PRE, m.QT_MAT_FUND_AI,
               m.QT_MAT_FUND_AF, m.QT_MAT_MED,
               m.QT_MAT_PROF_TEC_CONC, m.QT_MAT_PROF_TEC_SUBS, m.QT_MAT_PROF_FIC_CONC,
               m.QT_MAT_PROF_TEC_IFTP_CT, m.QT_MAT_PROF_IFTP_QP,
               m.QT_MAT_EJA_FUND, m.QT_MAT_EJA_MED
        FROM #escola AS e
        LEFT JOIN #matricula AS m ON m.CO_ENTIDADE = e.CO_ENTIDADE;';  -- escola sem matrícula fica com QT nulos

    DECLARE @nome_arquivo VARCHAR(400) =
        (SELECT ds_caminho_escola + ISNULL(' + ' + ds_caminho_matricula, '')
         FROM staging.arquivo_fonte WHERE nu_ano_referencia = @nu_ano_referencia);

    BEGIN TRANSACTION;
        -- reprocessamento: substitui a carga anterior do mesmo ano
        DELETE FROM staging.censo_escolar WHERE nu_ano_referencia = @nu_ano_referencia;

        EXEC sys.sp_executesql @sql,
             N'@ano INT, @arquivo VARCHAR(400)',
             @ano = @nu_ano_referencia, @arquivo = @nome_arquivo;
    COMMIT TRANSACTION;

    SELECT @qt_linhas = COUNT(*) FROM staging.censo_escolar WHERE nu_ano_referencia = @nu_ano_referencia;

    IF @qt_linhas = 0
        THROW 50002, 'Nenhum registro foi carregado na staging.', 1;
END;
GO

/* =====================================================================
   ETAPA 2 – dim_tempo: todos os dias do ano de referência
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_carregar_dim_tempo
    @nu_ano_referencia INT,
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @inicio DATE = DATEFROMPARTS(@nu_ano_referencia, 1, 1),
            @fim    DATE = DATEFROMPARTS(@nu_ano_referencia, 12, 31);

    WITH numeros AS (
        SELECT TOP (DATEDIFF(DAY, @inicio, @fim) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ), datas AS (
        SELECT DATEADD(DAY, n, @inicio) AS dt FROM numeros
    )
    INSERT INTO dw.dim_tempo (sk_tempo, ano, mes, dia, dt_calendario)
    SELECT dw.fn_sk_tempo(d.dt), YEAR(d.dt), MONTH(d.dt), DAY(d.dt), d.dt
    FROM datas AS d
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_tempo AS t WHERE t.dt_calendario = d.dt);

    SET @qt_linhas = @@ROWCOUNT;
END;
GO

/* =====================================================================
   ETAPA 3 – dim_etapa_ensino: carga fixa e idempotente
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_carregar_dim_etapa_ensino
    @nu_ano_referencia INT = NULL,   -- não utilizado; mantém a assinatura padrão das etapas
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- membro "não se aplica" usado para escolas sem nenhuma matrícula (RT06)
    IF NOT EXISTS (SELECT 1 FROM dw.dim_etapa_ensino WHERE sk_etapa_ensino = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_etapa_ensino ON;
        INSERT INTO dw.dim_etapa_ensino (sk_etapa_ensino, tp_etapa_ensino, ds_etapa_ensino)
        VALUES (-1, -1, 'Não se aplica (escola sem matrícula)');
        SET IDENTITY_INSERT dw.dim_etapa_ensino OFF;
    END;

    MERGE dw.dim_etapa_ensino AS d
    USING (VALUES
        (1, 'Educação Infantil - Creche'),
        (2, 'Educação Infantil - Pré-escola'),
        (3, 'Ensino Fundamental - Anos Iniciais'),
        (4, 'Ensino Fundamental - Anos Finais'),
        (5, 'Ensino Médio'),
        (6, 'Educação Profissional (concomitante, subsequente e FIC)'),
        (7, 'EJA - Ensino Fundamental'),
        (8, 'EJA - Ensino Médio')
    ) AS s (tp_etapa_ensino, ds_etapa_ensino)
       ON d.tp_etapa_ensino = s.tp_etapa_ensino
    WHEN MATCHED AND d.ds_etapa_ensino <> s.ds_etapa_ensino THEN
        UPDATE SET ds_etapa_ensino = s.ds_etapa_ensino
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (tp_etapa_ensino, ds_etapa_ensino) VALUES (s.tp_etapa_ensino, s.ds_etapa_ensino);

    SET @qt_linhas = @@ROWCOUNT;
END;
GO

/* =====================================================================
   ETAPA 4 – dim_municipio (SCD tipo 1)
   Nome padronizado (RT01–RT03) e UF válida (RT04). Quando um registro
   vem sem nome/UF, o valor é obtido dos demais registros do mesmo
   código IBGE.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_carregar_dim_municipio
    @nu_ano_referencia INT,
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- valores distintos primeiro: as functions rodam ~5.600 vezes, não 215 mil
    SELECT DISTINCT
           co_municipio = TRY_CAST(TRIM(v.co_municipio) AS INT),
           sg_uf        = v.sg_uf,
           no_municipio = v.no_municipio
    INTO #bruto
    FROM staging.vw_censo_escolar_valido AS v
    WHERE v.nu_ano_referencia = @nu_ano_referencia;

    IF @@ROWCOUNT = 0
        THROW 50010, 'Staging sem registros válidos para o ano de referência.', 1;

    SELECT b.co_municipio,
           uf             = MAX(dw.fn_padronizar_uf(b.sg_uf, CAST(b.co_municipio AS VARCHAR(20)))),
           nome_municipio = MAX(dw.fn_padronizar_nome(b.no_municipio))
    INTO #municipio
    FROM #bruto AS b
    WHERE b.co_municipio IS NOT NULL
    GROUP BY b.co_municipio;

    BEGIN TRANSACTION;
        MERGE dw.dim_municipio AS d
        USING (SELECT * FROM #municipio WHERE uf IS NOT NULL AND nome_municipio IS NOT NULL) AS s
           ON d.co_municipio = s.co_municipio
        WHEN MATCHED AND (d.uf <> s.uf
                          OR d.nome_municipio COLLATE Latin1_General_BIN2 <> s.nome_municipio) THEN
            UPDATE SET uf = s.uf, nome_municipio = s.nome_municipio
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (co_municipio, uf, nome_municipio) VALUES (s.co_municipio, s.uf, s.nome_municipio);

        SET @qt_linhas = @@ROWCOUNT;
    COMMIT TRANSACTION;
END;
GO

/* =====================================================================
   ETAPA 5 – dim_escola (SCD tipo 2)
   ---------------------------------------------------------------------
   Atributos versionados: no_entidade, co_municipio, tp_rede_ensino.
   Para o ano A:
     * versão vigente alterada  -> fechada (dt_fim = 31/12/A-1, fl_ativo = 'N')
                                   e nova versão aberta em 01/01/A
     * escola nova              -> versão aberta em 01/01/A
     * escola ausente no Censo  -> versão fechada, sem nova versão
   Idempotência: reprocessar o último ano carregado desfaz antes as
   alterações daquele ano. Anos anteriores ao último são recusados
   (carga fora de ordem quebraria o histórico).
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_carregar_dim_escola
    @nu_ano_referencia INT,
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @dt_inicio   DATE = DATEFROMPARTS(@nu_ano_referencia, 1, 1),
            @dt_fim_ant  DATE = DATEFROMPARTS(@nu_ano_referencia - 1, 12, 31),
            @ultimo_ano  INT,
            @fechadas    INT = 0,
            @inseridas   INT = 0;

    SELECT @ultimo_ano = MAX(x.ano)
    FROM (SELECT YEAR(dt_inicio) AS ano FROM dw.dim_escola
          UNION ALL
          SELECT YEAR(dt_fim) + 1 FROM dw.dim_escola WHERE dt_fim IS NOT NULL) AS x;

    IF @ultimo_ano > @nu_ano_referencia
        THROW 50020, 'Carga fora de ordem: a dim_escola já possui versões de ano posterior.', 1;

    -- escolas do ano já padronizadas (RT01–RT03)
    SELECT co_entidade    = CAST(TRIM(v.co_entidade) AS BIGINT),
           no_entidade    = CAST(dw.fn_padronizar_nome(v.no_entidade) AS VARCHAR(200)),
           co_municipio   = CAST(TRIM(v.co_municipio) AS INT),
           tp_rede_ensino = CAST(dw.fn_converter_inteiro(v.tp_dependencia) AS TINYINT)
    INTO #escola
    FROM staging.vw_censo_escolar_valido AS v
    JOIN dw.dim_municipio AS m ON m.co_municipio = TRY_CAST(TRIM(v.co_municipio) AS INT)
    WHERE v.nu_ano_referencia = @nu_ano_referencia;

    IF @@ROWCOUNT = 0
        THROW 50021, 'Staging sem registros válidos para o ano de referência.', 1;

    CREATE UNIQUE CLUSTERED INDEX ix_escola ON #escola (co_entidade);

    BEGIN TRANSACTION;
        -- reprocessamento do último ano: desfaz o que aquele ano alterou
        IF @ultimo_ano = @nu_ano_referencia
        BEGIN
            DELETE f
            FROM dw.fact_matricula AS f
            JOIN dw.dim_tempo AS t ON t.sk_tempo = f.sk_tempo
            WHERE t.ano = @nu_ano_referencia;

            DELETE FROM dw.dim_escola WHERE dt_inicio = @dt_inicio;

            UPDATE dw.dim_escola
               SET dt_fim = NULL, fl_ativo = 'S'
             WHERE dt_fim = @dt_fim_ant;
        END;

        -- fecha versões alteradas e escolas que não constam no ano
        UPDATE d
           SET dt_fim = @dt_fim_ant, fl_ativo = 'N'
        FROM dw.dim_escola AS d
        LEFT JOIN #escola AS e ON e.co_entidade = d.co_entidade
        WHERE d.fl_ativo = 'S'
          AND (   e.co_entidade IS NULL
               OR d.no_entidade COLLATE Latin1_General_BIN2 <> e.no_entidade
               OR d.co_municipio   <> e.co_municipio
               OR d.tp_rede_ensino <> e.tp_rede_ensino);
        SET @fechadas = @@ROWCOUNT;

        -- abre versão para escolas novas e alteradas
        INSERT INTO dw.dim_escola
            (co_entidade, no_entidade, co_municipio, tp_rede_ensino, dt_inicio, dt_fim, fl_ativo)
        SELECT e.co_entidade, e.no_entidade, e.co_municipio, e.tp_rede_ensino, @dt_inicio, NULL, 'S'
        FROM #escola AS e
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_escola AS d
                          WHERE d.co_entidade = e.co_entidade AND d.fl_ativo = 'S');
        SET @inseridas = @@ROWCOUNT;
    COMMIT TRANSACTION;

    SET @qt_linhas = @fechadas + @inseridas;   -- versões fechadas + versões abertas
END;
GO

/* =====================================================================
   ETAPA 6 – fact_matricula
   ---------------------------------------------------------------------
   1. desdobra as colunas QT_MAT_* em linhas por etapa (fn_desdobrar_etapas)
   2. RT05: soma por ano/escola/município/etapa
   3. etapas com zero = etapa não ofertada -> não geram registro
   4. escola sem nenhuma matrícula -> 1 registro na etapa -1 com qt 0,
      que o trigger INSTEAD OF (RT06) desvia para o log
   5. a escola é ligada à versão SCD2 vigente na data de referência
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_carregar_fact_matricula
    @nu_ano_referencia INT,
    @qt_linhas         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @dt_referencia DATE = dw.fn_data_referencia_censo(@nu_ano_referencia);
    DECLARE @sk_tempo      INT  = dw.fn_sk_tempo(@dt_referencia);

    IF NOT EXISTS (SELECT 1 FROM dw.dim_tempo WHERE sk_tempo = @sk_tempo)
        THROW 50030, 'Data de referência ausente na dim_tempo – execute a etapa da dimensão tempo.', 1;

    -- 1 e 2: desdobramento + RT05
    SELECT co_entidade     = CAST(TRIM(v.co_entidade) AS BIGINT),
           co_municipio    = CAST(TRIM(v.co_municipio) AS INT),
           x.tp_etapa_ensino,
           qt_matricula    = SUM(ISNULL(x.qt_matricula, 0))
    INTO #agregado
    FROM staging.vw_censo_escolar_valido AS v
    CROSS APPLY dw.fn_desdobrar_etapas(
        v.qt_mat_inf_cre, v.qt_mat_inf_pre, v.qt_mat_fund_ai, v.qt_mat_fund_af, v.qt_mat_med,
        v.qt_mat_prof_tec_conc, v.qt_mat_prof_tec_subs, v.qt_mat_prof_fic_conc,
        v.qt_mat_prof_tec_iftp_ct, v.qt_mat_prof_iftp_qp,
        v.qt_mat_eja_fund, v.qt_mat_eja_med) AS x
    WHERE v.nu_ano_referencia = @nu_ano_referencia
    GROUP BY CAST(TRIM(v.co_entidade) AS BIGINT), CAST(TRIM(v.co_municipio) AS INT), x.tp_etapa_ensino;

    IF @@ROWCOUNT = 0
        THROW 50031, 'Staging sem registros válidos para o ano de referência.', 1;

    -- 3 e 4: registros candidatos à fato
    SELECT a.co_entidade, a.co_municipio, a.tp_etapa_ensino, a.qt_matricula
    INTO #candidato
    FROM #agregado AS a
    WHERE a.qt_matricula <> 0
    UNION ALL
    SELECT a.co_entidade, a.co_municipio, -1, SUM(a.qt_matricula)
    FROM #agregado AS a
    GROUP BY a.co_entidade, a.co_municipio
    HAVING SUM(a.qt_matricula) <= 0;

    BEGIN TRANSACTION;
        -- idempotência: substitui o ano inteiro
        DELETE FROM dw.fact_matricula WHERE sk_tempo = @sk_tempo;

        -- 5: o trigger dw.trg_fact_matricula_rt06 aplica a RT06
        INSERT INTO dw.fact_matricula
            (sk_tempo, sk_escola, sk_municipio, sk_etapa_ensino, qt_matricula, dt_carga)
        SELECT @sk_tempo, e.sk_escola, m.sk_municipio, et.sk_etapa_ensino, c.qt_matricula, SYSDATETIME()
        FROM #candidato AS c
        JOIN dw.dim_escola AS e
          ON e.co_entidade = c.co_entidade
         AND @dt_referencia >= e.dt_inicio
         AND @dt_referencia <= ISNULL(e.dt_fim, '99991231')
        JOIN dw.dim_municipio    AS m  ON m.co_municipio     = c.co_municipio
        JOIN dw.dim_etapa_ensino AS et ON et.tp_etapa_ensino = c.tp_etapa_ensino;
    COMMIT TRANSACTION;

    SELECT @qt_linhas = COUNT(*) FROM dw.fact_matricula WHERE sk_tempo = @sk_tempo;
END;
GO

/* =====================================================================
   Execução de uma etapa com registro em dw.log_execucao
   (início, fim, linhas afetadas, status e mensagem de erro).
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_executar_etapa
    @id_execucao       UNIQUEIDENTIFIER,
    @nu_ano_referencia INT,
    @no_etapa          VARCHAR(100),
    @no_procedure      VARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id_log INT, @qt INT;

    INSERT INTO dw.log_execucao (id_execucao, nu_ano_referencia, no_etapa, no_procedure, dt_inicio, ds_status)
    VALUES (@id_execucao, @nu_ano_referencia, @no_etapa, @no_procedure, SYSDATETIME(), 'EXECUTANDO');
    SET @id_log = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC @no_procedure @nu_ano_referencia = @nu_ano_referencia, @qt_linhas = @qt OUTPUT;

        UPDATE dw.log_execucao
           SET dt_fim = SYSDATETIME(), qt_linhas = @qt, ds_status = 'SUCESSO'
         WHERE id_log_execucao = @id_log;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE dw.log_execucao
           SET dt_fim = SYSDATETIME(),
               ds_status = 'ERRO',
               ds_mensagem = CONCAT('Erro ', ERROR_NUMBER(), ' em ', ISNULL(ERROR_PROCEDURE(), @no_procedure),
                                    ', linha ', ERROR_LINE(), ': ', ERROR_MESSAGE())
         WHERE id_log_execucao = @id_log;

        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   ORQUESTRADOR – executa o pipeline completo de um ano de referência
   @fl_recarregar_staging = 0 reaproveita a staging já carregada
   (útil para reprocessar só o DW).
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_executar_pipeline
    @nu_ano_referencia     INT,
    @fl_recarregar_staging BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id_execucao UNIQUEIDENTIFIER = NEWID();

    -- lido pelos triggers para ligar auditoria e logs a esta execução
    EXEC sys.sp_set_session_context @key = N'id_execucao', @value = @id_execucao;

    BEGIN TRY
        EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '0 - Validação de pré-condições', 'dw.usp_validar_ordem_carga';

        IF @fl_recarregar_staging = 1
            EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '1 - Carga da staging (CSV)',  'staging.usp_carregar_staging';

        EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '2 - Dimensão tempo',             'dw.usp_carregar_dim_tempo';
        EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '3 - Dimensão etapa de ensino',   'dw.usp_carregar_dim_etapa_ensino';
        EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '4 - Dimensão município (SCD1)',  'dw.usp_carregar_dim_municipio';
        EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '5 - Dimensão escola (SCD2)',     'dw.usp_carregar_dim_escola';
        EXEC dw.usp_executar_etapa @id_execucao, @nu_ano_referencia, '6 - Fato matrícula',             'dw.usp_carregar_fact_matricula';
    END TRY
    BEGIN CATCH
        EXEC sys.sp_set_session_context @key = N'id_execucao', @value = NULL;
        THROW;
    END CATCH;

    EXEC sys.sp_set_session_context @key = N'id_execucao', @value = NULL;

    -- resumo da execução
    SELECT no_etapa, ds_status, qt_linhas,
           duracao_s = CAST(DATEDIFF(MILLISECOND, dt_inicio, dt_fim) / 1000.0 AS DECIMAL(10, 1)),
           ds_mensagem
    FROM dw.log_execucao
    WHERE id_execucao = @id_execucao
    ORDER BY id_log_execucao;
END;
GO

/* =====================================================================
   UTILITÁRIO – gera o arquivo de formato XML de um CSV do INEP a partir
   do seu cabeçalho, para incluir um novo ano no pipeline.
   Uso: copie o resultado para um arquivo .xml e cadastre o caminho em
        staging.arquivo_fonte.
   Ex.: EXEC staging.usp_gerar_arquivo_formato
            '/var/opt/mssql/projeto/.../microdados_ed_basica_2024.csv',
            'NU_ANO_CENSO,SG_UF,CO_ENTIDADE,QT_MAT_BAS';
   ===================================================================== */
CREATE OR ALTER PROCEDURE staging.usp_gerar_arquivo_formato
    @ds_caminho_csv VARCHAR(400),
    @ds_colunas     VARCHAR(MAX)   -- colunas a expor, separadas por vírgula
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql NVARCHAR(MAX), @cabecalho VARCHAR(MAX), @xml VARCHAR(MAX), @n INT;

    SET @sql = N'SELECT @c = LEFT(BulkColumn, CHARINDEX(CHAR(10), BulkColumn) - 1)
                 FROM OPENROWSET(BULK ''' + REPLACE(@ds_caminho_csv, '''', '''''') + N''', SINGLE_CLOB) AS arq;';
    EXEC sys.sp_executesql @sql, N'@c VARCHAR(MAX) OUTPUT', @c = @cabecalho OUTPUT;

    SET @cabecalho = REPLACE(@cabecalho, CHAR(13), '');

    SELECT nr = CAST([key] AS INT) + 1, nome = CAST([value] AS VARCHAR(128))
    INTO #campo
    FROM OPENJSON('["' + REPLACE(STRING_ESCAPE(@cabecalho, 'json'), ';', '","') + '"]');
    SET @n = @@ROWCOUNT;

    SELECT nome = TRIM(value) INTO #selecionada FROM STRING_SPLIT(@ds_colunas, ',');

    SELECT @xml =
          '<?xml version="1.0"?>' + CHAR(10)
        + '<BCPFORMAT xmlns="http://schemas.microsoft.com/sqlserver/2004/bulkload/format" '
        + 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' + CHAR(10)
        + ' <RECORD>' + CHAR(10)
        + (SELECT STRING_AGG(CAST('  <FIELD ID="' + CAST(nr AS VARCHAR(10)) + '" xsi:type="CharTerm" TERMINATOR="'
                                  + CASE WHEN nr = @n THEN '\n' ELSE ';' END
                                  + '" MAX_LENGTH="2000"/>' AS VARCHAR(MAX)), CHAR(10))
                  WITHIN GROUP (ORDER BY nr)
           FROM #campo) + CHAR(10)
        + ' </RECORD>' + CHAR(10) + ' <ROW>' + CHAR(10)
        + (SELECT STRING_AGG(CAST('  <COLUMN SOURCE="' + CAST(c.nr AS VARCHAR(10)) + '" NAME="' + c.nome
                                  + '" xsi:type="SQLVARYCHAR"/>' AS VARCHAR(MAX)), CHAR(10))
                  WITHIN GROUP (ORDER BY c.nr)
           FROM #campo AS c JOIN #selecionada AS s ON s.nome = c.nome) + CHAR(10)
        + ' </ROW>' + CHAR(10) + '</BCPFORMAT>';

    SELECT arquivo_formato_xml = @xml, qt_campos_csv = @n;

    SELECT coluna_nao_encontrada = s.nome
    FROM #selecionada AS s
    WHERE NOT EXISTS (SELECT 1 FROM #campo AS c WHERE c.nome = s.nome);
END;
GO

/* =====================================================================
   Visão analítica (disponibilização para relatórios e dashboards)
   ===================================================================== */
CREATE OR ALTER VIEW dw.vw_matricula
AS
SELECT t.ano,
       t.dt_calendario                AS dt_referencia,
       m.uf,
       m.co_municipio,
       m.nome_municipio,
       e.co_entidade,
       e.no_entidade,
       e.tp_rede_ensino,
       CASE e.tp_rede_ensino WHEN 1 THEN 'Federal' WHEN 2 THEN 'Estadual'
                             WHEN 3 THEN 'Municipal' WHEN 4 THEN 'Privada' END AS ds_rede_ensino,
       et.tp_etapa_ensino,
       et.ds_etapa_ensino,
       f.qt_matricula
FROM dw.fact_matricula   AS f
JOIN dw.dim_tempo        AS t  ON t.sk_tempo         = f.sk_tempo
JOIN dw.dim_escola       AS e  ON e.sk_escola        = f.sk_escola
JOIN dw.dim_municipio    AS m  ON m.sk_municipio     = f.sk_municipio
JOIN dw.dim_etapa_ensino AS et ON et.sk_etapa_ensino = f.sk_etapa_ensino;
GO
