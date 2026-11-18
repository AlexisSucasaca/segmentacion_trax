-- Dimensiona el impacto de pasar a la boca del historico: compara, para el corte, la boca de
--   (a) la tabla estrategica (cod_boca_salida, fec_corrida = p_corte)
--   (b) cr_cliente_dex_historico en el ultimo mes de la ventana (p_corte - 1 mes)
--   (c) la ultima venta del sell-out en la ventana (regla anterior del paso 01)
-- Todas llevadas a grupo vs2 (BO/MM/AB/Sin asignar -> BO). Edita p_corte.
DECLARE p_corte DATE DEFAULT DATE '2026-10-01';
DECLARE p_ini   DATE DEFAULT DATE_SUB(p_corte, INTERVAL 12 MONTH);
DECLARE p_hist  DATE DEFAULT DATE_SUB(p_corte, INTERVAL 1 MONTH);

CREATE TEMP FUNCTION vs2(c STRING) AS (IF(UPPER(c) IN ('BO','MM','AB','SIN ASIGNAR','GO'), 'BO', c));

WITH
estr AS (
  SELECT SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(id_interlocutor_origen AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64) AS dex,
         ARRAY_AGG(DISTINCT vs2(cod_boca_salida) IGNORE NULLS) AS bocas
  FROM `acpe-prod-uc-ml.delivery_gtm.dex_b2b_cmp_segmentacion_estrategica`
  WHERE SAFE_CAST(fec_corrida AS DATE) = p_corte
  GROUP BY 1
),
hist AS (
  SELECT SAFE_CAST(cod_cliente_dex AS INT64) AS dex,
         vs2(ARRAY_AGG(cod_grupo_precio_dex IGNORE NULLS ORDER BY periodo DESC, cod_grupo_precio_dex LIMIT 1)[SAFE_OFFSET(0)]) AS boca,
         COUNT(DISTINCT cod_grupo_precio_dex) AS n_grupos_en_mes
  FROM `acpe-prod-dlk-shrd-gld.delivery_modelo_dimensional.cr_cliente_dex_historico`
  WHERE DATE_TRUNC(periodo, MONTH) = p_hist
  GROUP BY 1
),
venta AS (
  SELECT SAFE_CAST(cod_cliente_dex AS INT64) AS dex,
         vs2(ARRAY_AGG(cod_grupo_precio_dex ORDER BY periodo DESC, cod_grupo_precio_dex LIMIT 1)[OFFSET(0)]) AS boca
  FROM `acpe-prod-dlk-shrd-gld.delivery_reporte_comercial.cr_venta_sell_out`
  WHERE periodo >= p_ini AND periodo < p_corte
  GROUP BY 1
)
SELECT
  COUNT(*)                                                                    AS n_clientes_union,
  COUNTIF(e.dex IS NOT NULL AND h.dex IS NOT NULL)                            AS n_en_estr_e_hist,
  COUNTIF(e.dex IS NOT NULL AND h.dex IS NOT NULL
          AND h.boca NOT IN UNNEST(e.bocas))                                  AS n_estr_dif_hist,
  COUNTIF(h.dex IS NOT NULL AND v.dex IS NOT NULL AND h.boca != v.boca)       AS n_hist_dif_venta,
  COUNTIF(e.dex IS NOT NULL AND v.dex IS NOT NULL AND v.boca NOT IN UNNEST(e.bocas)) AS n_venta_dif_estr,
  COUNTIF(h.n_grupos_en_mes > 1)                                              AS n_hist_multi_grupo_mes,   -- debe ser 0 si cliente-mes es unico
  COUNTIF(h.dex IS NULL AND v.dex IS NOT NULL)                                AS n_con_venta_sin_hist
FROM estr e
FULL OUTER JOIN hist h  ON h.dex = e.dex
FULL OUTER JOIN venta v ON v.dex = COALESCE(e.dex, h.dex);
