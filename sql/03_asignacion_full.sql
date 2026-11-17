-- 03 (modo FULL): segmentacion por percentil acumulado de UB ajustada + flujo Diamante.
-- Regular: igual que el notebook "mes 0" (el total del percentil incluye a los "Sin asignar").
-- Diamante: los grupos de {{ grupos_diamante }} se tratan como UN solo grupo (por SAP). Se rankea a TODOS los clientes
--   (incluidos "Sin asignar") por UB ajustada; percentil acumulado <= p_diamante => '0 Diamante', con prioridad
--   sobre la segmentacion regular. En des_segmento_regular queda la segmentacion antes del overlay Diamante.
DECLARE p_corte    DATE    DEFAULT @p_corte;
DECLARE p_diamante FLOAT64 DEFAULT @p_diamante;

DELETE FROM `{{ ds }}.seg_segmentacion` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_segmentacion`
  (fecha_corte, cod_grupo_precio_dex, des_grupo_precio_dex, cod_grupo_precio_dex_vs2,
   cod_cliente_dex, cod_cliente_alicorp_actual, sum_vb, sum_ub, sum_ub_ajustada,
   meses_distintos, sin_asignar, ub_ajustada_acum, ub_ajustada_dex, percentil,
   des_segmentacion_transaccional, origen,
   des_segmento_regular, grupo_diamante, percentil_diamante)
WITH
r AS (
  SELECT * FROM `{{ ds }}.seg_resumen_cliente` WHERE fecha_corte = p_corte
),
acum AS (
  SELECT
    r.*,
    SUM(IF(r.sin_asignar = 'Sin asignar', 0, r.sum_ub_ajustada)) OVER (
      PARTITION BY r.cod_grupo_precio_dex_vs2, r.cod_cliente_alicorp_actual
      ORDER BY r.sum_ub_ajustada DESC, r.cod_cliente_dex
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS ub_acum_raw,
    SUM(r.sum_ub_ajustada) OVER (
      PARTITION BY r.cod_grupo_precio_dex_vs2, r.cod_cliente_alicorp_actual
    ) AS ub_ajustada_dex
  FROM r
),
pct AS (
  SELECT
    acum.*,
    IF(sin_asignar = 'Sin asignar', 0, ub_acum_raw) AS ub_ajustada_acum,
    SAFE_DIVIDE(IF(sin_asignar = 'Sin asignar', 0, ub_acum_raw), ub_ajustada_dex) AS percentil
  FROM acum
),
reg AS (
  SELECT
    pct.*,
    IF(meses_distintos <= 3, 'Sin asignar',
       CASE WHEN percentil <= 0.25 THEN '1 Oro+'
            WHEN percentil <= 0.50 THEN '2 Oro'
            WHEN percentil <= 0.75 THEN '3 Plata'
            ELSE '4 Bronce' END) AS seg_regular
  FROM pct
),
dia AS (
  SELECT
    cod_cliente_dex,
    SAFE_DIVIDE(
      SUM(sum_ub_ajustada) OVER (
        PARTITION BY cod_cliente_alicorp_actual
        ORDER BY sum_ub_ajustada DESC, cod_cliente_dex
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
      SUM(sum_ub_ajustada) OVER (PARTITION BY cod_cliente_alicorp_actual)
    ) AS percentil_diamante
  FROM r
  WHERE cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }})
)
SELECT
  p_corte,
  g.cod_grupo_precio_dex,
  g.des_grupo_precio_dex,
  g.cod_grupo_precio_dex_vs2,
  g.cod_cliente_dex,
  g.cod_cliente_alicorp_actual,
  g.sum_vb,
  g.sum_ub,
  g.sum_ub_ajustada,
  g.meses_distintos,
  g.sin_asignar,
  g.ub_ajustada_acum,
  g.ub_ajustada_dex,
  g.percentil,
  IF(d.percentil_diamante <= p_diamante, '0 Diamante', g.seg_regular),
  'FULL',
  g.seg_regular,
  IF(d.cod_cliente_dex IS NOT NULL, 'DIAMANTE', NULL),
  d.percentil_diamante
FROM reg g
LEFT JOIN dia d ON d.cod_cliente_dex = g.cod_cliente_dex;

SELECT
  COUNT(*) AS n_filas,
  COUNTIF(des_segmentacion_transaccional IS NULL)            AS n_sin_segmento,
  COUNTIF(des_segmentacion_transaccional = '0 Diamante')     AS n_diamante,
  COUNTIF(des_segmentacion_transaccional = '1 Oro+')         AS n_oro_plus,
  COUNTIF(des_segmentacion_transaccional = '2 Oro')          AS n_oro,
  COUNTIF(des_segmentacion_transaccional = '3 Plata')        AS n_plata,
  COUNTIF(des_segmentacion_transaccional = '4 Bronce')       AS n_bronce,
  COUNTIF(des_segmentacion_transaccional = 'Sin asignar')    AS n_sin_asignar_seg
FROM `{{ ds }}.seg_segmentacion`
WHERE fecha_corte = p_corte;
