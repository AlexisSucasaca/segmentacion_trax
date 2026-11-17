-- Traza clientes puntuales por el pipeline y diagnostica por que quedan "Por definir".
-- Edita p_corte y la lista de ids (cod_interlocutor tal como aparece en la tabla alterna).
DECLARE p_corte DATE DEFAULT DATE '2026-08-01';
DECLARE p_prev  DATE DEFAULT DATE '2026-07-01';
DECLARE p_ini   DATE DEFAULT DATE_SUB(p_corte, INTERVAL 12 MONTH);
DECLARE ids ARRAY<STRING> DEFAULT [
  '0004200762', '0004201143', '0004201146', '0004201327',
  '0004202001', '0004202030', '0004202291'
];

WITH
c AS (
  SELECT id, SAFE_CAST(id AS INT64) AS dex FROM UNNEST(ids) AS id
),
alt AS (   -- lo que quedo en la tabla alterna
  SELECT cod_interlocutor AS id, STRING_AGG(DISTINCT des_segmento_transaccional) AS seg_alterna
  FROM `acpe-dev-uc-sandbox-aa.dev_segmentacion.seg_tabla_alterna_estrategica_transaccional`
  WHERE periodo = p_corte AND cod_interlocutor IN UNNEST(ids)
  GROUP BY 1
),
fuente AS (   -- tabla estrategica del periodo (nueva fuente): segmento estrategico y boca de salida
  SELECT id_interlocutor_origen AS id,
         STRING_AGG(DISTINCT des_segmento_estrategico) AS seg_fuente,
         STRING_AGG(DISTINCT cod_boca_salida)          AS boca_fuente
  FROM `acpe-prod-uc-ml.delivery_gtm.dex_b2b_cmp_segmentacion_estrategica`
  WHERE SAFE_CAST(fec_corrida AS DATE) = p_corte AND id_interlocutor_origen IN UNNEST(ids)
  GROUP BY 1
),
previa AS (   -- segmentacion oficial del corte previo
  SELECT cod_interlocutor AS id, STRING_AGG(DISTINCT des_segmento_transaccional) AS seg_previa
  FROM `acpe-prod-dlk-shrd-gld.delivery_cliente_gtm.cr_segmentacion`
  WHERE periodo = p_prev AND cod_interlocutor IN UNNEST(ids)
  GROUP BY 1
),
seg AS (      -- resultado interno del pipeline
  SELECT cod_cliente_dex AS dex, origen, meses_distintos, sin_asignar,
         des_segmentacion_transaccional AS seg_interna,
         cod_grupo_precio_dex AS grupo_pipeline, cod_cliente_alicorp_actual AS sap_pipeline
  FROM `acpe-dev-uc-sandbox-aa.dev_segmentacion.seg_segmentacion`
  WHERE fecha_corte = p_corte AND cod_cliente_dex IN (SELECT dex FROM c)
),
venta AS (    -- ventas reales en la ventana (sin ningun filtro del pipeline)
  SELECT
    SAFE_CAST(cod_cliente_dex AS INT64) AS dex,
    COUNT(DISTINCT periodo) AS meses_con_venta,
    ARRAY_AGG(cod_grupo_precio_dex ORDER BY periodo DESC LIMIT 1)[OFFSET(0)] AS grupo_ult_venta,
    ARRAY_AGG(cod_cliente_alicorp_actual IGNORE NULLS ORDER BY periodo DESC LIMIT 1)[SAFE_OFFSET(0)] AS sap_ult_venta
  FROM `acpe-prod-dlk-shrd-gld.delivery_reporte_comercial.cr_venta_sell_out`
  WHERE periodo >= p_ini AND periodo < p_corte
    AND SAFE_CAST(cod_cliente_dex AS INT64) IN (SELECT dex FROM c)
  GROUP BY 1
),
base AS (     -- meses cuya venta SI cruzo con ratios
  SELECT cod_cliente_dex AS dex, COUNT(DISTINCT periodo) AS meses_con_ratio
  FROM `acpe-dev-uc-sandbox-aa.dev_segmentacion.seg_base_cliente_mes`
  WHERE fecha_corte = p_corte AND cod_cliente_dex IN (SELECT dex FROM c)
  GROUP BY 1
),
activo AS (   -- filtro de activos tal como lo aplica el pipeline (foto de hoy)
  SELECT DISTINCT SAFE_CAST(a.id_interlocutor_origen AS INT64) AS dex
  FROM `acpe-prod-dlk-shrd-gld.gld_cliente.dex_cliente` a
  LEFT JOIN `acpe-prod-dlk-shrd-gld.gld_cliente.odoo_mk_dex_cliente` b
    ON a.id_interlocutor_origen = b.id_interlocutor_origen
  WHERE a.est_cliente = 'A' AND b.flg_activo = TRUE
    AND SAFE_CAST(a.id_interlocutor_origen AS INT64) IN (SELECT dex FROM c)
)
SELECT
  c.id,
  previa.seg_previa,
  fuente.seg_fuente           AS seg_estrategico_fuente,
  fuente.boca_fuente,
  alt.seg_alterna,
  seg.origen,
  seg.seg_interna,
  seg.meses_distintos         AS meses_para_regla,      -- los que cuenta la regla de "Sin asignar"
  base.meses_con_ratio,
  venta.meses_con_venta       AS meses_con_venta_real,
  venta.grupo_ult_venta,
  venta.sap_ult_venta,
  activo.dex IS NOT NULL      AS activo_segun_pipeline,
  CASE
    WHEN seg.dex IS NULL AND venta.dex IS NULL
      THEN '1. Sin venta en la ventana (no entra al pipeline)'
    WHEN seg.dex IS NULL AND activo.dex IS NULL
      THEN '2. Vendio, pero no es activo segun el filtro del pipeline'
    WHEN seg.dex IS NULL AND venta.grupo_ult_venta NOT IN ('BO','MM','AB','Sin Asignar','Sin asignar','PM','GA','PA','LV','GO')
      THEN '3. Su grupo de precio esta fuera de la lista valida'
    WHEN seg.dex IS NULL AND base.dex IS NULL
      THEN '4. Sin SAP o sin ratio: su venta no cruza y se pierde'
    WHEN seg.dex IS NULL
      THEN '5. No entra al pipeline por otra causa'
    WHEN seg.sin_asignar = 'Sin asignar' AND venta.meses_con_venta > 3
      THEN '6. Entra, pero solo cuenta <=3 meses porque el resto de su venta no cruza con ratios'
    WHEN seg.sin_asignar = 'Sin asignar'
      THEN '7. Realmente tiene 3 meses o menos con venta'
    WHEN fuente.id IS NULL
      THEN '8. Segmentado internamente, pero NO esta en la tabla estrategica del periodo: no sale en la alterna (salvo completar_con_oficial)'
    WHEN seg.origen = 'Sin datos en ventana'
      THEN '8b. Sin datos en ventana: conserva su segmento previo'
    WHEN alt.seg_alterna = 'Por definir'
      THEN '9. Segmentado internamente pero la alterna dice Por definir (revisar paso 05)'
    ELSE '10. OK'
  END AS diagnostico
FROM c
LEFT JOIN previa  ON previa.id  = c.id
LEFT JOIN fuente  ON fuente.id  = c.id
LEFT JOIN alt     ON alt.id     = c.id
LEFT JOIN seg     ON seg.dex    = c.dex
LEFT JOIN venta   ON venta.dex  = c.dex
LEFT JOIN base    ON base.dex   = c.dex
LEFT JOIN activo  ON activo.dex = c.dex
ORDER BY c.id;
