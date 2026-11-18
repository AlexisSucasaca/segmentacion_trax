-- 03 (modos NEXT_MONTH y REASSIGN): umbrales congelados del ultimo FULL.
--   solo_sin_asignar = TRUE  -> NEXT_MONTH: reevalua solo los "Sin asignar" previos y agrega nuevos.
--                               Usa umbrales Oro+/Oro/Plata/Bronce. NO evalua Diamante; los Diamante previos se conservan.
--   solo_sin_asignar = FALSE -> REASSIGN:   reevalua TODOS los previos y agrega nuevos.
--                               Evalua Diamante con el umbral congelado (UB >= min_diamante, grupos {{ grupos_diamante }}),
--                               con prioridad sobre la segmentacion regular (tambien para "Sin asignar").
-- La UB y el estado "Sin asignar" salen de la ventana NUEVA.
-- CAMBIO DE BOCA (seg_cambios_boca, paso 01b): ademas de los "Sin asignar", se reevaluan con los umbrales de su boca NUEVA
--   los previos con tipo_cambio = CAMBIO_UNIVERSO, y los CAMBIO_INTERNO cuyo grupo vs2 cambia Y cuyos umbrales (por SAP) difieren.
--   NEXT_MONTH no evalua Diamante: un Diamante previo se conserva solo si su boca nueva sigue en grupos_diamante;
--   si salio de esos grupos se reevalua con los umbrales regulares. Los previos no reevaluados actualizan igual su boca.
-- Segmentacion previa: {{ prev_tabla }} (seg_segmentacion o la copia de la oficial, segun fuente_prev).
DECLARE p_corte DATE DEFAULT @p_corte;
DECLARE p_prev  DATE DEFAULT @p_prev;
DECLARE p_umb   DATE DEFAULT @p_umb;
DECLARE v_solo  BOOL DEFAULT @solo_sin_asignar;
-- sin_umbral_conservar = TRUE: un cliente cuya (boca, SAP) no tiene umbrales en el FULL NO se asigna por la funcion (que lo mandaria a Bronce):
--   conserva su segmento previo y, si no tenia (nuevo o 'Sin asignar'), queda 'Sin asignar'.
DECLARE v_cons  BOOL DEFAULT @sin_umbral_conservar;

DELETE FROM `{{ ds }}.seg_segmentacion` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_segmentacion`
  (fecha_corte, cod_grupo_precio_dex, des_grupo_precio_dex, cod_grupo_precio_dex_vs2,
   cod_cliente_dex, cod_cliente_alicorp_actual, sum_vb, sum_ub, sum_ub_ajustada,
   meses_distintos, sin_asignar, ub_ajustada_acum, ub_ajustada_dex, percentil,
   des_segmentacion_transaccional, origen,
   des_segmento_regular, grupo_diamante, percentil_diamante, cod_boca_ant, tipo_cambio_boca)
WITH
-- previa a cliente unico (nodo): una fila por cliente actual, con el mejor segmento (menor codigo; 'Sin asignar' al final)
prev AS (
  SELECT * EXCEPT (rn)
  FROM (
    SELECT
      p0.* REPLACE (COALESCE(mn.cod_cliente_dex_actual, p0.cod_cliente_dex) AS cod_cliente_dex),
      ROW_NUMBER() OVER (
        PARTITION BY COALESCE(mn.cod_cliente_dex_actual, p0.cod_cliente_dex)
        ORDER BY IF(p0.des_segmentacion_transaccional = 'Sin asignar', 'Z', p0.des_segmentacion_transaccional),
                 IF(mn.cod_cliente_dex IS NULL, 0, 1)) AS rn
    FROM `{{ prev_tabla }}` p0
    LEFT JOIN `{{ ds }}.seg_mapa_nodo` mn
      ON mn.fecha_corte = p_corte AND mn.cod_cliente_dex = p0.cod_cliente_dex
    WHERE p0.fecha_corte = p_prev
  )
  WHERE rn = 1
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
cambios AS (
  SELECT * FROM `{{ ds }}.seg_cambios_boca` WHERE fecha_corte = p_corte
),
base_scored AS (
  SELECT
    n.*,
    IF(n.sin_asignar = 'Sin asignar', 'Sin asignar',
       `{{ ds }}.fn_asignar_seg`(n.sum_ub_ajustada, u.min_oro_plus, u.min_oro, u.min_plata, u.min_bronce)
    ) AS seg_regular,
    d.min_diamante,
    (u.cod_cliente_alicorp_actual IS NULL AND n.sin_asignar <> 'Sin asignar') AS sin_umbral,
    c.cod_boca_ant,
    c.tipo_cambio,
    (UPPER(c.cod_vs2_act) IN ('BO','PM','GA','PA','LV','GO')   -- boca nueva segmentable (MA, FA, PI, OT no se reevaluan)
     AND (c.tipo_cambio = 'CAMBIO_UNIVERSO'
     OR (c.tipo_cambio = 'CAMBIO_INTERNO'
         AND c.cod_vs2_ant IS DISTINCT FROM c.cod_vs2_act
         AND NOT (    ua.min_oro_plus IS NOT DISTINCT FROM u.min_oro_plus
                  AND ua.min_oro     IS NOT DISTINCT FROM u.min_oro
                  AND ua.min_plata   IS NOT DISTINCT FROM u.min_plata
                  AND ua.min_bronce  IS NOT DISTINCT FROM u.min_bronce)))
    ) AS reeval_boca
  FROM nuevo n
  LEFT JOIN umb u
    ON  u.cod_grupo_precio_dex_vs2   = n.cod_grupo_precio_dex_vs2
    AND u.cod_cliente_alicorp_actual = n.cod_cliente_alicorp_actual
  LEFT JOIN umb_d d
    ON  d.cod_cliente_alicorp_actual = n.cod_cliente_alicorp_actual
    AND n.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }})
  LEFT JOIN cambios c
    ON  c.cod_cliente_dex = n.cod_cliente_dex
  LEFT JOIN umb ua       -- umbrales de la boca ANTERIOR (para saber si el cambio interno altera algo)
    ON  ua.cod_grupo_precio_dex_vs2   = c.cod_vs2_ant
    AND ua.cod_cliente_alicorp_actual = n.cod_cliente_alicorp_actual
),
scored AS (
  SELECT
    b.*,
    CASE
      WHEN (NOT v_solo) AND b.min_diamante IS NOT NULL AND b.sum_ub_ajustada >= b.min_diamante THEN '0 Diamante'
      WHEN v_solo AND p.des_segmentacion_transaccional = '0 Diamante'
           AND b.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }})                         THEN '0 Diamante'
      WHEN v_cons AND b.sin_umbral THEN
           IF(p.des_segmentacion_transaccional IS NOT NULL AND p.des_segmentacion_transaccional <> 'Sin asignar',
              p.des_segmentacion_transaccional, 'Sin asignar')
      ELSE b.seg_regular
    END AS seg_nuevo,
    (v_cons AND b.sin_umbral) AS sin_umbral_f,
    COALESCE(b.reeval_boca, FALSE) AS reeval_boca_f,
    p.des_segmentacion_transaccional AS seg_prev
  FROM base_scored b
  LEFT JOIN prev p ON p.cod_cliente_dex = b.cod_cliente_dex
)
-- A) previos que se conservan (o que ya no tienen datos en la ventana). Si hay datos nuevos, se actualiza la boca.
SELECT
  p_corte,
  COALESCE(s.cod_grupo_precio_dex, p.cod_grupo_precio_dex),
  COALESCE(s.des_grupo_precio_dex, p.des_grupo_precio_dex),
  COALESCE(s.cod_grupo_precio_dex_vs2, p.cod_grupo_precio_dex_vs2),
  p.cod_cliente_dex, p.cod_cliente_alicorp_actual, p.sum_vb, p.sum_ub, p.sum_ub_ajustada,
  p.meses_distintos, p.sin_asignar, p.ub_ajustada_acum, p.ub_ajustada_dex, p.percentil,
  p.des_segmentacion_transaccional,
  IF(s.cod_cliente_dex IS NULL, 'Sin datos en ventana', 'Previo'),
  p.des_segmento_regular, p.grupo_diamante, p.percentil_diamante,
  s.cod_boca_ant, s.tipo_cambio
FROM prev p
LEFT JOIN scored s ON s.cod_cliente_dex = p.cod_cliente_dex
WHERE (s.cod_cliente_dex IS NULL
       -- fuera de alcance: su boca actual (historico) no es segmentable (MA, FA, PI, OT) -> no se arrastra la segmentacion previa
       AND NOT EXISTS (SELECT 1 FROM cambios c
                       WHERE c.cod_cliente_dex = p.cod_cliente_dex
                         AND c.cod_boca_act IS NOT NULL
                         AND UPPER(c.cod_vs2_act) NOT IN ('BO','PM','GA','PA','LV','GO')))
   OR (v_solo AND p.des_segmentacion_transaccional <> 'Sin asignar' AND NOT s.reeval_boca_f)

UNION ALL

-- B) previos reevaluados con datos nuevos
SELECT
  p_corte, s.cod_grupo_precio_dex, s.des_grupo_precio_dex, s.cod_grupo_precio_dex_vs2,
  s.cod_cliente_dex, s.cod_cliente_alicorp_actual, s.sum_vb, s.sum_ub, s.sum_ub_ajustada,
  s.meses_distintos, s.sin_asignar,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  s.seg_nuevo,
  IF(v_solo AND s.reeval_boca_f AND p.des_segmentacion_transaccional <> 'Sin asignar', 'Reevaluado cambio boca', 'Reevaluado'),
  IF(s.sin_umbral_f, s.seg_nuevo, s.seg_regular),
  IF(s.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }}), 'DIAMANTE', NULL),
  CAST(NULL AS FLOAT64),
  s.cod_boca_ant, s.tipo_cambio
FROM prev p
JOIN scored s ON s.cod_cliente_dex = p.cod_cliente_dex
WHERE (NOT v_solo) OR p.des_segmentacion_transaccional = 'Sin asignar' OR s.reeval_boca_f

UNION ALL

-- C) clientes nuevos (no estaban en la segmentacion previa)
SELECT
  p_corte, s.cod_grupo_precio_dex, s.des_grupo_precio_dex, s.cod_grupo_precio_dex_vs2,
  s.cod_cliente_dex, s.cod_cliente_alicorp_actual, s.sum_vb, s.sum_ub, s.sum_ub_ajustada,
  s.meses_distintos, s.sin_asignar,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  s.seg_nuevo,
  'Nuevo',
  IF(s.sin_umbral_f, s.seg_nuevo, s.seg_regular),
  IF(s.cod_grupo_precio_dex_vs2 IN ({{ grupos_diamante }}), 'DIAMANTE', NULL),
  CAST(NULL AS FLOAT64),
  s.cod_boca_ant, s.tipo_cambio
FROM scored s
WHERE NOT EXISTS (SELECT 1 FROM prev p WHERE p.cod_cliente_dex = s.cod_cliente_dex);

SELECT
  COUNT(*) AS n_filas,
  -- previa a cliente unico (los codigos de un mismo nodo cuentan una vez), para que la compuerta sea comparable
  (SELECT COUNT(DISTINCT COALESCE(mn.cod_cliente_dex_actual, p.cod_cliente_dex))
     FROM `{{ prev_tabla }}` p
     LEFT JOIN `{{ ds }}.seg_mapa_nodo` mn
       ON mn.fecha_corte = p_corte AND mn.cod_cliente_dex = p.cod_cliente_dex
    WHERE p.fecha_corte = p_prev) AS n_filas_prev,
  COUNTIF(des_segmentacion_transaccional IS NULL)          AS n_sin_segmento,
  COUNTIF(origen = 'Previo')               AS n_previo,
  COUNTIF(origen = 'Reevaluado')           AS n_reevaluado,
  -- previos (cliente unico) que salen de la segmentacion por tener boca no segmentable (MA, FA, PI, OT)
  (SELECT COUNT(DISTINCT k.dex)
     FROM (SELECT COALESCE(mn.cod_cliente_dex_actual, p.cod_cliente_dex) AS dex
             FROM `{{ prev_tabla }}` p
             LEFT JOIN `{{ ds }}.seg_mapa_nodo` mn
               ON mn.fecha_corte = p_corte AND mn.cod_cliente_dex = p.cod_cliente_dex
            WHERE p.fecha_corte = p_prev) k
    WHERE EXISTS (SELECT 1 FROM `{{ ds }}.seg_cambios_boca` c
                  WHERE c.fecha_corte = p_corte AND c.cod_cliente_dex = k.dex AND c.cod_boca_act IS NOT NULL
                    AND UPPER(c.cod_vs2_act) NOT IN ('BO','PM','GA','PA','LV','GO'))
      AND NOT EXISTS (SELECT 1 FROM `{{ ds }}.seg_resumen_cliente` r
                      WHERE r.fecha_corte = p_corte AND r.cod_cliente_dex = k.dex)) AS n_fuera_alcance,
  COUNTIF(origen = 'Reevaluado cambio boca') AS n_reevaluado_cambio_boca,
  COUNTIF(tipo_cambio_boca = 'CAMBIO_UNIVERSO') AS n_cambio_universo,
  COUNTIF(tipo_cambio_boca = 'CAMBIO_INTERNO')  AS n_cambio_interno,
  -- reevaluados sin fila de umbrales para su (boca, SAP): fn_asignar_seg los manda a Bronce; revisar si es > 0
  (SELECT COUNT(*) FROM `{{ ds }}.seg_segmentacion` g
     LEFT JOIN `{{ ds }}.seg_umbrales` u
       ON u.fecha_corte = p_umb AND u.cod_grupo_precio_dex_vs2 = g.cod_grupo_precio_dex_vs2
      AND u.cod_cliente_alicorp_actual = g.cod_cliente_alicorp_actual
    WHERE g.fecha_corte = p_corte AND g.origen LIKE 'Reevaluado%'
      AND g.des_segmento_regular IS NOT NULL AND g.des_segmento_regular <> 'Sin asignar'
      AND u.cod_cliente_alicorp_actual IS NULL)           AS n_reeval_sin_umbral,
  COUNTIF(origen = 'Nuevo')                AS n_nuevo,
  COUNTIF(origen = 'Sin datos en ventana') AS n_sin_datos_ventana,
  COUNTIF(des_segmentacion_transaccional = '0 Diamante') AS n_diamante,
  COUNTIF(des_segmentacion_transaccional = 'Sin asignar') AS n_sin_asignar_seg
FROM `{{ ds }}.seg_segmentacion`
WHERE fecha_corte = p_corte;
