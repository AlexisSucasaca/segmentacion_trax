-- 04 (solo FULL): umbrales congelados.
--   seg_umbrales:           por (grupo vs2, SAP), min/max de UB ajustada por segmento REGULAR (antes del overlay Diamante,
--                           para que Diamante no altere los umbrales de Oro+/Oro/Plata/Bronce). Sin "Sin asignar".
--   seg_umbrales_diamante:  por SAP (grupos de {{ grupos_diamante }} agrupados), min/max de UB ajustada de los Diamante.
DECLARE p_corte DATE DEFAULT @p_corte;

DELETE FROM `{{ ds }}.seg_umbrales` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_umbrales`
  (fecha_corte, cod_grupo_precio_dex_vs2, cod_cliente_alicorp_actual,
   total_clientes_activos, total_ub_ajustada,
   min_bronce, max_bronce, min_plata, max_plata, min_oro, max_oro, min_oro_plus, max_oro_plus)
SELECT
  p_corte,
  cod_grupo_precio_dex_vs2,
  cod_cliente_alicorp_actual,
  COUNT(DISTINCT cod_cliente_dex),
  SUM(sum_ub_ajustada),
  MIN(IF(des_segmento_regular = '4 Bronce', sum_ub_ajustada, NULL)),
  MAX(IF(des_segmento_regular = '4 Bronce', sum_ub_ajustada, NULL)),
  MIN(IF(des_segmento_regular = '3 Plata',  sum_ub_ajustada, NULL)),
  MAX(IF(des_segmento_regular = '3 Plata',  sum_ub_ajustada, NULL)),
  MIN(IF(des_segmento_regular = '2 Oro',    sum_ub_ajustada, NULL)),
  MAX(IF(des_segmento_regular = '2 Oro',    sum_ub_ajustada, NULL)),
  MIN(IF(des_segmento_regular = '1 Oro+',   sum_ub_ajustada, NULL)),
  MAX(IF(des_segmento_regular = '1 Oro+',   sum_ub_ajustada, NULL))
FROM `{{ ds }}.seg_segmentacion`
WHERE fecha_corte = p_corte
  AND des_segmento_regular IS NOT NULL
  AND des_segmento_regular <> 'Sin asignar'
GROUP BY cod_grupo_precio_dex_vs2, cod_cliente_alicorp_actual;

DELETE FROM `{{ ds }}.seg_umbrales_diamante` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_umbrales_diamante`
  (fecha_corte, grupo_diamante, cod_cliente_alicorp_actual, total_clientes, min_diamante, max_diamante)
SELECT
  p_corte,
  'DIAMANTE',
  cod_cliente_alicorp_actual,
  COUNT(DISTINCT cod_cliente_dex),
  MIN(sum_ub_ajustada),
  MAX(sum_ub_ajustada)
FROM `{{ ds }}.seg_segmentacion`
WHERE fecha_corte = p_corte
  AND des_segmentacion_transaccional = '0 Diamante'
  AND cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }})
GROUP BY cod_cliente_alicorp_actual;

SELECT
  (SELECT COUNT(*) FROM `{{ ds }}.seg_umbrales` WHERE fecha_corte = p_corte) AS n_filas,
  (SELECT COUNTIF(min_oro_plus IS NULL) FROM `{{ ds }}.seg_umbrales` WHERE fecha_corte = p_corte) AS n_sin_oro_plus,
  (SELECT COUNT(*) FROM `{{ ds }}.seg_umbrales_diamante` WHERE fecha_corte = p_corte) AS n_umbrales_diamante;
