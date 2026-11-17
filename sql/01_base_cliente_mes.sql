-- 01: base cliente-mes (output sell-out x ratios). Comun a FULL / NEXT_MONTH / REASSIGN.
-- Parametros: p_corte. Ventana = [p_corte - 12 meses, p_corte).
-- Cruces por cod_familia / cod_categoria (no por descripcion).
-- Grupo de precio y SAP del cliente = los de su ULTIMA VENTA dentro de la ventana (sell-out).
-- Si el cliente no tiene SAP en ninguna venta, se usa el de la dimension al periodo p_corte (cod_sucursal).
DECLARE p_corte DATE DEFAULT @p_corte;
DECLARE p_ini   DATE DEFAULT DATE_SUB(p_corte, INTERVAL 12 MONTH);

-- Ratios (reemplaza ratios_*.csv). Filtro unico = interseccion del SQL y del notebook.
CREATE TEMP TABLE ratios AS (
  SELECT
    REGEXP_REPLACE(CAST(cod_cliente AS STRING), r'\.0$', '') AS sap,
    COALESCE(CAST(cod_familia   AS STRING), '<NULL>') AS fam,
    COALESCE(CAST(cod_categoria AS STRING), '<NULL>') AS cat,
    SAFE_DIVIDE(SUM(mnt_utilidad_bruta), SUM(mnt_venta_bruta)) AS r_ub,
    SAFE_DIVIDE(SUM(mnt_utilidad_bruta) - SUM(mnt_comision_dex), SUM(mnt_venta_bruta)) AS r_ub_aj
  FROM `{{ src_kpi }}`
  WHERE periodo >= p_ini AND periodo < p_corte
    AND des_cluster_canal = 'DEX'
    AND cod_moneda = 'PEN'
    AND cod_grupo_precio = 'D1'
  GROUP BY 1, 2, 3
  HAVING SUM(mnt_venta_bruta) > 0
     AND SUM(mnt_utilidad_bruta) < SUM(mnt_venta_bruta)
     AND SUM(mnt_utilidad_bruta) <> 0
     AND SUM(num_volumen) > 0
);

-- Respaldo: SAP por cliente DEX segun la dimension al periodo del corte (cod_sucursal -> cod_cliente_actual)
CREATE TEMP TABLE mapa_sap AS (
  SELECT
    SAFE_CAST(a.cod_cliente_dex AS INT64) AS cod_cliente_dex,
    MIN(REGEXP_REPLACE(CAST(b.cod_cliente_actual AS STRING), r'\.0$', '')) AS sap_dim,
    COUNT(DISTINCT b.cod_cliente_actual) AS n_sap
  FROM `{{ src_cliente_dex_hist }}` a
  LEFT JOIN `{{ src_cliente_alicorp }}` b
    ON a.cod_sucursal = b.cod_sucursal
  WHERE a.periodo = p_corte
  GROUP BY 1
);

CREATE TEMP TABLE out_clean AS (
  WITH
  activos AS (
    SELECT DISTINCT SAFE_CAST(a.id_interlocutor_origen AS INT64) AS cod_cliente_dex
    FROM `{{ src_cliente }}` a
    LEFT JOIN `{{ src_odoo }}` b
      ON a.id_interlocutor_origen = b.id_interlocutor_origen
    WHERE a.est_cliente = 'A' AND b.flg_activo = TRUE
  ),
  golosinero AS (
    SELECT DISTINCT SAFE_CAST(id_interlocutor_origen AS INT64) AS cod_cliente_dex
    FROM `{{ src_estrategica }}`
    WHERE fecha_corte = p_corte
      AND des_segmento_estrategico = 'Golosinera'
  ),
  out_raw AS (
    SELECT
      periodo,
      SAFE_CAST(cod_cliente_dex AS INT64) AS cod_cliente_dex,
      REGEXP_REPLACE(CAST(cod_cliente_alicorp_actual AS STRING), r'\.0$', '') AS sap_out,
      COALESCE(CAST(cod_familia   AS STRING), '<NULL>') AS fam,
      COALESCE(CAST(cod_categoria AS STRING), '<NULL>') AS cat,
      cod_grupo_precio_dex,
      des_grupo_precio_dex,
      SUM(mnt_venta_real_bruto) AS vb
    FROM `{{ src_sellout }}`
    WHERE periodo >= p_ini AND periodo < p_corte
    GROUP BY 1, 2, 3, 4, 5, 6, 7
  ),
  ultimo_grupo AS (
    SELECT
      cod_cliente_dex,
      ARRAY_AGG(STRUCT(cod_grupo_precio_dex AS cod, des_grupo_precio_dex AS des)
                ORDER BY periodo DESC, cod_grupo_precio_dex LIMIT 1)[OFFSET(0)] AS g,
      -- SAP de la venta mas reciente (si esa venta no trae SAP, el mas reciente que lo tenga)
      ARRAY_AGG(sap_out IGNORE NULLS ORDER BY periodo DESC, vb DESC, sap_out LIMIT 1)[SAFE_OFFSET(0)] AS sap_ult
    FROM out_raw
    WHERE cod_cliente_dex IS NOT NULL
    GROUP BY cod_cliente_dex
  ),
  con_grupo AS (
    SELECT
      o.periodo,
      o.cod_cliente_dex,
      COALESCE(u.sap_ult, m.sap_dim) AS sap,
      o.fam,
      o.cat,
      IF(gl.cod_cliente_dex IS NOT NULL, 'GO', u.g.cod) AS cod_grupo,
      IF(gl.cod_cliente_dex IS NOT NULL, 'Golosinera',
         IF(u.g.des = 'Puesto De Mercado', 'Puesto de mercado', u.g.des)) AS des_grupo,
      o.vb
    FROM out_raw o
    JOIN ultimo_grupo u      ON u.cod_cliente_dex  = o.cod_cliente_dex
    JOIN activos a           ON a.cod_cliente_dex  = o.cod_cliente_dex
    LEFT JOIN golosinero gl  ON gl.cod_cliente_dex = o.cod_cliente_dex
    LEFT JOIN mapa_sap m     ON m.cod_cliente_dex  = o.cod_cliente_dex
  )
  SELECT periodo, cod_cliente_dex, sap, fam, cat, cod_grupo, des_grupo, vb
  FROM con_grupo
  WHERE cod_grupo IN ('BO','MM','AB','Sin Asignar','Sin asignar','PM','GA','PA','LV','GO')
);

DELETE FROM `{{ ds }}.seg_base_cliente_mes` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_base_cliente_mes`
  (fecha_corte, periodo, cod_cliente_dex, cod_cliente_alicorp_actual,
   cod_grupo_precio_dex, des_grupo_precio_dex, vb, ub, ub_ajustada)
SELECT
  p_corte,
  c.periodo,
  c.cod_cliente_dex,
  c.sap,
  c.cod_grupo,
  c.des_grupo,
  SUM(c.vb),
  SUM(c.vb * r.r_ub),
  SUM(c.vb * r.r_ub_aj)
FROM out_clean c
JOIN ratios r
  ON  r.sap = c.sap
  AND r.fam = c.fam
  AND r.cat = c.cat
GROUP BY c.periodo, c.cod_cliente_dex, c.sap, c.cod_grupo, c.des_grupo;

-- Metricas para la compuerta de calidad
SELECT n_ratios, vb_out, vb_base, n_clientes, n_dex_multi_sap, n_dex_sap_dif_dim,
       SAFE_DIVIDE(vb_base, vb_out) AS pct_match_vb
FROM (
  SELECT
    (SELECT COUNT(*) FROM ratios) AS n_ratios,
    (SELECT SUM(vb) FROM out_clean) AS vb_out,
    (SELECT SUM(vb) FROM `{{ ds }}.seg_base_cliente_mes` WHERE fecha_corte = p_corte) AS vb_base,
    (SELECT COUNT(DISTINCT cod_cliente_dex) FROM `{{ ds }}.seg_base_cliente_mes` WHERE fecha_corte = p_corte) AS n_clientes,
    (SELECT COUNTIF(n_sap > 1) FROM mapa_sap) AS n_dex_multi_sap,
    -- clientes cuyo SAP de ultima venta difiere del de la dimension (mide cuanto importa la eleccion)
    (SELECT COUNT(DISTINCT c.cod_cliente_dex)
       FROM out_clean c
       JOIN mapa_sap m ON m.cod_cliente_dex = c.cod_cliente_dex
      WHERE m.sap_dim IS NOT NULL AND c.sap IS NOT NULL AND c.sap <> m.sap_dim) AS n_dex_sap_dif_dim
);
