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
DECLARE p_prev  DATE DEFAULT @p_prev;
-- Periodo de la oficial usado como BASE (segmento de respaldo y lista de Diamante): el del corte si ya existe;
--   si todavia no existe (el corte es mas nuevo que la oficial), el del corte previo. En ese caso no se completa con la oficial
--   y los clientes sin segmento propio ni base quedan 'Por definir'.
DECLARE p_base  DATE DEFAULT IF(EXISTS (SELECT 1 FROM `{{ src_prev_oficial }}` WHERE periodo = p_corte), p_corte, COALESCE(p_prev, p_corte));
DECLARE p_hist  DATE DEFAULT DATE_SUB(p_corte, INTERVAL 1 MONTH);   -- ultimo mes de la ventana (igual que el paso 01)
-- boca_desde_historico = TRUE: cod_boca_salida de las filas que vienen de la estrategica o de la oficial se REEMPLAZA por la boca
--   de cr_cliente_dex_historico en p_hist (grupo vs2; GO/MM/AB/Sin asignar -> BO) cuando el cliente esta en el historico.
--   Si no esta, se conserva la de la fuente.
--   Los clientes cuya boca en el historico NO es segmentable (MA, FA, PI, OT) se EXCLUYEN de la tabla alterna: salieron de la segmentacion. Las filas derivadas (clientes nuevos) ya salen del grupo del paso 01.
-- derivar_boca_por_grupo = TRUE: clientes segmentados que no estan ni en la tabla estrategica ni en la oficial (clientes nuevos)
--   se agregan con cod_boca_salida derivado de su grupo de precio (vs2; GO -> BO) y segmento estrategico vacio.
--   Regla validada contra la tabla estrategica: coincide en ~99.8% de los clientes que tienen ambos datos.

-- Cliente unico (nodo): `dex` de todo este script = cod_cliente_dex_actual. cod_interlocutor conserva el codigo original,
--   asi cada codigo del nodo mantiene su fila en la alterna con el segmento del cliente unificado.
CREATE TEMP TABLE mapa_nodo AS (
  SELECT cod_cliente_dex, cod_cliente_dex_actual
  FROM `{{ ds }}.seg_mapa_nodo` WHERE fecha_corte = p_corte
);

-- Segmento transaccional oficial por cliente unico (si hay varias bocas, el de menor codigo: 0 Diamante < ... < Por definir)
CREATE TEMP TABLE oficial_tx AS (
  SELECT dex, MIN(des_segmento_transaccional) AS tx
  FROM (
    SELECT
      COALESCE(mn.cod_cliente_dex_actual,
               SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(o.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64)) AS dex,
      o.des_segmento_transaccional
    FROM `{{ src_prev_oficial }}` o
    LEFT JOIN mapa_nodo mn
      ON mn.cod_cliente_dex = SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(o.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64)
    WHERE o.periodo = p_base
  )
  WHERE dex IS NOT NULL
  GROUP BY dex
);

CREATE TEMP TABLE boca_hist AS (
  SELECT
    COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(h0.cod_cliente_dex AS INT64)) AS dex,
    `{{ ds }}.fn_vs2`(ARRAY_AGG(h0.cod_grupo_precio_dex IGNORE NULLS
                                ORDER BY IF(mn.cod_cliente_dex IS NULL, 0, 1), h0.periodo DESC, h0.cod_grupo_precio_dex LIMIT 1)[SAFE_OFFSET(0)]) AS boca
  FROM `{{ src_cliente_dex_hist }}` h0
  LEFT JOIN mapa_nodo mn ON mn.cod_cliente_dex = SAFE_CAST(h0.cod_cliente_dex AS INT64)
  WHERE v_bhist AND DATE_TRUNC(h0.periodo, MONTH) = p_hist
  GROUP BY 1
);

CREATE TEMP TABLE base_all AS (
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
      a.des_segmento_estrategica, COALESCE(mn.cod_cliente_dex_actual, a.dex) AS dex,
      'estrategica' AS origen_base,
      a.dex AS dex_raw   -- codigo original (sin unificar por nodo)
    FROM ft0 a
    LEFT JOIN mapa_nodo mn ON mn.cod_cliente_dex = a.dex
    LEFT JOIN oficial_tx o ON o.dex = COALESCE(mn.cod_cliente_dex_actual, a.dex)
  ),
  fo AS (
    SELECT
      y.periodo, y.cod_interlocutor, y.cod_boca_salida,
      y.des_segmento_transaccional, y.des_segmento_estrategica,
      COALESCE(mn.cod_cliente_dex_actual,
               SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(y.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64)) AS dex,
      'oficial' AS origen_base,
      SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(y.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64) AS dex_raw
    FROM `{{ src_prev_oficial }}` y
    LEFT JOIN mapa_nodo mn
      ON mn.cod_cliente_dex = SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(y.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64)
    WHERE v_comp AND y.periodo = p_corte
  ),
  fg AS (
    SELECT
      p_corte AS periodo,
      LPAD(CAST(s.cod_cliente_dex AS STRING), 10, '0') AS cod_interlocutor,
      -- boca: la del grupo del paso 01; los previos sin datos en la ventana (sin grupo) usan la del historico
      COALESCE(IF(s.cod_grupo_precio_dex_vs2 = 'GO', 'BO', s.cod_grupo_precio_dex_vs2), bh.boca) AS cod_boca_salida,
      -- segmento base: el de la oficial (si el cliente estaba en ella; p.ej. un Diamante previo que ya no esta en la estrategica)
      o.tx AS des_segmento_transaccional,
      CAST(NULL AS STRING) AS des_segmento_estrategica,
      s.cod_cliente_dex AS dex,
      'derivada' AS origen_base,
      s.cod_cliente_dex AS dex_raw
    FROM `{{ ds }}.seg_segmentacion` s
    LEFT JOIN boca_hist bh  ON bh.dex = s.cod_cliente_dex
    LEFT JOIN oficial_tx o  ON o.dex  = s.cod_cliente_dex
    WHERE v_grupo AND s.fecha_corte = p_corte
      AND COALESCE(s.cod_grupo_precio_dex_vs2, bh.boca) IS NOT NULL
  )
  , todo AS (
    SELECT * FROM ft
    UNION ALL
    SELECT * FROM fo WHERE NOT EXISTS (SELECT 1 FROM ft WHERE ft.dex = fo.dex)
    UNION ALL
    -- se compara por codigo ORIGINAL: si la estrategica solo trae el codigo viejo de un nodo, el codigo actual igual entra (derivado)
    SELECT * FROM fg
    WHERE NOT EXISTS (SELECT 1 FROM ft WHERE ft.dex_raw = fg.dex_raw)
      AND NOT EXISTS (SELECT 1 FROM fo WHERE fo.dex_raw = fg.dex_raw)
  )
  -- DISTINCT: la estrategica puede traer varias bocas por cliente; al unificar con el historico quedarian filas repetidas
  SELECT DISTINCT
    t.periodo, t.cod_interlocutor,
    COALESCE(IF(t.origen_base = 'derivada', NULL, h.boca), t.cod_boca_salida) AS cod_boca_salida,
    t.des_segmento_transaccional, t.des_segmento_estrategica, t.dex, t.origen_base,
    t.cod_boca_salida AS cod_boca_fuente,
    -- fuera de alcance: su boca actual (historico) no es segmentable (MA, FA, PI, OT) -> no entra a la tabla alterna
    COALESCE(UPPER(h.boca) NOT IN ('BO','PM','GA','PA','LV'), FALSE) AS fuera_alcance
  FROM todo t
  LEFT JOIN boca_hist h ON h.dex = t.dex
);

CREATE TEMP TABLE base AS (
  SELECT * EXCEPT (fuera_alcance) FROM base_all WHERE NOT fuera_alcance
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
    WHEN v_resp AND s.seg_tx = '0 Diamante'                     THEN COALESCE(b.des_segmento_transaccional, s.seg_tx)   -- sin valor base: se mantiene el Diamante (historia)
    ELSE COALESCE(s.seg_tx, b.des_segmento_transaccional, IF(p_base <> p_corte, 'Por definir', NULL))
  END,
  b.des_segmento_estrategica
FROM base b
LEFT JOIN seg s ON s.cod_cliente_dex = b.dex;

SELECT
  COUNT(*)                                                    AS n_filas,
  ANY_VALUE(p_base)                                           AS periodo_base_oficial,
  COUNTIF(s.cod_cliente_dex IS NULL)                          AS n_sin_segmentacion_interna,
  COUNTIF(s.seg_tx IS NOT NULL
          AND s.seg_tx <> IFNULL(b.des_segmento_transaccional, ''))   AS n_difiere_de_base,
  COUNTIF(s.seg_tx = 'Por definir')                           AS n_por_definir,
  COUNTIF(b.des_segmento_transaccional = '0 Diamante')        AS n_diamante_base,
  COUNTIF(b.origen_base = 'estrategica' AND b.des_segmento_transaccional = '0 Diamante') AS n_diamante_base_estrategica,
  COUNTIF(b.origen_base = 'oficial')                          AS n_filas_de_oficial,
  COUNTIF(b.origen_base = 'derivada')                         AS n_filas_derivadas,
  (SELECT COUNT(*) FROM base_all WHERE fuera_alcance)         AS n_excluidas_boca_no_segmentable,
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
