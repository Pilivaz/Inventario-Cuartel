-- Clear only the exact generic note added during the initial physical-unit reconciliation.
-- This leaves original Excel rows, other notes, assignments, units, and movement history untouched.
begin;

update public.assignments
set notes = null
where btrim(notes) = 'Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.';

update public.equipment_units
set notes = null
where btrim(notes) = 'Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.';

commit;
