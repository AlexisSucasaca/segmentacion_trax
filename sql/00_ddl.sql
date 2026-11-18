-- 00: DDL idempotente (tablas de salida, log y funcion de asignacion)

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_base_cliente_mes` (
  fecha_corte                 DATE,
  periodo                     DATE,
  cod_cliente_dex             INT64,
  cod_cliente_alicorp_actual  STRING,
  cod_grupo_precio_dex        STRING,
  des_grupo_precio_dex        STRING,
  vb                          FLOAT64,
  ub                          FLOAT64,
  ub_ajustada                 FLOAT64
)
PARTITION BY fecha_corte
CLUSTER BY cod_cliente_dex;

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_resumen_cliente` (
  fecha_corte                 DATE,
  cod_grupo_precio_dex        STRING,
  des_grupo_precio_dex        STRING,
  cod_grupo_precio_dex_vs2    STRING,
  cod_cliente_dex             INT64,
  cod_cliente_alicorp_actual  STRING,
  sum_vb                      FLOAT64,
  sum_ub                      FLOAT64,
  sum_ub_ajustada             FLOAT64,
  meses_distintos             INT64,
  sin_asignar                 STRING
)
PARTITION BY fecha_corte
CLUSTER BY cod_cliente_dex;

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_segmentacion` (
  fecha_corte                     DATE,
  cod_grupo_precio_dex            STRING,
  des_grupo_precio_dex            STRING,
  cod_grupo_precio_dex_vs2        STRING,
  cod_cliente_dex                 INT64,
  cod_cliente_alicorp_actual      STRING,
  sum_vb                          FLOAT64,
  sum_ub                          FLOAT64,
  sum_ub_ajustada                 FLOAT64,
  meses_distintos                 INT64,
  sin_asignar                     STRING,
  ub_ajustada_acum                FLOAT64,
  ub_ajustada_dex                 FLOAT64,
  percentil                       FLOAT64,
  des_segmentacion_transaccional  STRING,
  origen                          STRING,
  des_segmento_regular            STRING,
  grupo_diamante                  STRING,
  percentil_diamante              FLOAT64
)
PARTITION BY fecha_corte
CLUSTER BY cod_cliente_dex;

-- Si la tabla ya existia (version anterior), agrega las columnas nuevas
ALTER TABLE `{{ ds }}.seg_segmentacion`
  ADD COLUMN IF NOT EXISTS des_segmento_regular STRING,
  ADD COLUMN IF NOT EXISTS grupo_diamante STRING,
  ADD COLUMN IF NOT EXISTS percentil_diamante FLOAT64,
  ADD COLUMN IF NOT EXISTS cod_boca_ant STRING,   -- boca (historico) del corte previo; NULL si no hay dato
  ADD COLUMN IF NOT EXISTS tipo_cambio_boca STRING; -- SIN_CAMBIO | CAMBIO_INTERNO | CAMBIO_UNIVERSO | NUEVO | SIN_ACTUAL

-- Cambios de boca de salida por cliente entre dos cortes (fuente: cr_cliente_dex_historico). Lo llena el paso 01b.
CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_cambios_boca` (
  fecha_corte      DATE,
  cod_cliente_dex  INT64,
  mes_hist_ant     DATE,
  mes_hist_act     DATE,
  cod_boca_ant     STRING,
  cod_boca_act     STRING,
  cod_vs2_ant      STRING,
  cod_vs2_act      STRING,
  univ_ant         STRING,
  univ_act         STRING,
  tipo_cambio      STRING
)
PARTITION BY fecha_corte
CLUSTER BY cod_cliente_dex;

-- Mapa de clientes unificados (cambio de razon social / de codigo) por corte. Lo llena el paso 00d.
-- cod_cliente_dex_actual = llave unica del cliente en todo el pipeline.
CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_mapa_nodo` (
  fecha_corte             DATE,
  num_nodo                INT64,
  cod_cliente_dex         INT64,
  cod_cliente_dex_actual  INT64,
  tip_clasificacion       STRING
)
PARTITION BY fecha_corte;

-- Boca -> grupo vs2 (BO/MM/AB/Sin asignar se pliegan a BO; igual que el paso 02)
CREATE OR REPLACE FUNCTION `{{ ds }}.fn_vs2`(cod STRING)
RETURNS STRING AS (
  IF(UPPER(cod) IN ('BO','MM','AB','SIN ASIGNAR'), 'BO', cod)
);

-- Boca -> universo: CMP (BO, MM, AB, Sin asignar, PM, GO), AS (grupos_diamante: PA, GA, LV), OTRO
CREATE OR REPLACE FUNCTION `{{ ds }}.fn_universo`(cod STRING)
RETURNS STRING AS (
  CASE
    WHEN cod IS NULL THEN NULL
    WHEN UPPER(cod) IN ('BO','MM','AB','SIN ASIGNAR','PM','GO') THEN 'CMP'
    WHEN UPPER(cod) IN ({{ grupos_diamante }}) THEN 'AS'
    ELSE 'OTRO'
  END
);

-- Copia de la segmentacion OFICIAL del corte previo (mismo esquema que seg_segmentacion).
-- Tabla aparte para que la previa oficial no choque con la corrida del mismo fecha_corte.
CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_prev_oficial` (
  fecha_corte                     DATE,
  cod_grupo_precio_dex            STRING,
  des_grupo_precio_dex            STRING,
  cod_grupo_precio_dex_vs2        STRING,
  cod_cliente_dex                 INT64,
  cod_cliente_alicorp_actual      STRING,
  sum_vb                          FLOAT64,
  sum_ub                          FLOAT64,
  sum_ub_ajustada                 FLOAT64,
  meses_distintos                 INT64,
  sin_asignar                     STRING,
  ub_ajustada_acum                FLOAT64,
  ub_ajustada_dex                 FLOAT64,
  percentil                       FLOAT64,
  des_segmentacion_transaccional  STRING,
  origen                          STRING,
  des_segmento_regular            STRING,
  grupo_diamante                  STRING,
  percentil_diamante              FLOAT64
)
PARTITION BY fecha_corte
CLUSTER BY cod_cliente_dex;

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_umbrales_diamante` (
  fecha_corte                 DATE,
  grupo_diamante              STRING,
  cod_cliente_alicorp_actual  STRING,
  total_clientes              INT64,
  min_diamante                FLOAT64,
  max_diamante                FLOAT64
)
PARTITION BY fecha_corte;

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_umbrales` (
  fecha_corte                 DATE,
  cod_grupo_precio_dex_vs2    STRING,
  cod_cliente_alicorp_actual  STRING,
  total_clientes_activos      INT64,
  total_ub_ajustada           FLOAT64,
  min_bronce                  FLOAT64,
  max_bronce                  FLOAT64,
  min_plata                   FLOAT64,
  max_plata                   FLOAT64,
  min_oro                     FLOAT64,
  max_oro                     FLOAT64,
  min_oro_plus                FLOAT64,
  max_oro_plus                FLOAT64
)
PARTITION BY fecha_corte;

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_estrategica` (
  fecha_corte                  DATE,
  id_interlocutor_origen       STRING,
  des_segmento_estrategico     STRING
)
PARTITION BY fecha_corte;

CREATE TABLE IF NOT EXISTS `{{ ds }}.seg_run_log` (
  run_id        STRING,
  ts            TIMESTAMP,
  modo          STRING,
  p_corte       DATE,
  step          STRING,
  status        STRING,
  bytes_billed  INT64,
  seconds       FLOAT64,
  metrics       STRING,
  error         STRING
);

CREATE TABLE IF NOT EXISTS `{{ out_tabla_alterna }}` (
  periodo                     DATE,
  cod_interlocutor            STRING,
  cod_boca_salida             STRING,
  des_segmento_transaccional  STRING,
  des_segmento_estrategica    STRING
)
PARTITION BY periodo;

-- Misma logica que asignar_segmentacion() del notebook:
--   sin umbrales -> Bronce; >= minimo de mayor a menor; si queda por debajo de todos -> el segmento mas bajo disponible.
--   (con un solo umbral disponible devuelve ese segmento, igual que el notebook)
CREATE OR REPLACE FUNCTION `{{ ds }}.fn_asignar_seg`(
  ub FLOAT64, m_oro_plus FLOAT64, m_oro FLOAT64, m_plata FLOAT64, m_bronce FLOAT64
)
RETURNS STRING AS (
  CASE
    WHEN m_oro_plus IS NULL AND m_oro IS NULL AND m_plata IS NULL AND m_bronce IS NULL THEN '4 Bronce'
    WHEN m_oro_plus IS NOT NULL AND ub >= m_oro_plus THEN '1 Oro+'
    WHEN m_oro      IS NOT NULL AND ub >= m_oro      THEN '2 Oro'
    WHEN m_plata    IS NOT NULL AND ub >= m_plata    THEN '3 Plata'
    WHEN m_bronce   IS NOT NULL AND ub >= m_bronce   THEN '4 Bronce'
    WHEN m_bronce   IS NOT NULL THEN '4 Bronce'
    WHEN m_plata    IS NOT NULL THEN '3 Plata'
    WHEN m_oro      IS NOT NULL THEN '2 Oro'
    ELSE '1 Oro+'
  END
);
