-- Explicitly reconcile one original firefighter workbook row with one real unit.
-- Source rows stay immutable. This migration never creates stock by itself.
begin;

create table if not exists public.legacy_unit_links (
  legacy_import_row_id uuid primary key references public.legacy_import_rows(id) on delete restrict,
  equipment_unit_id uuid not null unique references public.equipment_units(id) on delete restrict,
  assignment_id uuid not null unique references public.assignments(id) on delete restrict,
  confirmed_by uuid references auth.users(id) on delete set null default auth.uid(),
  confirmed_at timestamptz not null default now()
);
alter table public.legacy_unit_links enable row level security;
drop policy if exists "authorized users read legacy unit links" on public.legacy_unit_links;
create policy "authorized users read legacy unit links" on public.legacy_unit_links
  for select to authenticated using (public.is_authorized_user());
revoke all on public.legacy_unit_links from public, anon, authenticated;
grant select on public.legacy_unit_links to authenticated;

create or replace function public.reconcile_legacy_item(
  p_legacy_row_id uuid,
  p_existing_unit_id uuid default null,
  p_type_name text default null,
  p_ownership text default null,
  p_condition text default null,
  p_brand text default null,
  p_size text default null,
  p_delivered_on date default null,
  p_notes text default null,
  p_confirmed boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_source public.legacy_import_rows%rowtype;
  v_link public.legacy_unit_links%rowtype;
  v_unit public.equipment_units%rowtype;
  v_type_id uuid;
  v_assignment_id uuid;
  v_ownership text;
  v_unit_created boolean := false;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para vincular fichas con el inventario.'; end if;
  if p_confirmed is distinct from true then raise exception 'Confirmá la vista previa antes de registrar el vínculo.'; end if;
  select * into v_source from public.legacy_import_rows where id=p_legacy_row_id for update;
  if not found or v_source.source_sheet not like 'Ficha individual · %' or v_source.firefighter_id is null then
    raise exception 'Solo se puede vincular una fila de ficha individual asociada a un bombero.';
  end if;
  if not exists(select 1 from public.firefighters where id=v_source.firefighter_id and active) then
    raise exception 'El bombero de esta ficha no está activo.';
  end if;
  if to_regclass('public.legacy_row_reviews') is not null and exists (
    select 1 from public.legacy_row_reviews where legacy_import_row_id=p_legacy_row_id and custody_status='no_longer_with_firefighter'
  ) then raise exception 'La ficha indica que el bombero ya no tiene este elemento; revisá su situación antes de vincularlo.'; end if;

  select * into v_link from public.legacy_unit_links where legacy_import_row_id=p_legacy_row_id;
  if found then
    return jsonb_build_object('legacy_import_row_id',v_link.legacy_import_row_id,'equipment_unit_id',v_link.equipment_unit_id,
      'assignment_id',v_link.assignment_id,'already_linked',true);
  end if;
  if p_delivered_on is null then raise exception 'Indicá la fecha de entrega confirmada.'; end if;
  if length(coalesce(p_brand,''))>200 or length(coalesce(p_size,''))>100 or length(coalesce(p_notes,''))>2000 then
    raise exception 'Revisá la longitud de marca, talle u observaciones.';
  end if;

  if p_existing_unit_id is not null then
    select * into v_unit from public.equipment_units where id=p_existing_unit_id for update;
    if not found or v_unit.lifecycle<>'active' then raise exception 'La unidad física seleccionada no está activa.'; end if;
    if exists(select 1 from public.assignments where equipment_unit_id=v_unit.id and status in ('active','pending_review')) then
      raise exception 'La unidad física ya está asignada o pendiente de revisión.';
    end if;
    if v_unit.condition='out_of_service' then raise exception 'La unidad está fuera de servicio.'; end if;
    if v_unit.ownership='station' then
      null;
    elsif v_unit.ownership='firefighter' then
      if v_unit.owner_firefighter_id is distinct from v_source.firefighter_id then
        raise exception 'La unidad personal no pertenece al bombero de esta ficha.';
      end if;
    else raise exception 'La propiedad de la unidad está pendiente de revisión.';
    end if;
    v_ownership:=v_unit.ownership;
  else
    if p_ownership is null or p_ownership not in ('station','firefighter') then raise exception 'Elegí expresamente si la unidad pertenece al cuartel o al bombero.'; end if;
    if p_condition is null or p_condition not in ('good','regular','bad','out_of_service','review') then raise exception 'Elegí expresamente el estado de conservación.'; end if;
    if p_condition='out_of_service' then raise exception 'Una unidad fuera de servicio no puede asignarse.'; end if;
    if nullif(trim(p_type_name),'') is null or length(p_type_name)>200 then raise exception 'Indicá un tipo de elemento válido.'; end if;
    perform pg_advisory_xact_lock(hashtextextended(lower(trim(p_type_name)),0));
    select id into v_type_id from public.equipment_types where lower(name)=lower(trim(p_type_name)) order by created_at limit 1;
    if v_type_id is null then
      insert into public.equipment_types(name) values(trim(p_type_name)) on conflict(name) do nothing;
      select id into v_type_id from public.equipment_types where lower(name)=lower(trim(p_type_name)) order by created_at limit 1;
    end if;
    if v_type_id is null then raise exception 'No se pudo crear o encontrar el tipo de elemento.'; end if;
    insert into public.equipment_units(equipment_type_id,condition,ownership,owner_firefighter_id,brand,size,notes)
      values(v_type_id,p_condition,p_ownership,case when p_ownership='firefighter' then v_source.firefighter_id else null end,
        nullif(trim(p_brand),''),nullif(trim(p_size),''),nullif(trim(p_notes),'')) returning * into v_unit;
    v_ownership:=p_ownership;
    v_unit_created:=true;
  end if;

  if not v_unit_created and (v_unit.brand is distinct from nullif(trim(p_brand),'') or v_unit.size is distinct from nullif(trim(p_size),'')) then
    update public.equipment_units set brand=nullif(trim(p_brand),''),size=nullif(trim(p_size),'') where id=v_unit.id;
  end if;

  insert into public.assignments(equipment_unit_id,firefighter_id,delivered_at,size_snapshot,brand_snapshot,notes)
    values(v_unit.id,v_source.firefighter_id,p_delivered_on::timestamptz,nullif(trim(p_size),''),nullif(trim(p_brand),''),nullif(trim(p_notes),''))
    returning id into v_assignment_id;
  insert into public.legacy_unit_links(legacy_import_row_id,equipment_unit_id,assignment_id)
    values(p_legacy_row_id,v_unit.id,v_assignment_id);
  if v_unit_created then
    insert into public.movements(equipment_unit_id,firefighter_id,movement_type,details,notes)
      values(v_unit.id,v_source.firefighter_id,'registered',jsonb_build_object('origin','legacy_row','legacy_import_row_id',p_legacy_row_id,'unit_code',v_unit.unit_code),nullif(trim(p_notes),''));
  end if;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v_unit.id,v_assignment_id,v_source.firefighter_id,'assigned',
      jsonb_build_object('origin','legacy_row','legacy_import_row_id',p_legacy_row_id,'unit_created',v_unit_created,
        'ownership',v_ownership,'delivered_on',p_delivered_on,
        'unit_details_before',case when v_unit_created then null else jsonb_build_object('brand',v_unit.brand,'size',v_unit.size) end,
        'unit_details_after',jsonb_build_object('brand',nullif(trim(p_brand),''),'size',nullif(trim(p_size),''))),nullif(trim(p_notes),''));
  return jsonb_build_object('legacy_import_row_id',p_legacy_row_id,'equipment_unit_id',v_unit.id,
    'assignment_id',v_assignment_id,'unit_code',v_unit.unit_code,'ownership',v_ownership,'already_linked',false);
end $$;
revoke all on function public.reconcile_legacy_item(uuid,uuid,text,text,text,text,text,date,text,boolean) from public, anon;
grant execute on function public.reconcile_legacy_item(uuid,uuid,text,text,text,text,text,date,text,boolean) to authenticated;

commit;
