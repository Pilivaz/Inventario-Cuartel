create or replace function public.update_equipment_assignment(
  p_assignment_id uuid,
  p_delivered_at date,
  p_brand text,
  p_size text,
  p_notes text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.assignments%rowtype;
  v_type_name text;
  v_unit_id uuid;
  v_delivered_at timestamptz;
begin
  if not public.is_authorized_user() then
    raise exception 'La cuenta no está autorizada para editar asignaciones.';
  end if;
  if length(coalesce(p_brand,'')) > 200 or length(coalesce(p_size,'')) > 100 or length(coalesce(p_notes,'')) > 2000 then
    raise exception 'Revisá la longitud de marca, talle u observaciones.';
  end if;

  select equipment_unit_id into v_unit_id from public.assignments where id=p_assignment_id;
  if not found then raise exception 'La asignación no existe.'; end if;
  perform 1 from public.equipment_units where id=v_unit_id and ownership='station' for update;
  if not found then raise exception 'La asignación no corresponde a una unidad del cuartel.'; end if;
  select * into v from public.assignments where id=p_assignment_id for update;
  if not found then raise exception 'La asignación no existe.'; end if;
  if v.status <> 'active' then raise exception 'Solo se pueden editar asignaciones activas.'; end if;

  select name into v_type_name
    from public.equipment_types t
    join public.equipment_units u on u.equipment_type_id=t.id
    where u.id=v.equipment_unit_id;

  -- Una fecha vacía conserva el valor que ya existía, incluso si sigue siendo NULL.
  v_delivered_at := coalesce(p_delivered_at::timestamptz, v.delivered_at);
  update public.assignments
    set delivered_at=v_delivered_at,
        brand_snapshot=nullif(trim(p_brand),''),
        size_snapshot=nullif(trim(p_size),''),
        notes=nullif(trim(p_notes),'')
    where id=v.id;
  update public.equipment_units
    set brand=nullif(trim(p_brand),''), size=nullif(trim(p_size),'')
    where id=v.equipment_unit_id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v.equipment_unit_id,v.id,v.firefighter_id,'edited',
      jsonb_build_object('record_type','assignment','element',v_type_name,
        'before',jsonb_build_object('delivered_at',v.delivered_at,'brand',v.brand_snapshot,'size',v.size_snapshot,'notes',v.notes),
        'after',jsonb_build_object('delivered_at',v_delivered_at,'brand',nullif(trim(p_brand),''),'size',nullif(trim(p_size),''),'notes',nullif(trim(p_notes),''))),
      nullif(trim(p_notes),''));
end $$;
revoke all on function public.update_equipment_assignment(uuid,date,text,text,text) from public, anon;
grant execute on function public.update_equipment_assignment(uuid,date,text,text,text) to authenticated;
