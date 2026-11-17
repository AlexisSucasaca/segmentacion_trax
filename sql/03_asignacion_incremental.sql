-- 03 (modos NEXT_MONTH y REASSIGN): umbrales congelados del ultimo FULL.
--   solo_sin_asignar = TRUE  -> NEXT_MONTH: reevalua solo los "Sin asignar" previos y agrega nuevos.
--                               Usa umbrales Oro+/Oro/Plata/Bronce. NO evalua Diamante; los Diamante previos se conservan.
--   solo_sin_asignar = FALSE -> REASSIGN:   reevalua TODOS los previos y agrega nuevos.
--                               Evalua Diamante con el umbral congelado (UB >= min_diamante, grupos {{ grupos_diamante }}),
--                               con prioridad sobre la segmentacion regular (tambien para "Sin asignar").
-- La UB y el estado "Sin asignar" salen de la ventana NUEVA.
-- Segmentacion previa: {{ prev_tabla }} (seg_segmentacion o la copia de la oficial, segun fuente_prev).
DECLARE p_corte DATE DEFAULT @p_corte;
DECLARE p_prev  DATE DEFAULT @p_prev;
DECLARE p_umb   DATE DEFAULT @p_umb;
DECLARE v_solo  BOOL DEFAULT @solo_sin_asignar;

DELETE FROM `{{ ds }}.seg_segmentacion` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_segmentacion`
  (fecha_corte, cod_grupo_precio_dex, des_grupo_precio_dex, cod_grupo_precio_dex_vs2,
   cod_cliente_dex, cod_cliente_alicorp_actual, sum_vb, sum_ub, sum_ub_ajustada,
   meses_distintos, sin_asignar, ub_ajustada_acum, ub_ajustada_dex, percentil,
   des_segmentacion_transaccional, origen,
   des_segmento_regular, grupo_diamante, percentil_diamante)
WITH
prev AS (
  SELECT * FROM `{{ prev_tabla }}` WHERE fecha_corte = p_prev
),
nuevo AS (
  SELECT * FROM `{{ ds }}.seg_resumen_cliente` WHERE fecha_corte = p_corte
),
umb AS (
  SELECT * FROM `{{ ds }}.seg_umbrales` WHERE fecha_corte = p_umb
),
umb_d AS (
  SELECT * FROM `{{ ds }}.seg_umbrales_diamante` WHERE fecha_corte = p_umb
),
base_scored AS (
  SELECT
    n.*,
    IF(n.sin_asignar = 'Sin asignar', 'Sin asignar',
       `{{ ds }}.fn_asignar_seg`(n.sum_ub_ajustada, u.min_oro_plus, u.min_oro, u.min_plata, u.min_bronce)
    ) AS seg_regular,
    d.min_diamante
  FROM nuevo n
  LEFT JOIN umb u
    ON  u.cod_grupo_precio_dex_vs2   = n.cod_grupo_precio_dex_vs2
    AND u.cod_cliente_alicorp_actual = n.cod_cliente_alicorp_actual
  LEFT JOIN umb_d d
    ON  d.cod_cliente_alicorp_actual = n.cod_cliente_alicorp_actual
    AND n.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }})
),
scored AS (
  SELECT
    b.*,
    IF((NOT v_solo) AND b.min_diamante IS NOT NULL AND b.sum_ub_ajustada >= b.min_diamante,
       '0 Diamante', b.seg_regular) AS seg_nuevo
  FROM base_scored b
)
-- A) previos que se conservan (o que ya no tienen datos en la ventana)
SELECT
  p_corte, p.cod_grupo_precio_dex, p.des_grupo_precio_dex, p.cod_grupo_precio_dex_vs2,
  p.cod_cliente_dex, p.cod_cliente_alicorp_actual, p.sum_vb, p.sum_ub, p.sum_ub_ajustada,
  p.meses_distintos, p.sin_asignar, p.ub_ajustada_acum, p.ub_ajustada_dex, p.percentil,
  p.des_segmentacion_transaccional,
  IF(s.cod_cliente_dex IS NULL, 'Sin datos en ventana', 'Previo'),
  p.des_segmento_regular, p.grupo_diamante, p.percentil_diamante
FROM prev p
LEFT JOIN scored s ON s.cod_cliente_dex = p.cod_cliente_dex
WHERE s.cod_cliente_dex IS NULL
   OR (v_solo AND p.des_segmentacion_transaccional <> 'Sin asignar')

UNION ALL

-- B) previos reevaluados con datos nuevos
SELECT
  p_corte, s.cod_grupo_precio_dex, s.des_grupo_precio_dex, s.cod_grupo_precio_dex_vs2,
  s.cod_cliente_dex, s.cod_cliente_alicorp_actual, s.sum_vb, s.sum_ub, s.sum_ub_ajustada,
  s.meses_distintos, s.sin_asignar,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  s.seg_nuevo,
  'Reevaluado',
  s.seg_regular,
  IF(s.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }}), 'DIAMANTE', NULL),
  CAST(NULL AS FLOAT64)
FROM prev p
JOIN scored s ON s.cod_cliente_dex = p.cod_cliente_dex
WHERE (NOT v_solo) OR p.des_segmentacion_transaccional = 'Sin asignar'

UNION ALL

-- C) clientes nuevos (no estaban en la segmentacion previa)
SELECT
  p_corte, s.cod_grupo_precio_dex, s.des_grupo_precio_dex, s.cod_grupo_precio_dex_vs2,
  s.cod_cliente_dex, s.cod_cliente_alicorp_actual, s.sum_vb, s.sum_ub, s.sum_ub_ajustada,
  s.meses_distintos, s.sin_asignar,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  s.seg_nuevo,
  'Nuevo',
  s.seg_regular,
  IF(s.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }}), 'DIAMANTE', NULL),
  CAST(NULL AS FLOAT64)
FROM scored s
WHERE NOT EXISTS (SELECT 1 FROM prev p WHERE p.cod_cliente_dex = s.cod_cliente_dex);

SELECT
  COUNT(*) AS n_filas,
  (SELECT COUNT(*) FROM `{{ prev_tabla }}` WHERE fecha_corte = p_prev) AS n_filas_prev,
  COUNTIF(des_segmentacion_transaccional IS NULL)          AS n_sin_segmento,
  COUNTIF(origen = 'Previo')               AS n_previo,
  COUNTIF(origen = 'Reevaluado')           AS n_reevaluado,
  COUNTIF(origen = 'Nuevo')                AS n_nuevo,
  COUNTIF(origen = 'Sin datos en ventana') AS n_sin_datos_ventana,
  COUNTIF(des_segmentacion_transaccional = '0 Diamante') AS n_diamante,
  COUNTIF(des_segmentacion_transaccional = 'Sin asignar') AS n_sin_asignar_seg
FROM `{{ ds }}.seg_segmentacion`
WHERE fecha_corte = p_corte;
