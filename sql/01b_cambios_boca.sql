-- 01b (NEXT_MONTH y REASSIGN): cambios de boca de salida por cliente, desde cr_cliente_dex_historico.
-- Compara la boca del cliente en el ultimo mes de la ventana del corte previo (p_hist_ant)
-- contra la del ultimo mes de la ventana actual (p_hist_act = p_corte - 1 mes).
--   p_hist_ant = p_prev - 1 mes (si p_prev < p_corte); si p_prev = p_corte (previa oficial del mismo periodo) = p_corte - 2 meses.
-- Un cliente puede tener varias filas en un mes: se queda la ultima (periodo DESC, codigo) -> una boca por cliente-mes.
-- Universos (fn_universo): CMP = BO, MM, AB, Sin asignar, PM, GO | AS = grupos_diamante | OTRO = resto.
-- tipo_cambio:
--   SIN_CAMBIO       misma boca
--   CAMBIO_INTERNO   otra boca dentro del mismo universo
--   CAMBIO_UNIVERSO  cambia de universo (CMP <-> AS <-> OTRO)
--   NUEVO            no estaba en el historico en p_hist_ant (cliente nuevo o reactivado)
--   SIN_ACTUAL       estaba en p_hist_ant y ya no esta en p_hist_act
DECLARE p_corte    DATE DEFAULT @p_corte;
DECLARE p_prev     DATE DEFAULT @p_prev;
DECLARE p_hist_act DATE DEFAULT DATE_SUB(p_corte, INTERVAL 1 MONTH);
DECLARE p_hist_ant DATE DEFAULT IF(p_prev IS NOT NULL AND p_prev < p_corte,
                                   DATE_SUB(p_prev, INTERVAL 1 MONTH),
                                   DATE_SUB(p_corte, INTERVAL 2 MONTH));

DELETE FROM `{{ ds }}.seg_cambios_boca` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_cambios_boca`
  (fecha_corte, cod_cliente_dex, mes_hist_ant, mes_hist_act, cod_boca_ant, cod_boca_act,
   cod_vs2_ant, cod_vs2_act, univ_ant, univ_act, tipo_cambio)
WITH
-- cliente unico (nodo): entre los codigos del nodo, primero el actual; asi un cambio de codigo no se cuenta como NUEVO / SIN_ACTUAL
h AS (
  SELECT
    COALESCE(mn.cod_cliente_dex_actual, SAFE_CAST(h0.cod_cliente_dex AS INT64)) AS cod_cliente_dex,
    DATE_TRUNC(h0.periodo, MONTH) AS mes,
    ARRAY_AGG(h0.cod_grupo_precio_dex IGNORE NULLS
              ORDER BY IF(mn.cod_cliente_dex IS NULL, 0, 1), h0.periodo DESC, h0.cod_grupo_precio_dex LIMIT 1)[SAFE_OFFSET(0)] AS cod
  FROM `{{ src_cliente_dex_hist }}` h0
  LEFT JOIN `{{ ds }}.seg_mapa_nodo` mn
    ON mn.fecha_corte = p_corte AND mn.cod_cliente_dex = SAFE_CAST(h0.cod_cliente_dex AS INT64)
  WHERE DATE_TRUNC(h0.periodo, MONTH) IN (p_hist_ant, p_hist_act)
  GROUP BY 1, 2
),
ant AS (SELECT cod_cliente_dex, cod FROM h WHERE mes = p_hist_ant AND cod_cliente_dex IS NOT NULL),
act AS (SELECT cod_cliente_dex, cod FROM h WHERE mes = p_hist_act AND cod_cliente_dex IS NOT NULL),
j AS (
  SELECT
    COALESCE(a.cod_cliente_dex, b.cod_cliente_dex) AS cod_cliente_dex,
    a.cod AS cod_ant,
    b.cod AS cod_act
  FROM ant a
  FULL OUTER JOIN act b ON b.cod_cliente_dex = a.cod_cliente_dex
)
SELECT
  p_corte,
  cod_cliente_dex,
  p_hist_ant,
  p_hist_act,
  cod_ant,
  cod_act,
  `{{ ds }}.fn_vs2`(cod_ant),
  `{{ ds }}.fn_vs2`(cod_act),
  `{{ ds }}.fn_universo`(cod_ant),
  `{{ ds }}.fn_universo`(cod_act),
  CASE
    WHEN cod_ant IS NULL THEN 'NUEVO'
    WHEN cod_act IS NULL THEN 'SIN_ACTUAL'
    WHEN cod_ant = cod_act THEN 'SIN_CAMBIO'
    WHEN `{{ ds }}.fn_universo`(cod_ant) <> `{{ ds }}.fn_universo`(cod_act) THEN 'CAMBIO_UNIVERSO'
    ELSE 'CAMBIO_INTERNO'
  END
FROM j;

SELECT
  COUNT(*)                                  AS n_filas,
  COUNTIF(tipo_cambio = 'SIN_CAMBIO')       AS n_sin_cambio,
  COUNTIF(tipo_cambio = 'CAMBIO_INTERNO')   AS n_cambio_interno,
  COUNTIF(tipo_cambio = 'CAMBIO_UNIVERSO')  AS n_cambio_universo,
  COUNTIF(tipo_cambio = 'NUEVO')            AS n_nuevo,
  COUNTIF(tipo_cambio = 'SIN_ACTUAL')       AS n_sin_actual,
  ANY_VALUE(mes_hist_ant)                   AS mes_hist_ant,
  ANY_VALUE(mes_hist_act)                   AS mes_hist_act
FROM `{{ ds }}.seg_cambios_boca`
WHERE fecha_corte = p_corte;
