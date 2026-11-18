-- 01: base cliente-mes (output sell-out x ratios). Comun a FULL / NEXT_MONTH / REASSIGN.
-- Parametros: p_corte. Ventana = [p_corte - 12 meses, p_corte).
-- Cruces por cod_familia / cod_categoria (no por descripcion).
-- SAP del cliente = el de su ULTIMA VENTA dentro de la ventana (sell-out).
-- Grupo de precio (boca) = el de cr_cliente_dex_historico en el ultimo mes de la ventana (boca_desde_historico = TRUE);
--   respaldo: el de su ultima venta. Con boca_desde_historico = FALSE se vuelve a la regla anterior (ultima venta).
-- Si el cliente no tiene SAP en ninguna venta, se usa el de la dimension al periodo p_corte (cod_sucursal).
DECLARE p_corte DATE DEFAULT @p_corte;
DECLARE p_ini   DATE DEFAULT DATE_SUB(p_corte, INTERVAL 12 MONTH);
DECLARE p_hist  DATE DEFAULT DATE_SUB(p_corte, INTERVAL 1 MONTH);   -- ultimo mes de la ventana
DECLARE v_hist  BOOL DEFAULT @boca_desde_historico;

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
    COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(a.cod_cliente_dex AS INT64)) AS cod_cliente_dex,
    MIN(REGEXP_REPLACE(CAST(b.cod_cliente_actual AS STRING), r'\.0$', '')) AS sap_dim,
    COUNT(DISTINCT b.cod_cliente_actual) AS n_sap
  FROM `{{ src_cliente_dex_hist }}` a
  LEFT JOIN `{{ src_cliente_alicorp }}` b
    ON a.cod_sucursal = b.cod_sucursal
  LEFT JOIN `{{ ds }}.seg_mapa_nodo` mn
    ON mn.fecha_corte = p_corte AND mn.cod_cliente_dex = SAFE_CAST(a.cod_cliente_dex AS INT64)
  WHERE a.periodo = p_corte
  GROUP BY 1
);

-- Mapa de nodos: cada codigo se resuelve a su cliente unico (cod_cliente_dex_actual). Sin fila = el mismo codigo.
CREATE TEMP TABLE mapa_nodo AS (
  SELECT cod_cliente_dex, cod_cliente_dex_actual
  FROM `{{ ds }}.seg_mapa_nodo` WHERE fecha_corte = p_corte
);

CREATE TEMP TABLE out_raw AS (
  SELECT
    periodo,
    COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(s.cod_cliente_dex AS INT64)) AS cod_cliente_dex,
    REGEXP_REPLACE(CAST(cod_cliente_alicorp_actual AS STRING), r'\.0$', '') AS sap_out,
    COALESCE(CAST(cod_familia   AS STRING), '<NULL>') AS fam,
    COALESCE(CAST(cod_categoria AS STRING), '<NULL>') AS cat,
    cod_grupo_precio_dex,
    des_grupo_precio_dex,
    SUM(mnt_venta_real_bruto) AS vb
  FROM `{{ src_sellout }}` s
  LEFT JOIN mapa_nodo mn ON mn.cod_cliente_dex = SAFE_CAST(s.cod_cliente_dex AS INT64)
  WHERE periodo >= p_ini AND periodo < p_corte
  GROUP BY 1, 2, 3, 4, 5, 6, 7
);

-- Descripcion por codigo de grupo (la mas reciente del sell-out), para cuando la boca viene del historico
CREATE TEMP TABLE des_por_cod AS (
  SELECT cod_grupo_precio_dex AS cod,
         ARRAY_AGG(des_grupo_precio_dex IGNORE NULLS ORDER BY periodo DESC LIMIT 1)[SAFE_OFFSET(0)] AS des
  FROM out_raw
  GROUP BY 1
);

-- Boca por cliente:
--   v_hist = TRUE : la del historico en el ULTIMO mes de la ventana (p_hist = p_corte - 1 mes);
--                   si el cliente no esta en el historico ese mes, la de su ultima venta.
--                   Si su boca en el historico no es segmentable (MA, FA, PI, OT) el filtro final lo deja FUERA de la segmentacion.
--   v_hist = FALSE: la de su ultima venta (regla anterior).
CREATE TEMP TABLE grupo_src AS (
  WITH
  ultimo AS (
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
  hist AS (
    -- cliente unico: entre los codigos del nodo, primero el actual (si no esta, el de periodo mas reciente)
    SELECT
      COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(h0.cod_cliente_dex AS INT64)) AS cod_cliente_dex,
      ARRAY_AGG(h0.cod_grupo_precio_dex IGNORE NULLS
                ORDER BY IF(mn.cod_cliente_dex IS NULL, 0, 1), h0.periodo DESC, h0.cod_grupo_precio_dex LIMIT 1)[SAFE_OFFSET(0)] AS cod
    FROM `{{ src_cliente_dex_hist }}` h0
    LEFT JOIN mapa_nodo mn ON mn.cod_cliente_dex = SAFE_CAST(h0.cod_cliente_dex AS INT64)
    WHERE DATE_TRUNC(h0.periodo, MONTH) = p_hist
    GROUP BY 1
  )
  SELECT
    u.cod_cliente_dex,
    u.sap_ult,
    u.g.cod AS cod_ult,
    h.cod   AS cod_hist,
    IF(v_hist, COALESCE(h.cod, u.g.cod), u.g.cod) AS cod_final,
    IF(IF(v_hist, COALESCE(h.cod, u.g.cod), u.g.cod) = u.g.cod, u.g.des,
       COALESCE(d.des, h.cod)) AS des_final
  FROM ultimo u
  LEFT JOIN hist h        ON h.cod_cliente_dex = u.cod_cliente_dex
  LEFT JOIN des_por_cod d ON d.cod = h.cod
);

CREATE TEMP TABLE out_clean AS (
  WITH
  activos AS (
    -- cliente unico activo si algun codigo de su nodo esta activo
    SELECT DISTINCT COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(a.id_interlocutor_origen AS INT64)) AS cod_cliente_dex
    FROM `{{ src_cliente }}` a
    LEFT JOIN `{{ src_odoo }}` b
      ON a.id_interlocutor_origen = b.id_interlocutor_origen
    LEFT JOIN mapa_nodo mn ON mn.cod_cliente_dex = SAFE_CAST(a.id_interlocutor_origen AS INT64)
    WHERE a.est_cliente = 'A' AND b.flg_activo = TRUE
  ),
  golosinero AS (
    SELECT DISTINCT COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(e.id_interlocutor_origen AS INT64)) AS cod_cliente_dex
    FROM `{{ src_estrategica }}` e
    LEFT JOIN mapa_nodo mn ON mn.cod_cliente_dex = SAFE_CAST(e.id_interlocutor_origen AS INT64)
    WHERE e.fecha_corte = p_corte
      AND e.des_segmento_estrategico = 'Golosinera'
  ),
  con_grupo AS (
    SELECT
      o.periodo,
      o.cod_cliente_dex,
      COALESCE(u.sap_ult, m.sap_dim) AS sap,
      o.fam,
      o.cat,
      IF(gl.cod_cliente_dex IS NOT NULL, 'GO', u.cod_final) AS cod_grupo,
      IF(gl.cod_cliente_dex IS NOT NULL, 'Golosinera',
         IF(u.des_final = 'Puesto De Mercado', 'Puesto de mercado', u.des_final)) AS des_grupo,
      o.vb
    FROM out_raw o
    JOIN grupo_src u         ON u.cod_cliente_dex  = o.cod_cliente_dex
    JOIN activos a           ON a.cod_cliente_dex  = o.cod_cliente_dex
    LEFT JOIN golosinero gl  ON gl.cod_cliente_dex = o.cod_cliente_dex
    LEFT JOIN mapa_sap m     ON m.cod_cliente_dex  = o.cod_cliente_dex
  )
  SELECT periodo, cod_cliente_dex, sap, fam, cat, cod_grupo, des_grupo, vb
  FROM con_grupo
  WHERE UPPER(cod_grupo) IN ('BO','MM','AB','SIN ASIGNAR','PM','GA','PA','LV','GO')
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
       SAFE_DIVIDE(vb_base, vb_out) AS pct_match_vb,
       n_dex_sin_hist, n_dex_boca_hist_dif_venta, n_dex_hist_no_segmentable
FROM (
  SELECT
    (SELECT COUNTIF(cod_hist IS NULL) FROM grupo_src) AS n_dex_sin_hist,
    -- clientes con boca del historico fuera de los grupos segmentables (MA, FA, PI, OT...): quedan fuera de la segmentacion
    (SELECT COUNTIF(cod_hist IS NOT NULL AND UPPER(cod_hist) NOT IN ('BO','MM','AB','SIN ASIGNAR','PM','GA','PA','LV','GO')) FROM grupo_src) AS n_dex_hist_no_segmentable,
    -- clientes cuya boca (vs2) del historico difiere de la de su ultima venta (mide el impacto del cambio de regla)
    (SELECT COUNTIF(cod_hist IS NOT NULL AND UPPER(cod_hist) IN ('BO','MM','AB','SIN ASIGNAR','PM','GA','PA','LV','GO') AND `{{ ds }}.fn_vs2`(cod_hist) IS DISTINCT FROM `{{ ds }}.fn_vs2`(cod_ult)) FROM grupo_src) AS n_dex_boca_hist_dif_venta,
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
