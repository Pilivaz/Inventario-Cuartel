begin;

-- New overload: atomically assign the exact available unit selected for every
-- component and save that component's current size/brand in both unit and assignment.
create or replace function public.assign_uniform(
  p_uniform_id uuid,
  p_firefighter_id uuid,
  p_delivered_at date,
  p_notes text,
  p_component_selections jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  selection jsonb;
  v_unit_id uuid;
  v_type_id uuid;
  v_size text;
  v_brand text;
  v_expected integer;
  v_inserted integer := 0;
begin
  if not public.is_authorized_user() then
    raise exception 'La cuenta no está autorizada para asignar uniformes.';
  end if;
  if p_delivered_at is null or length(coalesce(p_notes, '')) > 2000 then
    raise exception 'Revisá la fecha y las observaciones.';
  end if;
  if p_component_selections is null or jsonb_typeof(p_component_selections) is distinct from 'array' then
    raise exception 'Seleccioná las unidades de cada componente del uniforme.';
  end if;

  perform 1 from public.firefighters where id = p_firefighter_id and active for update;
  if not found then raise exception 'El bombero no existe o no está activo.'; end if;
  if not exists(select 1 from public.uniforms where id = p_uniform_id and active) then
    raise exception 'La plantilla no existe o está inactiva.';
  end if;
  select coalesce(sum(quantity), 0)::integer into v_expected
  from public.uniform_components where uniform_id = p_uniform_id;
  if v_expected < 1 then raise exception 'La plantilla no tiene componentes.'; end if;
  if jsonb_array_length(p_component_selections) <> v_expected then
    raise exception 'Debe seleccionarse una unidad para cada componente requerido.';
  end if;

  if exists (
    select 1 from (
      select item->>'equipment_unit_id' as unit_id, count(*) as copies
      from jsonb_array_elements(p_component_selections) as source(item)
      group by item->>'equipment_unit_id'
    ) chosen where chosen.unit_id is null or chosen.copies <> 1
  ) then raise exception 'Cada componente debe usar una unidad física distinta.'; end if;

  if exists (
    select 1 from (
      select (item->>'equipment_type_id')::uuid as equipment_type_id, count(*)::integer as quantity
      from jsonb_array_elements(p_component_selections) as source(item)
      group by (item->>'equipment_type_id')::uuid
    ) chosen
    where chosen.quantity <> coalesce((
      select sum(uc.quantity)::integer from public.uniform_components uc
      where uc.uniform_id = p_uniform_id and uc.equipment_type_id = chosen.equipment_type_id
    ), 0)
  ) then raise exception 'La selección no coincide con los componentes de la plantilla.'; end if;

  -- Lock all selected rows before validation, preventing concurrent assignment.
  perform u.id
  from public.equipment_units u
  where u.id in (
    select (item->>'equipment_unit_id')::uuid
    from jsonb_array_elements(p_component_selections) as source(item)
  )
  order by u.id
  for update;

  for selection in select value from jsonb_array_elements(p_component_selections) as source(value) loop
    v_unit_id := (selection->>'equipment_unit_id')::uuid;
    v_type_id := (selection->>'equipment_type_id')::uuid;
    v_size := nullif(trim(selection->>'size'), '');
    v_brand := nullif(trim(selection->>'brand'), '');

    if not exists (
      select 1 from public.uniform_components uc
      where uc.uniform_id = p_uniform_id and uc.equipment_type_id = v_type_id
    ) then raise exception 'Un componente no pertenece a la plantilla elegida.'; end if;

    if not exists (
      select 1 from public.equipment_units u
      where u.id = v_unit_id and u.equipment_type_id = v_type_id
        and u.ownership = 'station' and u.lifecycle = 'active'
        and u.condition not in ('out_of_service', 'review')
        and not exists (
          select 1 from public.assignments a
          where a.equipment_unit_id = u.id and a.status in ('active', 'pending_review')
        )
    ) then raise exception 'Una unidad elegida ya no está disponible o no coincide con el componente.'; end if;

    update public.equipment_units set size = v_size, brand = v_brand where id = v_unit_id;
    perform public.assign_unit(v_unit_id, p_firefighter_id, p_delivered_at, v_size, v_brand, p_notes);
    v_inserted := v_inserted + 1;
  end loop;

  insert into public.movements(firefighter_id, movement_type, details, notes)
  values (p_firefighter_id, 'assigned', jsonb_build_object('uniform_id', p_uniform_id, 'components_assigned', v_inserted), p_notes);
  return v_inserted;
end;
$$;

revoke all on function public.assign_uniform(uuid, uuid, date, text, jsonb) from public, anon;
grant execute on function public.assign_uniform(uuid, uuid, date, text, jsonb) to authenticated;

commit;
