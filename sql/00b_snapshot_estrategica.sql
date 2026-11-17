-- 00b: snapshot de golosineros para el corte, desde la tabla de segmentacion estrategica.
-- Se guarda en seg_estrategica (por fecha_corte) para que el corte sea reproducible aunque la fuente cambie.
-- Fuente: fec_corrida, id_interlocutor_origen STRING, des_segmento_estrategico STRING, cod_boca_salida STRING.
-- id_interlocutor_origen se limpia igual que en el notebook (quita decimales y caracteres no numericos).
-- La fuente puede traer varias filas por cliente (cod_boca_salida): se deduplica por interlocutor.
DECLARE p_corte DATE DEFAULT @p_corte;

DELETE FROM `{{ ds }}.seg_estrategica` WHERE fecha_corte = p_corte;

INSERT INTO `{{ ds }}.seg_estrategica`
  (fecha_corte, id_interlocutor_origen, des_segmento_estrategico)
SELECT DISTINCT
  p_corte,
  NULLIF(REGEXP_REPLACE(SPLIT(CAST(id_interlocutor_origen AS STRING), '.')[OFFSET(0)], r'\D', ''), ''),
  des_segmento_estrategico
FROM `{{ src_estrategica_fuente }}`
WHERE SAFE_CAST(fec_corrida AS DATE) = p_corte
  AND des_segmento_estrategico = 'Golosinera'
  AND id_interlocutor_origen IS NOT NULL;

SELECT COUNT(*) AS n_golosineros
FROM `{{ ds }}.seg_estrategica`
WHERE fecha_corte = p_corte
  AND id_interlocutor_origen IS NOT NULL;
