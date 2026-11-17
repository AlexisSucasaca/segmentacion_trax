-- 02: resumen por cliente DEX en la ventana. Comun a los tres modos.
DECLARE p_corte DATE DEFAULT @p_corte;

DELETE FROM `{{ ds }}.seg_resumen_cliente` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_resumen_cliente`
  (fecha_corte, cod_grupo_precio_dex, des_grupo_precio_dex, cod_grupo_precio_dex_vs2,
   cod_cliente_dex, cod_cliente_alicorp_actual, sum_vb, sum_ub, sum_ub_ajustada,
   meses_distintos, sin_asignar)
WITH
base AS (
  SELECT * FROM `{{ ds }}.seg_base_cliente_mes` WHERE fecha_corte = p_corte
),
-- "mode" del SAP: el de mayor venta (desempate por codigo)
sap_top AS (
  SELECT cod_cliente_dex, cod_cliente_alicorp_actual
  FROM (
    SELECT
      cod_cliente_dex,
      cod_cliente_alicorp_actual,
      ROW_NUMBER() OVER (PARTITION BY cod_cliente_dex
                         ORDER BY SUM(vb) DESC, cod_cliente_alicorp_actual) AS rn
    FROM base
    GROUP BY cod_cliente_dex, cod_cliente_alicorp_actual
  )
  WHERE rn = 1
),
agg AS (
  SELECT
    cod_grupo_precio_dex,
    des_grupo_precio_dex,
    cod_cliente_dex,
    SUM(vb)                 AS sum_vb,
    SUM(ub)                 AS sum_ub,
    SUM(ub_ajustada)        AS sum_ub_ajustada,
    COUNT(DISTINCT periodo) AS meses_distintos
  FROM base
  GROUP BY cod_grupo_precio_dex, des_grupo_precio_dex, cod_cliente_dex
)
SELECT
  p_corte,
  a.cod_grupo_precio_dex,
  a.des_grupo_precio_dex,
  IF(a.cod_grupo_precio_dex IN ('BO','MM','AB','Sin Asignar','Sin asignar'),
     'BO', a.cod_grupo_precio_dex),
  a.cod_cliente_dex,
  s.cod_cliente_alicorp_actual,
  a.sum_vb,
  a.sum_ub,
  a.sum_ub_ajustada,
  a.meses_distintos,
  IF(a.meses_distintos <= 3, 'Sin asignar', 'Asignar')
FROM agg a
JOIN sap_top s ON s.cod_cliente_dex = a.cod_cliente_dex;

SELECT
  COUNT(*)                          AS n_clientes,
  COUNTIF(sin_asignar = 'Sin asignar') AS n_sin_asignar,
  COUNTIF(cod_cliente_alicorp_actual IS NULL) AS n_sin_sap
FROM `{{ ds }}.seg_resumen_cliente`
WHERE fecha_corte = p_corte;
