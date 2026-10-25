-- Asigna legajos consecutivos únicamente a bomberos del padrón actual que no tengan uno.
-- Conserva todos los legajos existentes y no crea bomberos ni modifica asignaciones/equipamiento.
-- El orden es el listado vigente; los números empiezan después del mayor legajo numérico ya ocupado.
BEGIN;

CREATE TEMP TABLE firefighter_roster_order (
  roster_order integer PRIMARY KEY,
  full_name text NOT NULL
) ON COMMIT DROP;

INSERT INTO firefighter_roster_order (roster_order, full_name) VALUES
  (1, 'Mauricio Santini'),
  (2, 'Damian Miranda'),
  (3, 'Carlos Gadea'),
  (4, 'Julio Farias'),
  (5, 'Lucía Fiordani'),
  (6, 'Santiago Fernández'),
  (7, 'Shunko Rodríguez'),
  (8, 'Sergio Abaca'),
  (9, 'David Garnero'),
  (10, 'Gisela Di Giusto'),
  (11, 'Matías Magnano'),
  (12, 'Diego Panozzo'),
  (13, 'Carlos Bravo'),
  (14, 'Malena Teuler'),
  (15, 'Irina Monti'),
  (16, 'Laurentino Ponzalino'),
  (17, 'Valentin Camats'),
  (18, 'Angel Gonzalez'),
  (19, 'Danilo Cassina'),
  (20, 'Tomás Magolini'),
  (21, 'Magalí Acosta'),
  (22, 'Jonathan Martínez'),
  (23, 'Jonathan Oyola'),
  (24, 'Dana Pelo'),
  (25, 'Santiago Gonzalez'),
  (26, 'Aldana Barrera'),
  (27, 'Roberto Tulián'),
  (28, 'Maximiliano Cisnero'),
  (29, 'Juan Clavero'),
  (30, 'Pilar Vazquez'),
  (31, 'Lazaro Falco'),
  (32, 'Damaris Martín');

-- No continúa si el padrón no coincide exactamente con las personas existentes.
DO $$
DECLARE
  roster_problem text;
BEGIN
  SELECT string_agg(roster.full_name, ', ' ORDER BY roster.roster_order)
    INTO roster_problem
  FROM firefighter_roster_order AS roster
  WHERE (
    SELECT count(*)
    FROM public.firefighters AS firefighter
    WHERE translate(lower(regexp_replace(btrim(firefighter.full_name), '\s+', ' ', 'g')), 'áéíóúüñ', 'aeiouun')
        = translate(lower(regexp_replace(btrim(roster.full_name), '\s+', ' ', 'g')), 'áéíóúüñ', 'aeiouun')
  ) <> 1;

  IF roster_problem IS NOT NULL THEN
    RAISE EXCEPTION 'No se modificó ningún legajo. Revisá estos nombres del padrón (faltan o están duplicados): %', roster_problem;
  END IF;
END $$;

WITH missing AS (
  SELECT firefighter.id,
         row_number() OVER (ORDER BY roster.roster_order) AS sequence_no
  FROM firefighter_roster_order AS roster
  JOIN public.firefighters AS firefighter
    ON translate(lower(regexp_replace(btrim(firefighter.full_name), '\s+', ' ', 'g')), 'áéíóúüñ', 'aeiouun')
     = translate(lower(regexp_replace(btrim(roster.full_name), '\s+', ' ', 'g')), 'áéíóúüñ', 'aeiouun')
  WHERE nullif(btrim(firefighter.personnel_no), '') IS NULL
), highest AS (
  SELECT coalesce(max(btrim(personnel_no)::numeric), 0) AS number
  FROM public.firefighters
  WHERE btrim(personnel_no) ~ '^[0-9]+$'
), updated AS (
  UPDATE public.firefighters AS firefighter
  SET personnel_no = (highest.number + missing.sequence_no)::text,
      updated_at = now()
  FROM missing CROSS JOIN highest
  WHERE firefighter.id = missing.id
  RETURNING firefighter.full_name, firefighter.personnel_no
)
SELECT full_name, personnel_no AS legajo_asignado
FROM updated
ORDER BY personnel_no::numeric;

COMMIT;