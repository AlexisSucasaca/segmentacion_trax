-- 05: tabla alterna en el formato (periodo, cod_interlocutor, cod_boca_salida,
--     des_segmento_transaccional, des_segmento_estrategica).
-- Filas = clientes de la tabla estrategica ({{ src_estrategica_fuente }}) con fec_corrida = p_corte;
--   cod_boca_salida y segmento estrategico se toman tal cual de esa tabla.
-- La fuente estrategica NO trae segmento transaccional: el valor "base" (respaldo y lista de Diamante)
--   sale de la segmentacion oficial ({{ src_prev_oficial }}) del MISMO periodo, por cliente.
-- Solo cambia des_segmento_transaccional, que viene de seg_segmentacion ('Sin asignar' -> 'Por definir').
-- Filas sin segmentacion interna conservan el valor base.
-- respetar_diamante_base = TRUE: la lista de '0 Diamante' de la oficial del periodo es la autoridad:
--   * cliente Diamante en la oficial                   -> se mantiene '0 Diamante', gane lo que gane nuestra segmentacion
--   * Diamante en nuestra segmentacion pero NO en la oficial -> valor base
-- completar_con_oficial = TRUE: clientes de la oficial del periodo que NO estan en la tabla estrategica se agregan,
--   tomando de la oficial su boca de salida y su segmento estrategico.
DECLARE p_corte DATE DEFAULT @p_corte;
DECLARE v_resp  BOOL DEFAULT @respetar_diamante_base;
DECLARE v_comp  BOOL DEFAULT @completar_con_oficial;
DECLARE v_grupo BOOL DEFAULT @derivar_boca_por_grupo;
DECLARE v_bhist BOOL DEFAULT @boca_desde_historico;
DECLARE p_hist  DATE DEFAULT DATE_SUB(p_corte, INTERVAL 1 MONTH);   -- ultimo mes de la ventana (igual que el paso 01)
-- boca_desde_historico = TRUE: cod_boca_salida de las filas que vienen de la estrategica o de la oficial se REEMPLAZA por la boca
--   de cr_cliente_dex_historico en p_hist (grupo vs2; GO/MM/AB/Sin asignar -> BO) cuando el cliente esta en el historico.
--   Si no esta, se conserva la de la fuente. Las filas derivadas (clientes nuevos) ya salen del grupo del paso 01.
-- derivar_boca_por_grupo = TRUE: clientes segmentados que no estan ni en la tabla estrategica ni en la oficial (clientes nuevos)
--   se agregan con cod_boca_salida derivado de su grupo de precio (vs2; GO -> BO) y segmento estrategico vacio.
--   Regla validada contra la tabla estrategica: coincide en ~99.8% de los clientes que tienen ambos datos.

-- Segmento transaccional oficial por cliente (si hay varias bocas, el de menor codigo: 0 Diamante < ... < Por definir)
CREATE TEMP TABLE oficial_tx AS (
  SELECT dex, MIN(des_segmento_transaccional) AS tx
  FROM (
    SELECT
      SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64) AS dex,
      des_segmento_transaccional
    FROM `{{ src_prev_oficial }}`
    WHERE periodo = p_corte
  )
  WHERE dex IS NOT NULL
  GROUP BY dex
);

CREATE TEMP TABLE boca_hist AS (
  SELECT
    SAFE_CAST(cod_cliente_dex AS INT64) AS dex,
    `{{ ds }}.fn_vs2`(ARRAY_AGG(cod_grupo_precio_dex IGNORE NULLS ORDER BY periodo DESC, cod_grupo_precio_dex LIMIT 1)[SAFE_OFFSET(0)]) AS boca
  FROM `{{ src_cliente_dex_hist }}`
  WHERE v_bhist AND DATE_TRUNC(periodo, MONTH) = p_hist
  GROUP BY 1
);

CREATE TEMP TABLE base AS (
  WITH
  ft0 AS (
    SELECT
      p_corte AS periodo,
      CAST(x.id_interlocutor_origen AS STRING) AS cod_interlocutor,
      x.cod_boca_salida,
      x.des_segmento_estrategico AS des_segmento_estrategica,
      SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(x.id_interlocutor_origen AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64) AS dex
    FROM `{{ src_estrategica_fuente }}` x
    WHERE SAFE_CAST(x.fec_corrida AS DATE) = p_corte
  ),
  ft AS (
    SELECT
      a.periodo, a.cod_interlocutor, a.cod_boca_salida,
      o.tx AS des_segmento_transaccional,
      a.des_segmento_estrategica, a.dex,
      'estrategica' AS origen_base
    FROM ft0 a
    LEFT JOIN oficial_tx o ON o.dex = a.dex
  ),
  fo AS (
    SELECT
      y.periodo, y.cod_interlocutor, y.cod_boca_salida,
      y.des_segmento_transaccional, y.des_segmento_estrategica,
      SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(y.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64) AS dex,
      'oficial' AS origen_base
    FROM `{{ src_prev_oficial }}` y
    WHERE v_comp AND y.periodo = p_corte
  ),
  fg AS (
    SELECT
      p_corte AS periodo,
      LPAD(CAST(s.cod_cliente_dex AS STRING), 10, '0') AS cod_interlocutor,
      IF(s.cod_grupo_precio_dex_vs2 = 'GO', 'BO', s.cod_grupo_precio_dex_vs2) AS cod_boca_salida,
      CAST(NULL AS STRING) AS des_segmento_transaccional,
      CAST(NULL AS STRING) AS des_segmento_estrategica,
      s.cod_cliente_dex AS dex,
      'derivada' AS origen_base
    FROM `{{ ds }}.seg_segmentacion` s
    WHERE v_grupo AND s.fecha_corte = p_corte AND s.cod_grupo_precio_dex_vs2 IS NOT NULL
  )
  , todo AS (
    SELECT * FROM ft
    UNION ALL
    SELECT * FROM fo WHERE NOT EXISTS (SELECT 1 FROM ft WHERE ft.dex = fo.dex)
    UNION ALL
    SELECT * FROM fg
    WHERE NOT EXISTS (SELECT 1 FROM ft WHERE ft.dex = fg.dex)
      AND NOT EXISTS (SELECT 1 FROM fo WHERE fo.dex = fg.dex)
  )
  -- DISTINCT: la estrategica puede traer varias bocas por cliente; al unificar con el historico quedarian filas repetidas
  SELECT DISTINCT
    t.periodo, t.cod_interlocutor,
    COALESCE(IF(t.origen_base = 'derivada', NULL, h.boca), t.cod_boca_salida) AS cod_boca_salida,
    t.des_segmento_transaccional, t.des_segmento_estrategica, t.dex, t.origen_base,
    t.cod_boca_salida AS cod_boca_fuente
  FROM todo t
  LEFT JOIN boca_hist h ON h.dex = t.dex
);

CREATE TEMP TABLE seg AS (
  SELECT
    cod_cliente_dex,
    IF(des_segmentacion_transaccional = 'Sin asignar', 'Por definir', des_segmentacion_transaccional) AS seg_tx
  FROM `{{ ds }}.seg_segmentacion`
  WHERE fecha_corte = p_corte
);

DELETE FROM `{{ out_tabla_alterna }}` WHERE periodo = p_corte;

INSERT INTO `{{ out_tabla_alterna }}`
  (periodo, cod_interlocutor, cod_boca_salida, des_segmento_transaccional, des_segmento_estrategica)
SELECT
  b.periodo,
  b.cod_interlocutor,
  b.cod_boca_salida,
  CASE
    WHEN v_resp AND b.des_segmento_transaccional = '0 Diamante' THEN '0 Diamante'
    WHEN v_resp AND s.seg_tx = '0 Diamante'                     THEN b.des_segmento_transaccional
    ELSE COALESCE(s.seg_tx, b.des_segmento_transaccional)
  END,
  b.des_segmento_estrategica
FROM base b
LEFT JOIN seg s ON s.cod_cliente_dex = b.dex;

SELECT
  COUNT(*)                                                    AS n_filas,
  COUNTIF(s.cod_cliente_dex IS NULL)                          AS n_sin_segmentacion_interna,
  COUNTIF(s.seg_tx IS NOT NULL
          AND s.seg_tx <> IFNULL(b.des_segmento_transaccional, ''))   AS n_difiere_de_base,
  COUNTIF(s.seg_tx = 'Por definir')                           AS n_por_definir,
  COUNTIF(b.des_segmento_transaccional = '0 Diamante')        AS n_diamante_base,
  COUNTIF(b.origen_base = 'estrategica' AND b.des_segmento_transaccional = '0 Diamante') AS n_diamante_base_estrategica,
  COUNTIF(b.origen_base = 'oficial')                          AS n_filas_de_oficial,
  COUNTIF(b.origen_base = 'derivada')                         AS n_filas_derivadas,
  COUNTIF(b.origen_base <> 'derivada' AND b.cod_boca_salida IS DISTINCT FROM b.cod_boca_fuente) AS n_boca_actualizada,
  (SELECT COUNTIF(des_segmento_transaccional = '0 Diamante')
     FROM `{{ out_tabla_alterna }}` WHERE periodo = p_corte)  AS n_diamante_final,
  (SELECT COUNTIF(des_segmento_transaccional IS NULL)
     FROM `{{ out_tabla_alterna }}` WHERE periodo = p_corte)  AS n_sin_segmento_final,
  COUNTIF(b.des_segmento_transaccional = '0 Diamante'
          AND s.seg_tx IS NOT NULL AND s.seg_tx <> '0 Diamante')      AS n_diamante_base_pisa_nuestro,
  COUNTIF(s.seg_tx = '0 Diamante'
          AND IFNULL(b.des_segmento_transaccional, '') <> '0 Diamante') AS n_diamante_nuestro_fuera_de_lista,
  (SELECT COUNT(*) FROM seg x
    WHERE NOT EXISTS (SELECT 1 FROM base y WHERE y.dex = x.cod_cliente_dex)) AS n_seg_fuera_de_base
FROM base b
LEFT JOIN seg s ON s.cod_cliente_dex = b.dex;
