/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 04 – Functions de padronização e transformação  (RF07, RT01–RT05)
   ---------------------------------------------------------------------
   Padronização de textos
     dw.fn_remover_acentos     RT01  remove acentos
     dw.fn_limpar_espacos      RT02  TRIM + espaços duplicados/tabulação
     dw.fn_capitalizar         RT03  capitalização (Title Case)
     dw.fn_padronizar_nome           RT01 + RT02 + RT03 (escolas e municípios)
   UF
     dw.fn_uf_valida                 1 se for uma das 27 UFs
     dw.fn_uf_por_codigo_ibge        sigla a partir do código IBGE da UF
     dw.fn_padronizar_uf       RT04  UF sempre válida (corrige pelo IBGE)
   Transformação de dados
     dw.fn_converter_inteiro         texto -> INT (NULL se vazio/inválido)
     dw.fn_data_referencia_censo     última quarta-feira de maio do ano
     dw.fn_sk_tempo                  data -> chave AAAAMMDD
     dw.fn_desdobrar_etapas    RT05  colunas QT_MAT_* -> linhas por etapa
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

/* ---------------------------------------------------------------------
   RT01 – Remover acentos.
   O COLLATE binário garante a troca exata caractere a caractere
   (numa collation CI/AI o 'A' casaria com 'á' e viraria minúsculo).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_remover_acentos (@texto VARCHAR(400))
RETURNS VARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    IF @texto IS NULL RETURN NULL;

    RETURN TRANSLATE(@texto COLLATE Latin1_General_BIN2,
                     'áàâãäåéèêëíìîïóòôõöúùûüçñýÿÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑÝ',
                     'aaaaaaeeeeiiiiooooouuuucnyyAAAAAAEEEEIIIIOOOOOUUUUCNY');
END;
GO

/* ---------------------------------------------------------------------
   RT02 – TRIM. Também troca tabulação, quebra de linha e espaço não
   separável (CHAR 160) por espaço e elimina espaços duplicados.
   Texto vazio vira NULL.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_limpar_espacos (@texto VARCHAR(400))
RETURNS VARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    IF @texto IS NULL RETURN NULL;

    DECLARE @t VARCHAR(400) =
        REPLACE(REPLACE(REPLACE(REPLACE(@texto, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' '), CHAR(160), ' ');

    WHILE CHARINDEX('  ', @t) > 0
        SET @t = REPLACE(@t, '  ', ' ');

    RETURN NULLIF(TRIM(@t), '');
END;
GO

/* ---------------------------------------------------------------------
   RT03 – Capitalização (Title Case) com regras do português:
     * primeira letra de cada palavra em maiúscula, demais minúsculas;
     * também maiúscula após hífen, apóstrofo, parêntese, barra e ponto
       (ex.: "D'Oeste", "Villa-Lobos");
     * preposições/conjunção de, da, do, das, dos, e em minúsculas
       (exceto na primeira palavra);
     * algarismos romanos I a XX mantidos em maiúsculas.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_capitalizar (@texto VARCHAR(400))
RETURNS VARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    IF @texto IS NULL RETURN NULL;

    DECLARE @tamanho  INT = DATALENGTH(@texto),
            @inicio   INT = 1,
            @fim      INT,
            @nr       INT = 0,
            @i        INT,
            @palavra  VARCHAR(400),
            @formato  VARCHAR(400),
            @saida    VARCHAR(400) = '',
            @c        CHAR(1),
            @anterior CHAR(1);

    WHILE @inicio <= @tamanho + 1
    BEGIN
        SET @fim = CHARINDEX(' ', @texto, @inicio);
        IF @fim = 0 SET @fim = @tamanho + 1;

        SET @palavra = SUBSTRING(@texto, @inicio, @fim - @inicio);
        SET @nr += 1;

        IF @palavra = ''
            SET @formato = '';
        ELSE IF @nr > 1 AND LOWER(@palavra) IN ('de', 'da', 'do', 'das', 'dos', 'e')
            SET @formato = LOWER(@palavra);
        ELSE IF UPPER(@palavra) IN ('I','II','III','IV','V','VI','VII','VIII','IX','X',
                                    'XI','XII','XIII','XIV','XV','XVI','XVII','XVIII','XIX','XX')
            SET @formato = UPPER(@palavra);
        ELSE
        BEGIN
            SELECT @formato = '', @i = 1, @anterior = ' ';
            WHILE @i <= DATALENGTH(@palavra)
            BEGIN
                SET @c = SUBSTRING(@palavra, @i, 1);
                SET @formato += CASE WHEN @i = 1 OR @anterior IN ('-', '''', '(', '/', '.')
                                     THEN UPPER(@c) ELSE LOWER(@c) END;
                SET @anterior = @c;
                SET @i += 1;
            END;
        END;

        SET @saida += CASE WHEN @nr > 1 THEN ' ' ELSE '' END + @formato;
        SET @inicio = @fim + 1;
    END;

    RETURN @saida;
END;
GO

/* ---------------------------------------------------------------------
   RT01 + RT02 + RT03 – padronização completa de nomes de escolas e
   municípios. Ex.: '  ESCOLA ESTADUAL  JOÃO DE DEUS ' -> 'Escola Estadual Joao de Deus'
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_padronizar_nome (@texto VARCHAR(400))
RETURNS VARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    RETURN dw.fn_capitalizar(dw.fn_limpar_espacos(dw.fn_remover_acentos(@texto)));
END;
GO

/* ---------------------------------------------------------------------
   UF válida: uma das 27 unidades federativas.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_uf_valida (@uf VARCHAR(10))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN UPPER(TRIM(@uf)) COLLATE Latin1_General_BIN2 IN
                     ('AC','AL','AM','AP','BA','CE','DF','ES','GO','MA','MG','MS','MT','PA',
                      'PB','PE','PI','PR','RJ','RN','RO','RR','RS','SC','SE','SP','TO')
                THEN 1 ELSE 0 END;
END;
GO

/* ---------------------------------------------------------------------
   Sigla da UF a partir do código IBGE da UF (2 primeiros dígitos do
   código do município).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_uf_por_codigo_ibge (@co_uf INT)
RETURNS CHAR(2)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE @co_uf
        WHEN 11 THEN 'RO' WHEN 12 THEN 'AC' WHEN 13 THEN 'AM' WHEN 14 THEN 'RR'
        WHEN 15 THEN 'PA' WHEN 16 THEN 'AP' WHEN 17 THEN 'TO' WHEN 21 THEN 'MA'
        WHEN 22 THEN 'PI' WHEN 23 THEN 'CE' WHEN 24 THEN 'RN' WHEN 25 THEN 'PB'
        WHEN 26 THEN 'PE' WHEN 27 THEN 'AL' WHEN 28 THEN 'SE' WHEN 29 THEN 'BA'
        WHEN 31 THEN 'MG' WHEN 32 THEN 'ES' WHEN 33 THEN 'RJ' WHEN 35 THEN 'SP'
        WHEN 41 THEN 'PR' WHEN 42 THEN 'SC' WHEN 43 THEN 'RS' WHEN 50 THEN 'MS'
        WHEN 51 THEN 'MT' WHEN 52 THEN 'GO' WHEN 53 THEN 'DF'
    END;
END;
GO

/* ---------------------------------------------------------------------
   RT04 – UF sempre em formato válido: TRIM + maiúsculas; se ainda assim
   for inválida (vazia, digitada errada), deriva do código IBGE do
   município. Retorna NULL apenas se nenhuma das duas fontes for válida.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_padronizar_uf (@sg_uf VARCHAR(10), @co_municipio VARCHAR(20))
RETURNS CHAR(2)
WITH SCHEMABINDING
AS
BEGIN
    IF dw.fn_uf_valida(@sg_uf) = 1
        RETURN UPPER(TRIM(@sg_uf));

    RETURN dw.fn_uf_por_codigo_ibge(TRY_CAST(LEFT(TRIM(@co_municipio), 2) AS INT));
END;
GO

/* ---------------------------------------------------------------------
   Conversão segura de texto para inteiro (vazio ou inválido -> NULL).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_converter_inteiro (@valor VARCHAR(50))
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    RETURN TRY_CAST(NULLIF(TRIM(@valor), '') AS INT);
END;
GO

/* ---------------------------------------------------------------------
   Data de referência do Censo Escolar: última quarta-feira de maio.
   Cálculo independente de SET DATEFIRST (03/01/1900 foi quarta-feira).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_data_referencia_censo (@ano INT)
RETURNS DATE
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @ultimo_dia DATE = DATEFROMPARTS(@ano, 5, 31);
    RETURN DATEADD(DAY, -(DATEDIFF(DAY, CAST('19000103' AS DATE), @ultimo_dia) % 7), @ultimo_dia);
END;
GO

/* ---------------------------------------------------------------------
   Chave da dim_tempo no formato AAAAMMDD.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_sk_tempo (@data DATE)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    RETURN YEAR(@data) * 10000 + MONTH(@data) * 100 + DAY(@data);
END;
GO

/* ---------------------------------------------------------------------
   Desdobra as colunas de matrícula de uma escola em linhas
   (tp_etapa_ensino, qt_matricula) – UNPIVOT tipado.
   A etapa 6 (Educação Profissional) recebe várias colunas de origem;
   a soma por etapa (RT05) é feita na procedure de carga da fato.
   As 8 etapas são mutuamente exclusivas: a soma é igual a QT_MAT_BAS.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dw.fn_desdobrar_etapas (
    @qt_mat_inf_cre           VARCHAR(20),
    @qt_mat_inf_pre           VARCHAR(20),
    @qt_mat_fund_ai           VARCHAR(20),
    @qt_mat_fund_af           VARCHAR(20),
    @qt_mat_med               VARCHAR(20),
    @qt_mat_prof_tec_conc     VARCHAR(20),
    @qt_mat_prof_tec_subs     VARCHAR(20),
    @qt_mat_prof_fic_conc     VARCHAR(20),
    @qt_mat_prof_tec_iftp_ct  VARCHAR(20),
    @qt_mat_prof_iftp_qp      VARCHAR(20),
    @qt_mat_eja_fund          VARCHAR(20),
    @qt_mat_eja_med           VARCHAR(20)
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT v.tp_etapa_ensino, v.no_coluna_origem, v.qt_matricula
    FROM (VALUES
        (1, 'QT_MAT_INF_CRE',          dw.fn_converter_inteiro(@qt_mat_inf_cre)),
        (2, 'QT_MAT_INF_PRE',          dw.fn_converter_inteiro(@qt_mat_inf_pre)),
        (3, 'QT_MAT_FUND_AI',          dw.fn_converter_inteiro(@qt_mat_fund_ai)),
        (4, 'QT_MAT_FUND_AF',          dw.fn_converter_inteiro(@qt_mat_fund_af)),
        (5, 'QT_MAT_MED',              dw.fn_converter_inteiro(@qt_mat_med)),
        (6, 'QT_MAT_PROF_TEC_CONC',    dw.fn_converter_inteiro(@qt_mat_prof_tec_conc)),
        (6, 'QT_MAT_PROF_TEC_SUBS',    dw.fn_converter_inteiro(@qt_mat_prof_tec_subs)),
        (6, 'QT_MAT_PROF_FIC_CONC',    dw.fn_converter_inteiro(@qt_mat_prof_fic_conc)),
        (6, 'QT_MAT_PROF_TEC_IFTP_CT', dw.fn_converter_inteiro(@qt_mat_prof_tec_iftp_ct)),
        (6, 'QT_MAT_PROF_IFTP_QP',     dw.fn_converter_inteiro(@qt_mat_prof_iftp_qp)),
        (7, 'QT_MAT_EJA_FUND',         dw.fn_converter_inteiro(@qt_mat_eja_fund)),
        (8, 'QT_MAT_EJA_MED',          dw.fn_converter_inteiro(@qt_mat_eja_med))
    ) AS v (tp_etapa_ensino, no_coluna_origem, qt_matricula);
GO

/* Testes rápidos das funções */
SELECT dw.fn_padronizar_nome('  ESCOLA ESTADUAL  JOÃO   DE DEUS ')            AS rt01_02_03,
       dw.fn_padronizar_nome('ALTA FLORESTA D''OESTE')                         AS apostrofo,
       dw.fn_padronizar_nome('EEEMTI HEITOR VILLA-LOBOS')                      AS hifen,
       dw.fn_padronizar_nome('COLEGIO TIRADENTES DA POLICIA MILITAR - CTPM V') AS romano,
       dw.fn_padronizar_uf(' sp ', '3550308')                                  AS uf_minuscula,
       dw.fn_padronizar_uf('', '4319901')                                      AS uf_vazia_rs,
       dw.fn_data_referencia_censo(2024)                                       AS ref_2024,  -- 2024-05-29
       dw.fn_data_referencia_censo(2025)                                       AS ref_2025;  -- 2025-05-28
GO
