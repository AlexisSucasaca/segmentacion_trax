-- 06 (QA): resumen de cambios de boca por universo, calculado sobre seg_cambios_boca (paso 01b).
-- Equivale a la query agregada original (CMP / AS / TOTAL), con el mapeo del pipeline (MM, AB, Sin asignar -> CMP).
-- Comparables = clientes presentes en el historico en ambos meses.
DECLARE p_corte DATE DEFAULT @p_corte;

WITH comparables AS (
  SELECT * FROM `{{ ds }}.seg_cambios_boca`
  WHERE fecha_corte = p_corte AND cod_boca_ant IS NOT NULL AND cod_boca_act IS NOT NULL
),
por_universo AS (
  SELECT
    u AS universo,
    COUNTIF(univ_ant = u)                                                AS base_mes_ant,
    COUNTIF(univ_ant = u AND univ_act != u)                              AS salen,
    COUNTIF(univ_ant != u AND univ_act = u)                              AS entran,
    COUNTIF(univ_ant = u AND univ_act = u AND tipo_cambio = 'CAMBIO_INTERNO') AS cambios_internos
  FROM comparables, UNNEST(['CMP','AS']) AS u
  GROUP BY universo
),
total AS (
  SELECT
    'TOTAL' AS universo,
    COUNT(*) AS base_mes_ant,
    COUNTIF(tipo_cambio IN ('CAMBIO_UNIVERSO','CAMBIO_INTERNO')) AS salen,   -- clientes con cambio de codigo
    COUNTIF(tipo_cambio IN ('CAMBIO_UNIVERSO','CAMBIO_INTERNO')) AS entran,
    COUNTIF(tipo_cambio = 'CAMBIO_INTERNO') AS cambios_internos
  FROM comparables
)
SELECT
  p_corte AS fecha_corte,
  universo, base_mes_ant, salen, entran,
  IF(universo = 'TOTAL', NULL, entran - salen) AS neto,
  cambios_internos,
  ROUND(SAFE_DIVIDE(salen,  base_mes_ant) * 100, 2) AS pct_salen,
  ROUND(SAFE_DIVIDE(entran, base_mes_ant) * 100, 2) AS pct_entran,
  IF(universo = 'TOTAL', NULL, ROUND(SAFE_DIVIDE(entran - salen, base_mes_ant) * 100, 2)) AS pct_neto
FROM (SELECT * FROM por_universo UNION ALL SELECT * FROM total)
ORDER BY universo;
