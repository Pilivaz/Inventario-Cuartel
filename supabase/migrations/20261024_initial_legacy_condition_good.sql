-- Establece el estado inicial de las unidades sincronizadas desde las fichas.
-- Solo afecta unidades activas del cuartel aún en revisión que no tienen
-- un cambio de conservación auditado. Las filas fuente nunca se modifican.
-- Idempotente: las unidades ya revisadas/cambiadas manualmente quedan intactas.

do $$
declare
  v_updated integer;
begin
  with linked_units as (
    select equipment_unit_id from public.legacy_unit_links
    union
    select equipment_unit_id from public.legacy_unit_link_extras
  ), candidates as (
    select distinct u.id
    from public.equipment_units u
    join linked_units l on l.equipment_unit_id = u.id
    where u.ownership = 'station'
      and u.lifecycle = 'active'
      and u.condition = 'review'
      and not exists (
        select 1 from public.movements m
        where m.equipment_unit_id = u.id
          and m.movement_type = 'condition_changed'
      )
  ), updated as (
    update public.equipment_units u
    set condition = 'good'
    from candidates c
    where u.id = c.id
    returning u.id
  )
  insert into public.movements(
    equipment_unit_id, assignment_id, firefighter_id,
    movement_type, details, notes, actor_id
  )
  select updated.id, active_assignment.id, active_assignment.firefighter_id,
    'condition_changed',
    jsonb_build_object(
      'before', 'review',
      'after', 'good',
      'reason', 'initial_legacy_default',
      'source', 'administrator_requested_default'
    ),
    'Estado inicial establecido en Bien estado por solicitud del administrador; valor original de la ficha conservado.',
    null
  from updated
  left join lateral (
    select a.id, a.firefighter_id
    from public.assignments a
    where a.equipment_unit_id = updated.id
      and a.status in ('active', 'pending_review')
    order by a.created_at desc
    limit 1
  ) active_assignment on true;

  get diagnostics v_updated = row_count;
  raise notice 'Unidades históricas pasadas a Bien estado: %', v_updated;
end $$;
