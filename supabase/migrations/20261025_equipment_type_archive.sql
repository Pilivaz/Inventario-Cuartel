-- Baja lógica y auditable de tipos de equipamiento. No elimina datos ni relaciones.
alter table public.equipment_types
  add column if not exists archived_at timestamptz;

create or replace function public.archive_equipment_type(p_type_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type public.equipment_types%rowtype;
  v_unit record;
  v_assignment public.assignments%rowtype;
  v_units_retired integer := 0;
  v_assignments_closed integer := 0;
  v_closed_for_unit integer;
begin
  if not public.is_authorized_user() then
    raise exception 'La cuenta no está autorizada para dar de baja elementos.';
  end if;
  if p_type_id is null or nullif(trim(p_reason), '') is null or length(p_reason) > 2000 then
    raise exception 'Seleccioná un elemento e indicá un motivo de hasta 2000 caracteres.';
  end if;

  select * into v_type
  from public.equipment_types
  where id = p_type_id
  for update;
  if not found then raise exception 'El tipo de elemento no existe.'; end if;
  if v_type.archived_at is not null then raise exception 'El tipo de elemento ya está dado de baja.'; end if;
  if exists (
    select 1 from public.uniform_components where equipment_type_id = p_type_id
  ) then
    raise exception 'Este tipo forma parte de una plantilla de uniforme. Quitalo de la plantilla antes de darlo de baja.';
  end if;

  -- Lock and retire each real physical unit. The row locks serialize this operation
  -- against assignment/return RPCs that also lock the unit.
  for v_unit in
    select id from public.equipment_units
    where equipment_type_id = p_type_id and lifecycle = 'active'
    order by id
    for update
  loop
    select * into v_assignment
    from public.assignments
    where equipment_unit_id = v_unit.id
      and status in ('active', 'pending_review')
    order by created_at desc, id desc
    limit 1
    for update;

    update public.assignments
    set status = 'retired',
        returned_at = coalesce(returned_at, now()),
        notes = concat_ws(E'\n', notes, 'Baja del tipo: ' || trim(p_reason))
    where equipment_unit_id = v_unit.id
      and status in ('active', 'pending_review');
    get diagnostics v_closed_for_unit = row_count;
    v_assignments_closed := v_assignments_closed + v_closed_for_unit;

    update public.equipment_units
    set lifecycle = 'retired'
    where id = v_unit.id and lifecycle = 'active';
    if found then
      v_units_retired := v_units_retired + 1;
      insert into public.movements(equipment_unit_id, assignment_id, firefighter_id, movement_type, details, notes)
      values (
        v_unit.id,
        case when v_assignment.id is not null then v_assignment.id else null end,
        case when v_assignment.id is not null then v_assignment.firefighter_id else null end,
        'retired',
        jsonb_build_object(
          'equipment_type_id', p_type_id,
          'equipment_type_name', v_type.name,
          'type_archived', true,
          'assignments_closed', v_closed_for_unit
        ),
        trim(p_reason)
      );
    end if;
  end loop;

  update public.equipment_types
  set archived_at = now(), updated_at = now()
  where id = p_type_id;

  -- A type-level event also records zero-stock types and the aggregate operation.
  insert into public.movements(movement_type, details, notes)
  values (
    'retired',
    jsonb_build_object(
      'equipment_type_id', p_type_id,
      'equipment_type_name', v_type.name,
      'type_archived', true,
      'units_retired', v_units_retired,
      'assignments_closed', v_assignments_closed
    ),
    trim(p_reason)
  );

  return jsonb_build_object(
    'equipment_type_id', p_type_id,
    'equipment_type_name', v_type.name,
    'units_retired', v_units_retired,
    'assignments_closed', v_assignments_closed
  );
end;
$$;
revoke all on function public.archive_equipment_type(uuid, text) from public, anon;
grant execute on function public.archive_equipment_type(uuid, text) to authenticated;

create or replace function public.restore_equipment_type(p_type_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_type public.equipment_types%rowtype;
begin
  if not public.is_authorized_user() then
    raise exception 'La cuenta no está autorizada para restaurar elementos.';
  end if;
  if p_type_id is null then raise exception 'Seleccioná el tipo de elemento.'; end if;
  select * into v_type from public.equipment_types where id = p_type_id for update;
  if not found then raise exception 'El tipo de elemento no existe.'; end if;
  if v_type.archived_at is null then raise exception 'El tipo de elemento no está dado de baja.'; end if;
  update public.equipment_types set archived_at = null, updated_at = now() where id = p_type_id;
  insert into public.movements(movement_type, details, notes)
  values ('edited', jsonb_build_object('equipment_type_id', p_type_id, 'equipment_type_name', v_type.name, 'type_restored', true), 'Tipo restaurado; las unidades permanecen dadas de baja.');
end;
$$;
revoke all on function public.restore_equipment_type(uuid) from public, anon;
grant execute on function public.restore_equipment_type(uuid) to authenticated;
