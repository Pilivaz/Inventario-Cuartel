-- Allow a firefighter to register personal gear and update ownership without
-- including personal units in the station stock. All writes stay transactional.
create or replace function public.register_personal_equipment(
  p_firefighter_id uuid,
  p_type_name text,
  p_condition text,
  p_delivered_at date,
  p_size text default null,
  p_brand text default null,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_type_id uuid;
  v_unit public.equipment_units%rowtype;
  v_assignment_id uuid;
begin
  if not public.is_authorized_user() then
    raise exception 'La cuenta no está autorizada para registrar equipamiento.';
  end if;
  if not exists(select 1 from public.firefighters where id=p_firefighter_id and active) then
    raise exception 'Elegí un bombero activo.';
  end if;
  if nullif(trim(p_type_name),'') is null or length(p_type_name)>200 then
    raise exception 'Indicá un nombre de elemento válido (hasta 200 caracteres).';
  end if;
  if p_condition is null or p_condition not in ('good','regular','bad','out_of_service','review') then
    raise exception 'Elegí un estado de conservación válido.';
  end if;
  if p_condition in ('out_of_service','review') then
    raise exception 'Un elemento fuera de servicio o pendiente de revisión no se puede registrar como asignado.';
  end if;
  if p_delivered_at is null then raise exception 'Indicá la fecha de entrega.'; end if;
  if length(coalesce(p_brand,''))>200 or length(coalesce(p_size,''))>100 or length(coalesce(p_notes,''))>2000 then
    raise exception 'Revisá la longitud de marca, talle u observaciones.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_type_name)),0));
  select id into v_type_id from public.equipment_types
    where lower(name)=lower(trim(p_type_name)) order by created_at limit 1;
  if v_type_id is null then
    insert into public.equipment_types(name) values(trim(p_type_name)) on conflict(name) do nothing;
    select id into v_type_id from public.equipment_types
      where lower(name)=lower(trim(p_type_name)) order by created_at limit 1;
  end if;
  if v_type_id is null then raise exception 'No se pudo crear o encontrar el tipo de elemento.'; end if;

  insert into public.equipment_units(equipment_type_id,condition,ownership,owner_firefighter_id,lifecycle,brand,size,notes)
    values(v_type_id,p_condition,'firefighter',p_firefighter_id,'active',nullif(trim(p_brand),''),
      nullif(trim(p_size),''),nullif(trim(p_notes),'')) returning * into v_unit;
  insert into public.assignments(equipment_unit_id,firefighter_id,delivered_at,size_snapshot,brand_snapshot,notes)
    values(v_unit.id,p_firefighter_id,p_delivered_at::timestamptz,nullif(trim(p_size),''),
      nullif(trim(p_brand),''),nullif(trim(p_notes),'')) returning id into v_assignment_id;
  insert into public.movements(equipment_unit_id,firefighter_id,movement_type,details,notes)
    values(v_unit.id,p_firefighter_id,'registered',jsonb_build_object('origin','personal_equipment','ownership','firefighter','unit_code',v_unit.unit_code),nullif(trim(p_notes),''));
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v_unit.id,v_assignment_id,p_firefighter_id,'assigned',
      jsonb_build_object('origin','personal_equipment','ownership','firefighter','delivered_at',p_delivered_at,
        'brand',nullif(trim(p_brand),''),'size',nullif(trim(p_size),'')),nullif(trim(p_notes),''));
  return jsonb_build_object('equipment_unit_id',v_unit.id,'assignment_id',v_assignment_id,
    'unit_code',v_unit.unit_code,'ownership',v_unit.ownership);
end $$;
revoke all on function public.register_personal_equipment(uuid,text,text,date,text,text,text) from public, anon;
grant execute on function public.register_personal_equipment(uuid,text,text,date,text,text,text) to authenticated;

-- Ownership, assignment details, and audit movement change atomically.
create or replace function public.update_equipment_assignment(
  p_assignment_id uuid,
  p_delivered_at date,
  p_brand text,
  p_size text,
  p_notes text,
  p_ownership text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v public.assignments%rowtype;
  v_unit public.equipment_units%rowtype;
  v_type_name text;
  v_delivered_at timestamptz;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para editar asignaciones.'; end if;
  if p_ownership is null or p_ownership not in ('station','firefighter') then
    raise exception 'Elegí si el elemento pertenece al cuartel o al bombero.';
  end if;
  if length(coalesce(p_brand,''))>200 or length(coalesce(p_size,''))>100 or length(coalesce(p_notes,''))>2000 then
    raise exception 'Revisá la longitud de marca, talle u observaciones.';
  end if;

  select * into v from public.assignments where id=p_assignment_id for update;
  if not found then raise exception 'La asignación no existe.'; end if;
  if v.status<>'active' then raise exception 'Solo se pueden editar asignaciones activas.'; end if;
  select * into v_unit from public.equipment_units where id=v.equipment_unit_id for update;
  if not found or v_unit.lifecycle<>'active' then raise exception 'La unidad no existe o ya no está activa.'; end if;
  if v_unit.ownership='firefighter' and v_unit.owner_firefighter_id is distinct from v.firefighter_id then
    raise exception 'El elemento personal pertenece a otro bombero.';
  end if;
  select name into v_type_name from public.equipment_types where id=v_unit.equipment_type_id;
  v_delivered_at:=coalesce(p_delivered_at::timestamptz,v.delivered_at);

  update public.assignments set delivered_at=v_delivered_at,
    brand_snapshot=nullif(trim(p_brand),''),size_snapshot=nullif(trim(p_size),''),notes=nullif(trim(p_notes),'')
    where id=v.id;
  update public.equipment_units set ownership=p_ownership,
    owner_firefighter_id=case when p_ownership='firefighter' then v.firefighter_id else null end,
    brand=nullif(trim(p_brand),''),size=nullif(trim(p_size),'')
    where id=v_unit.id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v_unit.id,v.id,v.firefighter_id,'edited',
      jsonb_build_object('record_type','assignment','element',v_type_name,
        'before',jsonb_build_object('delivered_at',v.delivered_at,'brand',v.brand_snapshot,'size',v.size_snapshot,
          'notes',v.notes,'ownership',v_unit.ownership,'owner_firefighter_id',v_unit.owner_firefighter_id),
        'after',jsonb_build_object('delivered_at',v_delivered_at,'brand',nullif(trim(p_brand),''),
          'size',nullif(trim(p_size),''),'notes',nullif(trim(p_notes),''),'ownership',p_ownership,
          'owner_firefighter_id',case when p_ownership='firefighter' then v.firefighter_id else null end)),
      nullif(trim(p_notes),''));
end $$;
revoke all on function public.update_equipment_assignment(uuid,date,text,text,text,text) from public, anon;
grant execute on function public.update_equipment_assignment(uuid,date,text,text,text,text) to authenticated;


