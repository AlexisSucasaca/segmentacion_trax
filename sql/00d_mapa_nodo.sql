-- 00d: mapa de clientes unificados desde gtm_cliente_nodo (cambio de razon social / de codigo).
-- Cada codigo del nodo se resuelve a cod_cliente_dex_actual (vigente); todo el pipeline usa ese codigo como cliente unico.
-- Se toma la fila mas reciente por cod_cliente_dex con periodo <= p_corte (hoy cada codigo aparece una sola vez).
-- Con unificar_nodos = FALSE la tabla del corte queda vacia y el pipeline se comporta como antes.
-- Solo se guardan los codigos que cambian de llave (cod <> actual); los demas se resuelven por COALESCE.
DECLARE p_corte DATE DEFAULT @p_corte;
DECLARE v_unif  BOOL DEFAULT @unificar_nodos;

DELETE FROM `{{ ds }}.seg_mapa_nodo` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_mapa_nodo`
  (fecha_corte, num_nodo, cod_cliente_dex, cod_cliente_dex_actual, tip_clasificacion)
SELECT p_corte, num_nodo, cod, actual, tip_clasificacion
FROM (
  SELECT
    num_nodo,
    SAFE_CAST(cod_cliente_dex AS INT64)        AS cod,
    SAFE_CAST(cod_cliente_dex_actual AS INT64) AS actual,
    tip_clasificacion,
    ROW_NUMBER() OVER (PARTITION BY cod_cliente_dex ORDER BY periodo DESC, fec_proceso DESC) AS rn
  FROM `{{ src_nodo }}`
  WHERE v_unif AND periodo IS NOT NULL AND periodo <= p_corte
)
WHERE rn = 1 AND cod IS NOT NULL AND actual IS NOT NULL AND cod <> actual;

SELECT
  COUNT(*)                          AS n_filas,
  COUNT(DISTINCT cod_cliente_dex_actual) AS n_nodos_con_reemplazo,
  -- un codigo reemplazado que a su vez es "actual" de otro: la cadena no esta resuelta
  (SELECT COUNT(*) FROM `{{ ds }}.seg_mapa_nodo` a
    JOIN `{{ ds }}.seg_mapa_nodo` b
      ON b.fecha_corte = a.fecha_corte AND b.cod_cliente_dex = a.cod_cliente_dex_actual
   WHERE a.fecha_corte = p_corte)   AS n_cadenas
FROM `{{ ds }}.seg_mapa_nodo`
WHERE fecha_corte = p_corte;
