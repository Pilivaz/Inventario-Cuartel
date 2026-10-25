-- Limpieza única previa al inicio de uso operativo.
-- Ejecutar una sola vez en Supabase SQL Editor.
-- Conserva las unidades, bomberos, asignaciones, fichas Excel y plantillas.
-- El contador final informa cuántos movimientos fueron eliminados.
BEGIN;

ALTER TABLE public.equipment_units
  ADD COLUMN IF NOT EXISTS legacy_retired_adjustment boolean NOT NULL DEFAULT false;

-- Preserva la clasificación de los ajustes previos que no fueron bajas reales.
UPDATE public.equipment_units AS unit
SET legacy_retired_adjustment = true
WHERE EXISTS (
  SELECT 1
  FROM public.movements AS movement
  WHERE movement.equipment_unit_id = unit.id
    AND movement.movement_type = 'retired'
    AND btrim(coalesce(movement.notes, '')) = 'Nunca lo tuvo este bombero'
);

WITH deleted_movements AS (
  DELETE FROM public.movements
  RETURNING id
)
SELECT count(*) AS deleted_movements FROM deleted_movements;

COMMIT;