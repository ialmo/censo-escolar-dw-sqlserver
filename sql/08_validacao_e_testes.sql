/* =====================================================================
   Projeto Prático 2 – ETL e Data Warehouse – Censo Escolar (INEP)
   Script 08 – Validação da carga e testes das regras
   ---------------------------------------------------------------------
   Seção 1  Conferência automática contra valores esperados
            (calculados de forma independente a partir dos CSVs)
   Seção 2  Monitoramento: log de execução e auditoria
   Seção 3  Qualidade: log de inconsistências
   Seção 4  Evidências das regras RT01–RT06 e do SCD2
   Seção 5  Teste dos triggers com registros inválidos
   Seção 6  Teste de idempotência (reprocessamento de 2025)
   Seção 7  Consultas analíticas de exemplo
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE db_educacional;
GO

/* =====================================================================
   SEÇÃO 1 – Conferência automática (todas as linhas devem dar OK)
   ===================================================================== */
WITH esperado AS (
    SELECT * FROM (VALUES
        ('01 staging – registros 2024',                   215545),
        ('02 staging – registros 2025',                   214192),
        ('03 fato – linhas 2024',                         411643),
        ('04 fato – linhas 2025',                         409480),
        ('05 fato – total de matrículas 2024',          47088922),
        ('06 fato – total de matrículas 2025',          46018380),
        ('07 dim_municipio – municípios',                   5571),
        ('08 dim_escola – total de versões',              229100),
        ('09 dim_escola – versões vigentes (S)',          214192),
        ('10 dim_escola – versões abertas em 2025',        13555),   -- 8.572 alteradas + 4.983 novas
        ('11 dim_escola – versões fechadas em 2024-12-31', 14908),   -- 8.572 alteradas + 6.336 ausentes
        ('12 RT06 – escolas sem matrícula 2024',           36259),
        ('13 RT06 – escolas sem matrícula 2025',           35426),
        ('14 V04 – município sem nome 2025',                   1),
        ('15 V05 – UF inválida corrigida 2025',                1),
        ('16 inconsistências ERRO (2024 e 2025)',              0)
    ) AS v (indicador, valor_esperado)
), obtido AS (
    SELECT '01 staging – registros 2024' AS indicador, COUNT_BIG(*) AS valor_obtido FROM staging.censo_escolar WHERE nu_ano_referencia = 2024
    UNION ALL SELECT '02 staging – registros 2025', COUNT_BIG(*) FROM staging.censo_escolar WHERE nu_ano_referencia = 2025
    UNION ALL SELECT '03 fato – linhas 2024', COUNT_BIG(*) FROM dw.fact_matricula f JOIN dw.dim_tempo t ON t.sk_tempo = f.sk_tempo WHERE t.ano = 2024
    UNION ALL SELECT '04 fato – linhas 2025', COUNT_BIG(*) FROM dw.fact_matricula f JOIN dw.dim_tempo t ON t.sk_tempo = f.sk_tempo WHERE t.ano = 2025
    UNION ALL SELECT '05 fato – total de matrículas 2024', SUM(CAST(f.qt_matricula AS BIGINT)) FROM dw.fact_matricula f JOIN dw.dim_tempo t ON t.sk_tempo = f.sk_tempo WHERE t.ano = 2024
    UNION ALL SELECT '06 fato – total de matrículas 2025', SUM(CAST(f.qt_matricula AS BIGINT)) FROM dw.fact_matricula f JOIN dw.dim_tempo t ON t.sk_tempo = f.sk_tempo WHERE t.ano = 2025
    UNION ALL SELECT '07 dim_municipio – municípios', COUNT_BIG(*) FROM dw.dim_municipio
    UNION ALL SELECT '08 dim_escola – total de versões', COUNT_BIG(*) FROM dw.dim_escola
    UNION ALL SELECT '09 dim_escola – versões vigentes (S)', COUNT_BIG(*) FROM dw.dim_escola WHERE fl_ativo = 'S'
    UNION ALL SELECT '10 dim_escola – versões abertas em 2025', COUNT_BIG(*) FROM dw.dim_escola WHERE dt_inicio = '20250101'
    UNION ALL SELECT '11 dim_escola – versões fechadas em 2024-12-31', COUNT_BIG(*) FROM dw.dim_escola WHERE dt_fim = '20241231'
    UNION ALL SELECT '12 RT06 – escolas sem matrícula 2024', COUNT_BIG(DISTINCT co_entidade) FROM dw.log_inconsistencia WHERE cd_regra = 'RT06' AND nu_ano_referencia = 2024
    UNION ALL SELECT '13 RT06 – escolas sem matrícula 2025', COUNT_BIG(DISTINCT co_entidade) FROM dw.log_inconsistencia WHERE cd_regra = 'RT06' AND nu_ano_referencia = 2025
    UNION ALL SELECT '14 V04 – município sem nome 2025', COUNT_BIG(DISTINCT id_staging) FROM dw.log_inconsistencia l WHERE cd_regra = 'V04' AND nu_ano_referencia = 2025 AND EXISTS (SELECT 1 FROM staging.censo_escolar s WHERE s.id_staging = l.id_staging)
    UNION ALL SELECT '15 V05 – UF inválida corrigida 2025', COUNT_BIG(DISTINCT id_staging) FROM dw.log_inconsistencia l WHERE cd_regra = 'V05' AND nu_ano_referencia = 2025 AND EXISTS (SELECT 1 FROM staging.censo_escolar s WHERE s.id_staging = l.id_staging)
    UNION ALL SELECT '16 inconsistências ERRO (2024 e 2025)', COUNT_BIG(*) FROM dw.log_inconsistencia l WHERE tp_severidade = 'ERRO' AND nu_ano_referencia IN (2024, 2025)
)
SELECT e.indicador, e.valor_esperado, o.valor_obtido,
       CASE WHEN e.valor_esperado = o.valor_obtido THEN 'OK' ELSE '*** DIVERGENTE ***' END AS resultado
FROM esperado AS e
LEFT JOIN obtido AS o ON o.indicador = e.indicador
ORDER BY e.indicador;
GO

-- Reconciliação por etapa: fato x soma das colunas de origem na staging
SELECT t.ano, et.tp_etapa_ensino, et.ds_etapa_ensino,
       SUM(CAST(f.qt_matricula AS BIGINT)) AS qt_matricula
FROM dw.fact_matricula f
JOIN dw.dim_tempo t         ON t.sk_tempo = f.sk_tempo
JOIN dw.dim_etapa_ensino et ON et.sk_etapa_ensino = f.sk_etapa_ensino
GROUP BY t.ano, et.tp_etapa_ensino, et.ds_etapa_ensino
ORDER BY t.ano, et.tp_etapa_ensino;
/* Esperado (2024 | 2025):
   1 Creche          4.187.691 |  4.182.646     5 Médio          7.790.396 | 7.370.879
   2 Pré-escola      5.304.203 |  5.103.536     6 Profissional   1.412.957 | 1.302.483
   3 Fund. iniciais 14.498.233 | 14.514.244     7 EJA fund.      1.414.929 | 1.406.442
   4 Fund. finais   11.504.123 | 11.292.523     8 EJA médio        976.390 |   845.627 */

-- Total da fato = soma de QT_MAT_BAS informada pelo INEP
SELECT s.nu_ano_referencia,
       SUM(CAST(dw.fn_converter_inteiro(s.qt_mat_bas) AS BIGINT)) AS qt_mat_bas_inep,
       (SELECT SUM(CAST(f.qt_matricula AS BIGINT)) FROM dw.fact_matricula f
          JOIN dw.dim_tempo t ON t.sk_tempo = f.sk_tempo WHERE t.ano = s.nu_ano_referencia) AS qt_fato
FROM staging.censo_escolar s
GROUP BY s.nu_ano_referencia;
GO

/* =====================================================================
   SEÇÃO 2 – Monitoramento e auditoria
   ===================================================================== */
SELECT id_execucao, nu_ano_referencia, no_etapa, ds_status, qt_linhas,
       dt_inicio, dt_fim, DATEDIFF(SECOND, dt_inicio, dt_fim) AS duracao_s, ds_mensagem, no_usuario
FROM dw.log_execucao
ORDER BY id_log_execucao;

SELECT * FROM dw.auditoria ORDER BY id_auditoria;     -- item 7
GO

/* =====================================================================
   SEÇÃO 3 – Log de inconsistências (RF08)
   ===================================================================== */
SELECT nu_ano_referencia, no_objeto_origem, cd_regra, tp_severidade,
       COUNT(*) AS qt_registros, MIN(ds_inconsistencia) AS exemplo
FROM dw.log_inconsistencia
GROUP BY nu_ano_referencia, no_objeto_origem, cd_regra, tp_severidade
ORDER BY nu_ano_referencia, cd_regra;

-- Caso real de 2025: escola sem UF e sem nome de município no CSV
SELECT l.cd_regra, l.ds_inconsistencia, s.co_entidade, s.sg_uf, s.no_municipio, s.co_municipio
FROM dw.log_inconsistencia l
JOIN staging.censo_escolar s ON s.id_staging = l.id_staging
WHERE l.cd_regra IN ('V04', 'V05');

SELECT e.co_entidade, e.no_entidade, m.co_municipio, m.nome_municipio, m.uf
FROM dw.dim_escola e JOIN dw.dim_municipio m ON m.co_municipio = e.co_municipio
WHERE e.co_entidade = 43145833;
GO

/* =====================================================================
   SEÇÃO 4 – Evidências das regras de transformação
   ===================================================================== */
-- RT01/RT02/RT03: nome original (staging) x nome padronizado (DW)
SELECT TOP (15) s.no_entidade AS original_escola, e.no_entidade AS padronizado_escola,
                s.no_municipio AS original_municipio, m.nome_municipio AS padronizado_municipio
FROM staging.censo_escolar s
JOIN dw.dim_escola e    ON e.co_entidade = CAST(s.co_entidade AS BIGINT) AND e.fl_ativo = 'S'
JOIN dw.dim_municipio m ON m.co_municipio = e.co_municipio
WHERE s.nu_ano_referencia = 2025
  AND s.no_entidade COLLATE Latin1_General_CS_AS LIKE '%[ÁÂÃÉÊÍÓÔÕÚÇáâãéêíóôõúç]%';

-- RT04: UFs na dimensão (27 valores válidos)
SELECT uf, COUNT(*) AS qt_municipios FROM dw.dim_municipio GROUP BY uf ORDER BY uf;

-- RT05: a etapa 6 soma até 5 colunas de origem (2025)
SELECT TOP (5) s.co_entidade, s.qt_mat_prof_tec_conc, s.qt_mat_prof_tec_subs, s.qt_mat_prof_fic_conc,
       s.qt_mat_prof_tec_iftp_ct, s.qt_mat_prof_iftp_qp, v.qt_matricula AS qt_fato_etapa_6
FROM staging.censo_escolar s
JOIN dw.vw_matricula v ON v.co_entidade = CAST(s.co_entidade AS BIGINT) AND v.ano = 2025 AND v.tp_etapa_ensino = 6
WHERE s.nu_ano_referencia = 2025
  AND (SELECT COUNT(*) FROM (VALUES (s.qt_mat_prof_tec_conc), (s.qt_mat_prof_tec_subs), (s.qt_mat_prof_fic_conc),
                                     (s.qt_mat_prof_tec_iftp_ct), (s.qt_mat_prof_iftp_qp)) x(q)
       WHERE dw.fn_converter_inteiro(x.q) > 0) >= 2;

-- SCD2: histórico de escolas que mudaram de nome entre 2024 e 2025
SELECT sk_escola, co_entidade, no_entidade, co_municipio, tp_rede_ensino, dt_inicio, dt_fim, fl_ativo
FROM dw.dim_escola
WHERE co_entidade IN (11007257, 11007885)
ORDER BY co_entidade, dt_inicio;

-- SCD2: a fato de cada ano aponta para a versão vigente naquele ano
SELECT v.ano, v.co_entidade, v.no_entidade, SUM(v.qt_matricula) AS qt_matricula
FROM dw.vw_matricula v
WHERE v.co_entidade = 11007257
GROUP BY v.ano, v.co_entidade, v.no_entidade;
GO

/* =====================================================================
   SEÇÃO 5 – Teste dos triggers com registros inválidos
   Usa o ano fictício 1900 e remove os registros de teste ao final
   (o log e a auditoria permanecem como evidência).
   ===================================================================== */
INSERT INTO staging.censo_escolar
    (nu_ano_referencia, no_arquivo_origem, nu_ano_censo, sg_uf, co_uf, no_municipio, co_municipio,
     no_entidade, co_entidade, tp_dependencia, tp_situacao_funcionamento,
     qt_mat_bas, qt_mat_inf_cre, qt_mat_med)
VALUES
    (1900, 'TESTE', '1900', 'SP', '35', 'São Paulo', '3550308', '',            'ABC',      '3', '1', '10', '10', '0'),  -- V01, V02
    (1900, 'TESTE', '1900', 'XX', '35', 'São Paulo', '3550308', 'ESCOLA TESTE','99999901', '2', '1', '10', '5',  '-5'), -- V05, V09, V10
    (1900, 'TESTE', '1899', 'MG', '31', 'Teste',     '123',     'ESCOLA TESTE','99999902', '9', '1', NULL, NULL, NULL), -- V03, V07, V08
    (1900, 'TESTE', '1900', 'RJ', '35', 'São Paulo', '3550308', 'ESCOLA TESTE','99999903', '4', '1', NULL, NULL, NULL); -- V06

SELECT cd_regra, tp_severidade, co_entidade, no_campo, vl_campo, ds_inconsistencia
FROM dw.log_inconsistencia
WHERE nu_ano_referencia = 1900
ORDER BY id_log;

SELECT * FROM dw.auditoria WHERE nu_ano_referencia = 1900;   -- carga de teste também auditada

DELETE FROM staging.censo_escolar WHERE nu_ano_referencia = 1900;
GO

-- RT06 no trigger INSTEAD OF: inserção manual com quantidade zero
DECLARE @sk_tempo INT = dw.fn_sk_tempo(dw.fn_data_referencia_censo(2025)),
        @sk_escola INT, @sk_municipio INT;

SELECT TOP (1) @sk_escola = e.sk_escola, @sk_municipio = m.sk_municipio
FROM dw.dim_escola e JOIN dw.dim_municipio m ON m.co_municipio = e.co_municipio
WHERE e.fl_ativo = 'S';

INSERT INTO dw.fact_matricula (sk_tempo, sk_escola, sk_municipio, sk_etapa_ensino, qt_matricula, dt_carga)
VALUES (@sk_tempo, @sk_escola, @sk_municipio, (SELECT sk_etapa_ensino FROM dw.dim_etapa_ensino WHERE tp_etapa_ensino = 8), 0, SYSDATETIME());

SELECT TOP (1) cd_regra, co_entidade, vl_campo, ds_inconsistencia, dt_registro
FROM dw.log_inconsistencia
WHERE cd_regra = 'RT06' AND id_execucao IS NULL
ORDER BY id_log DESC;
GO

/* =====================================================================
   SEÇÃO 6 – Idempotência: reprocessar 2025 não altera os totais
   (leva alguns minutos – recarrega o CSV e o DW do ano)
   ===================================================================== */
DROP TABLE IF EXISTS #antes;
SELECT (SELECT COUNT(*) FROM dw.fact_matricula)                AS linhas_fato,
       (SELECT SUM(CAST(qt_matricula AS BIGINT)) FROM dw.fact_matricula) AS total_matriculas,
       (SELECT COUNT(*) FROM dw.dim_escola)                    AS versoes_escola,
       (SELECT COUNT(*) FROM dw.dim_municipio)                 AS municipios
INTO #antes;

EXEC dw.usp_executar_pipeline @nu_ano_referencia = 2025;

SELECT 'antes' AS momento, * FROM #antes
UNION ALL
SELECT 'depois',
       (SELECT COUNT(*) FROM dw.fact_matricula),
       (SELECT SUM(CAST(qt_matricula AS BIGINT)) FROM dw.fact_matricula),
       (SELECT COUNT(*) FROM dw.dim_escola),
       (SELECT COUNT(*) FROM dw.dim_municipio);

-- carga fora de ordem é recusada (deve terminar com erro 50020)
BEGIN TRY
    EXEC dw.usp_executar_pipeline @nu_ano_referencia = 2024, @fl_recarregar_staging = 0;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS erro_esperado_50020, ERROR_MESSAGE() AS mensagem;
END CATCH;
GO

/* =====================================================================
   SEÇÃO 7 – Consultas analíticas de exemplo
   ===================================================================== */
-- Matrículas por UF e ano
SELECT uf,
       SUM(CASE WHEN ano = 2024 THEN qt_matricula END) AS mat_2024,
       SUM(CASE WHEN ano = 2025 THEN qt_matricula END) AS mat_2025,
       CAST(100.0 * (SUM(CASE WHEN ano = 2025 THEN qt_matricula END)
                     - SUM(CASE WHEN ano = 2024 THEN qt_matricula END))
            / SUM(CASE WHEN ano = 2024 THEN qt_matricula END) AS DECIMAL(6, 2)) AS variacao_pct
FROM dw.vw_matricula
GROUP BY uf
ORDER BY mat_2025 DESC;

-- Participação de cada rede por etapa (2025)
SELECT ds_etapa_ensino, ds_rede_ensino, SUM(qt_matricula) AS qt_matricula,
       CAST(100.0 * SUM(qt_matricula) / SUM(SUM(qt_matricula)) OVER (PARTITION BY ds_etapa_ensino) AS DECIMAL(5, 1)) AS pct_etapa
FROM dw.vw_matricula
WHERE ano = 2025
GROUP BY tp_etapa_ensino, ds_etapa_ensino, ds_rede_ensino
ORDER BY tp_etapa_ensino, qt_matricula DESC;

-- 10 municípios com mais matrículas em 2025
SELECT TOP (10) nome_municipio, uf, SUM(qt_matricula) AS qt_matricula
FROM dw.vw_matricula
WHERE ano = 2025
GROUP BY nome_municipio, uf
ORDER BY qt_matricula DESC;
GO
