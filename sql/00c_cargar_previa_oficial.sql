-- 00c: carga la segmentacion OFICIAL (cr_segmentacion) del corte previo a seg_prev_oficial,
-- para que NEXT_MONTH / REASSIGN la usen como segmentacion previa.
--   'Por definir' -> 'Sin asignar' (nombre interno).  Los demas segmentos (incluido '0 Diamante') se conservan tal cual.
-- La oficial trae una fila por (cod_interlocutor, cod_boca_salida): se reduce a un cliente.
-- Si un cliente tiene varios segmentos entre bocas, se queda el asignado de menor codigo (0 Diamante < 1 Oro+ < ... < Sin asignar).
DECLARE p_prev  DATE DEFAULT @p_prev;
DECLARE p_corte DATE DEFAULT @p_corte;   -- el mapa de nodos es el del corte actual
-- Cliente unico: los codigos de un mismo nodo se reducen al actual y se queda el segmento de menor codigo (el mejor).

DELETE FROM `{{ ds }}.seg_prev_oficial` WHERE fecha_corte = p_prev;

INSERT INTO `{{ ds }}.seg_prev_oficial`
  (fecha_corte, cod_cliente_dex, sum_ub_ajustada, sin_asignar, des_segmentacion_transaccional, origen)
SELECT
  p_prev,
  dex,
  ub_movil,
  IF(seg = 'Sin asignar', 'Sin asignar', 'Asignar'),
  seg,
  'Oficial'
FROM (
  SELECT
    COALESCE(mn.cod_cliente_dex_actual,
             SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(o.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64)) AS dex,
    COALESCE(MIN(IF(o.des_segmento_transaccional = 'Por definir', 'Sin asignar', o.des_segmento_transaccional)),
             'Sin asignar') AS seg,
    MAX(CAST(o.mnt_utilidad_bruta_movil AS FLOAT64)) AS ub_movil
  FROM `{{ src_prev_oficial }}` o
  LEFT JOIN `{{ ds }}.seg_mapa_nodo` mn
    ON mn.fecha_corte = p_corte
   AND mn.cod_cliente_dex = SAFE_CAST(NULLIF(REGEXP_REPLACE(SPLIT(CAST(o.cod_interlocutor AS STRING), '.')[OFFSET(0)], r'\D', ''), '') AS INT64)
  WHERE o.periodo = p_prev
  GROUP BY 1
)
WHERE dex IS NOT NULL;

SELECT
  COUNT(*)                                                       AS n_filas,
  COUNTIF(des_segmentacion_transaccional = 'Sin asignar')        AS n_por_definir,
  COUNTIF(des_segmentacion_transaccional LIKE '0 %')             AS n_diamante,
  (SELECT COUNTIF(n > 1)
     FROM (SELECT COUNT(DISTINCT des_segmento_transaccional) AS n
             FROM `{{ src_prev_oficial }}`
            WHERE periodo = p_prev
            GROUP BY cod_interlocutor))                          AS n_dex_multi_seg
FROM `{{ ds }}.seg_prev_oficial`
WHERE fecha_corte = p_prev;
