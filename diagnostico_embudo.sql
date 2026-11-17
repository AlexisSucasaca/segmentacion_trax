-- Embudo de clientes: donde se pierden entre cr_venta_sell_out y seg_base_cliente_mes.
-- Misma logica que sql/01_base_cliente_mes.sql. Requiere seg_estrategica cargada para el corte (paso 00b).
DECLARE p_corte DATE DEFAULT DATE '2026-01-01';
DECLARE p_ini   DATE DEFAULT DATE_SUB(p_corte, INTERVAL 12 MONTH);

-- 1) Embudo por grupo (un cliente cuenta UNA vez, en su grupo de la ultima venta)
WITH
out_raw AS (
  SELECT
    periodo,
    SAFE_CAST(cod_cliente_dex AS INT64) AS dex,
    REGEXP_REPLACE(CAST(cod_cliente_alicorp_actual AS STRING), r'\.0$', '') AS sap_out,
    COALESCE(CAST(cod_familia   AS STRING), '<NULL>') AS fam,
    COALESCE(CAST(cod_categoria AS STRING), '<NULL>') AS cat,
    cod_grupo_precio_dex,
    SUM(mnt_venta_real_bruto) AS vb
  FROM `acpe-prod-dlk-shrd-gld.delivery_reporte_comercial.cr_venta_sell_out`
  WHERE periodo >= p_ini AND periodo < p_corte
    AND SAFE_CAST(cod_cliente_dex AS INT64) IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6
),
ultimo AS (
  SELECT
    dex,
    ARRAY_AGG(cod_grupo_precio_dex ORDER BY periodo DESC, cod_grupo_precio_dex LIMIT 1)[OFFSET(0)] AS g_ult,
    ARRAY_AGG(sap_out IGNORE NULLS ORDER BY periodo DESC, vb DESC, sap_out LIMIT 1)[SAFE_OFFSET(0)] AS sap_ult
  FROM out_raw
  GROUP BY dex
),
activos AS (
  SELECT DISTINCT SAFE_CAST(a.id_interlocutor_origen AS INT64) AS dex
  FROM `acpe-prod-dlk-shrd-gld.gld_cliente.dex_cliente` a
  LEFT JOIN `acpe-prod-dlk-shrd-gld.gld_cliente.odoo_mk_dex_cliente` b
    ON a.id_interlocutor_origen = b.id_interlocutor_origen
  WHERE a.est_cliente = 'A' AND b.flg_activo = TRUE
),
golosinero AS (
  SELECT DISTINCT SAFE_CAST(id_interlocutor_origen AS INT64) AS dex
  FROM `acpe-dev-uc-sandbox-aa.dev_segmentacion.seg_estrategica`
  WHERE fecha_corte = p_corte AND des_segmento_estrategico = 'Golosinera'
),
mapa_sap AS (
  SELECT
    SAFE_CAST(a.cod_cliente_dex AS INT64) AS dex,
    MIN(REGEXP_REPLACE(CAST(b.cod_cliente_actual AS STRING), r'\.0$', '')) AS sap_dim
  FROM `acpe-prod-dlk-shrd-gld.delivery_modelo_dimensional.cr_cliente_dex_historico` a
  LEFT JOIN `acpe-prod-dlk-shrd-gld.delivery_modelo_dimensional.cr_cliente_alicorp` b
    ON a.cod_sucursal = b.cod_sucursal
  WHERE a.periodo = p_corte
  GROUP BY 1
),
ratios AS (
  SELECT
    REGEXP_REPLACE(CAST(cod_cliente AS STRING), r'\.0$', '') AS sap,
    COALESCE(CAST(cod_familia   AS STRING), '<NULL>') AS fam,
    COALESCE(CAST(cod_categoria AS STRING), '<NULL>') AS cat
  FROM `acpe-prod-dlk-shrd-gld.delivery_contabilidad_gestion.cr_contabilidad_gestion_kpi`
  WHERE periodo >= p_ini AND periodo < p_corte
    AND des_cluster_canal = 'DEX' AND cod_moneda = 'PEN' AND cod_grupo_precio = 'D1'
  GROUP BY 1, 2, 3
  HAVING SUM(mnt_venta_bruta) > 0
     AND SUM(mnt_utilidad_bruta) < SUM(mnt_venta_bruta)
     AND SUM(mnt_utilidad_bruta) <> 0
     AND SUM(num_volumen) > 0
),
cl AS (
  SELECT
    u.dex,
    IF(gl.dex IS NOT NULL, 'GO', u.g_ult) AS g_final,
    a.dex IS NOT NULL AS es_activo,
    COALESCE(u.sap_ult, m.sap_dim) AS sap
  FROM ultimo u
  LEFT JOIN activos a     ON a.dex  = u.dex
  LEFT JOIN golosinero gl ON gl.dex = u.dex
  LEFT JOIN mapa_sap m    ON m.dex  = u.dex
),
con_ratio AS (
  SELECT DISTINCT o.dex
  FROM out_raw o
  JOIN cl ON cl.dex = o.dex
  JOIN ratios r ON r.sap = cl.sap AND r.fam = o.fam AND r.cat = o.cat
)
SELECT
  cl.g_final AS cod_grupo,
  cl.g_final IN ('BO','MM','AB','Sin Asignar','Sin asignar','PM','GA','PA','LV','GO') AS grupo_valido,
  COUNT(*)                                                                         AS n_clientes,
  COUNTIF(cl.es_activo)                                                            AS n_activos,
  COUNTIF(cl.es_activo AND cl.sap IS NOT NULL)                                     AS n_con_sap,
  COUNTIF(cl.es_activo AND cl.sap IS NOT NULL AND cr.dex IS NOT NULL)              AS n_con_ratio
FROM cl
LEFT JOIN con_ratio cr ON cr.dex = cl.dex
GROUP BY 1, 2
ORDER BY n_clientes DESC;

-- 2) Perdida por codigo de cliente no numerico (antes del embudo)
SELECT
  COUNT(DISTINCT cod_cliente_dex)                       AS n_dex_raw,
  COUNT(DISTINCT SAFE_CAST(cod_cliente_dex AS INT64))   AS n_dex_numerico
FROM `acpe-prod-dlk-shrd-gld.delivery_reporte_comercial.cr_venta_sell_out`
WHERE periodo >= DATE '2025-01-01' AND periodo < DATE '2026-01-01';

-- 3) Clientes que aparecen en mas de un grupo durante la ventana (doble conteo en tu primera query)
SELECT COUNT(*) AS n_clientes_multi_grupo
FROM (
  SELECT cod_cliente_dex
  FROM `acpe-prod-dlk-shrd-gld.delivery_reporte_comercial.cr_venta_sell_out`
  WHERE periodo >= DATE '2025-01-01' AND periodo < DATE '2026-01-01'
    AND cod_grupo_precio_dex IN ('BO','GA','MM','PA','AB','LV','PM')
  GROUP BY cod_cliente_dex
  HAVING COUNT(DISTINCT cod_grupo_precio_dex) > 1
);
