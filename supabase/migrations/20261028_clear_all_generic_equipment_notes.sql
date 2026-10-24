-- Remove only generic notes generated while preparing initial unit links.
-- It is safe to run repeatedly: other notes and all original Excel rows remain unchanged.
begin;

update public.assignments
set notes = null
where btrim(notes) in (
  'Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.',
  'Asignada según cantidad de la ficha histórica; fecha original no consignada.','Unidad adicional indicada por la cantidad original; conservación pendiente de revisión.'
);

update public.equipment_units
set notes = null
where btrim(notes) in (
  'Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.',
  'Asignada según cantidad de la ficha histórica; fecha original no consignada.','Unidad adicional indicada por la cantidad original; conservación pendiente de revisión.'
);

commit;
