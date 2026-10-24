-- One-time, idempotent reconciliation of source rows into physical inventory.
-- Source rows and summary rows remain untouched. Every change is made through an
-- authorized SECURITY DEFINER function and is committed atomically per RPC call.
begin;

-- The original sheets do not provide a reliable delivery date. NULL means unknown;
-- never substitute the import date for the actual historical handover date.
alter table public.assignments alter column delivered_at drop not null;

-- A source row can describe more than one physical unit (the workbook has 17
-- Overol rows with quantity 2). Keep the existing primary link and store additional
-- units here, preserving the original row as the shared provenance.
create table if not exists public.legacy_unit_link_extras (
  legacy_import_row_id uuid not null references public.legacy_import_rows(id) on delete restrict,
  equipment_unit_id uuid not null unique references public.equipment_units(id) on delete restrict,
  assignment_id uuid not null unique references public.assignments(id) on delete restrict,
  slot integer not null check (slot >= 2),
  confirmed_by uuid references auth.users(id) on delete set null default auth.uid(),
  confirmed_at timestamptz not null default now(),
  primary key (legacy_import_row_id, slot)
);
alter table public.legacy_unit_link_extras enable row level security;
drop policy if exists "authorized users read legacy unit link extras" on public.legacy_unit_link_extras;
create policy "authorized users read legacy unit link extras" on public.legacy_unit_link_extras
  for select to authenticated using (public.is_authorized_user());
revoke all on public.legacy_unit_link_extras from public, anon, authenticated;
grant select on public.legacy_unit_link_extras to authenticated;

-- Replace the one-row reconciliation RPC so unknown historical dates remain NULL
-- and blank optional fields never erase values on an existing unit.
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
  if exists(select 1 from public.legacy_row_reviews where legacy_import_row_id=p_legacy_row_id and custody_status='no_longer_with_firefighter') then
    raise exception 'La ficha indica que el bombero ya no tiene este elemento; revisá su situación antes de vincularlo.';
  end if;
  select * into v_link from public.legacy_unit_links where legacy_import_row_id=p_legacy_row_id;
  if found then
    return jsonb_build_object('legacy_import_row_id',v_link.legacy_import_row_id,'equipment_unit_id',v_link.equipment_unit_id,
      'assignment_id',v_link.assignment_id,'already_linked',true);
  end if;
  if length(coalesce(p_brand,''))>200 or length(coalesce(p_size,''))>100 or length(coalesce(p_notes,''))>2000 then
    raise exception 'Revisá la longitud de marca, talle u observaciones.';
  end if;

  if p_existing_unit_id is not null then
    select * into v_unit from public.equipment_units where id=p_existing_unit_id for update;
    if not found or v_unit.lifecycle<>'active' then raise exception 'La unidad física seleccionada no está activa.'; end if;
    if exists(select 1 from public.assignments where equipment_unit_id=v_unit.id and status in ('active','pending_review')) then
      raise exception 'La unidad física ya está asignada o pendiente de revisión.';
    end if;
    if v_unit.condition in ('out_of_service','review') then raise exception 'La unidad está fuera de servicio o pendiente de revisión.'; end if;
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

  if not v_unit_created and (p_brand is not null or p_size is not null) then
    update public.equipment_units set
      brand=coalesce(nullif(trim(p_brand),''),brand),
      size=coalesce(nullif(trim(p_size),''),size)
      where id=v_unit.id returning * into v_unit;
  end if;
  insert into public.assignments(equipment_unit_id,firefighter_id,delivered_at,size_snapshot,brand_snapshot,notes)
    values(v_unit.id,v_source.firefighter_id,p_delivered_on::timestamptz,
      coalesce(nullif(trim(p_size),''),v_unit.size),coalesce(nullif(trim(p_brand),''),v_unit.brand),nullif(trim(p_notes),''))
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
        'unit_details_after',jsonb_build_object('brand',v_unit.brand,'size',v_unit.size)),nullif(trim(p_notes),''));
  return jsonb_build_object('legacy_import_row_id',p_legacy_row_id,'equipment_unit_id',v_unit.id,
    'assignment_id',v_assignment_id,'unit_code',v_unit.unit_code,'ownership',v_ownership,'already_linked',false);
end $$;
revoke all on function public.reconcile_legacy_item(uuid,uuid,text,text,text,text,text,date,text,boolean) from public, anon;
grant execute on function public.reconcile_legacy_item(uuid,uuid,text,text,text,text,text,date,text,boolean) to authenticated;

-- Reconcile all named rows once. One unit is created per named source row. The
-- source explicitly records quantity 2 for 17 Overol rows (including split sizes);
-- those rows receive one additional physical unit each. Unknown states stay review,
-- dates stay NULL, all original fields stay in legacy_import_rows, and the 44 summary
-- rows are never selected. Rows without an identifiable element remain untouched.
create or replace function public.reconcile_all_legacy_equipment(p_confirmed boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_source public.legacy_import_rows%rowtype;
  v_result jsonb;
  v_item_name text;
  v_section text;
  v_type_name text;
  v_details text;
  v_quantity integer;
  v_unit_id uuid;
  v_assignment_id uuid;
  v_type_id uuid;
  v_extra_unit_id uuid;
  v_extra_assignment_id uuid;
  v_added_rows integer := 0;
  v_existing_rows integer := 0;
  v_extra_added integer := 0;
  v_extra_existing integer := 0;
  v_no_name integer := 0;
  v_no_longer integer := 0;
  v_source_count integer := 0;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para sincronizar el inventario histórico.'; end if;
  if p_confirmed is distinct from true then raise exception 'Confirmá la vista previa antes de crear unidades.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('legacy-equipment-initial-reconciliation',0));

  select count(*) into v_source_count from public.legacy_import_rows r
    join public.firefighters f on f.id=r.firefighter_id and f.active
    where r.source_sheet like 'Ficha individual · %';

  for v_source in
    select r.* from public.legacy_import_rows r
    join public.firefighters f on f.id=r.firefighter_id and f.active
    where r.source_sheet like 'Ficha individual · %'
    order by r.firefighter_id,r.source_row
    for update of r
  loop
    v_item_name:=coalesce(
      nullif(trim(v_source.raw_data->>'Elemento'),''),
      nullif(trim(v_source.raw_data->>'Prenda'),''),
      nullif(trim(v_source.raw_data->>'Componente'),''),
      nullif(trim(v_source.raw_data->>'Articulo'),''),
      nullif(trim(v_source.raw_data->>'Artículo'),''),
      nullif(trim(v_source.raw_data->>'HANDY'),'')
    );
    if v_item_name is null then v_no_name:=v_no_name+1; continue; end if;
    if exists(select 1 from public.legacy_row_reviews rv where rv.legacy_import_row_id=v_source.id and rv.custody_status='no_longer_with_firefighter') then
      v_no_longer:=v_no_longer+1; continue;
    end if;
    v_section:=coalesce(nullif(trim(v_source.raw_data->>'_section'),''),'Equipamiento operativo');
    v_type_name:=case
      when v_section='Traje de gala' then 'Gala · '||v_item_name
      when v_section='Traje de fajina' then 'Fajina · '||v_item_name
      when lower(v_section)='handy' then 'Handy · '||v_item_name
      else v_item_name end;
    v_details:=coalesce(v_source.raw_data->>'Detalles',v_source.raw_data->>'Columna 3','');
    v_quantity:=1;
    if lower(trim(v_item_name))='overol' and (
      v_details ~* '^\s*2(\s|$|\(|\.)' or v_details ~* '\mT\.?\s*[A-Z0-9]+\s+y\s+(T\.?\s*)?[A-Z0-9]+\M'
    ) then v_quantity:=2; end if;

    v_result:=public.reconcile_legacy_item(v_source.id,null,v_type_name,'station','review',null,null,null,
      'Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.',true);
    if coalesce((v_result->>'already_linked')::boolean,false) then
      v_existing_rows:=v_existing_rows+1;
    else
      v_added_rows:=v_added_rows+1;
    end if;
    v_unit_id:=(v_result->>'equipment_unit_id')::uuid;
    v_assignment_id:=(v_result->>'assignment_id')::uuid;
    select equipment_type_id into v_type_id from public.equipment_units where id=v_unit_id;

    if v_quantity>1 then
      if exists(select 1 from public.legacy_unit_link_extras where legacy_import_row_id=v_source.id and slot=2) then
        v_extra_existing:=v_extra_existing+1;
      else
        insert into public.equipment_units(equipment_type_id,condition,ownership,lifecycle,notes)
          values(v_type_id,'review','station','active','Unidad adicional indicada por la cantidad original; conservación pendiente de revisión.')
          returning id into v_extra_unit_id;
        insert into public.assignments(equipment_unit_id,firefighter_id,delivered_at,notes)
          values(v_extra_unit_id,v_source.firefighter_id,null,'Asignada según cantidad de la ficha histórica; fecha original no consignada.')
          returning id into v_extra_assignment_id;
        insert into public.legacy_unit_link_extras(legacy_import_row_id,equipment_unit_id,assignment_id,slot)
          values(v_source.id,v_extra_unit_id,v_extra_assignment_id,2);
        insert into public.movements(equipment_unit_id,firefighter_id,movement_type,details,notes)
          values(v_extra_unit_id,v_source.firefighter_id,'registered',jsonb_build_object('origin','legacy_row','legacy_import_row_id',v_source.id,'slot',2),
            'Unidad adicional descrita en la fila original.');
        insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
          values(v_extra_unit_id,v_extra_assignment_id,v_source.firefighter_id,'assigned',
            jsonb_build_object('origin','legacy_row','legacy_import_row_id',v_source.id,'slot',2,'delivered_on',null),
            'Asignada según cantidad de la ficha histórica; fecha original no consignada.');
        v_extra_added:=v_extra_added+1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('source_rows',v_source_count,'named_rows_processed',v_added_rows+v_existing_rows,
    'primary_units_created',v_added_rows,'primary_rows_already_linked',v_existing_rows,
    'additional_units_created',v_extra_added,'additional_units_already_linked',v_extra_existing,
    'rows_without_element_name',v_no_name,'rows_marked_no_longer_with_firefighter',v_no_longer,
    'physical_units_created',v_added_rows+v_extra_added);
end $$;
revoke all on function public.reconcile_all_legacy_equipment(boolean) from public, anon;
grant execute on function public.reconcile_all_legacy_equipment(boolean) to authenticated;

-- Keep manual assignment paths from making review-state units available again.
create or replace function public.assign_unit(p_unit_id uuid,p_firefighter_id uuid,p_delivered_at date default current_date,p_size text default null,p_brand text default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_assignment uuid; v_active boolean;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para asignar unidades.'; end if;
  if p_delivered_at is null or length(coalesce(p_size,''))>100 or length(coalesce(p_brand,''))>200 or length(coalesce(p_notes,''))>2000 then raise exception 'Revisá la fecha, el talle, la marca y las observaciones.'; end if;
  select active into v_active from public.firefighters where id=p_firefighter_id for update;
  if not found or not v_active then raise exception 'El bombero no existe o no está activo.'; end if;
  perform 1 from public.equipment_units where id=p_unit_id and ownership='station' and lifecycle='active' and condition not in ('out_of_service','review') for update;
  if not found then raise exception 'La unidad no pertenece al cuartel, está fuera de servicio o pendiente de revisión.'; end if;
  if exists(select 1 from public.assignments where equipment_unit_id=p_unit_id and status in ('active','pending_review')) then raise exception 'La unidad ya está asignada o pendiente de revisión.'; end if;
  insert into public.assignments(equipment_unit_id,firefighter_id,delivered_at,size_snapshot,brand_snapshot,notes)
    values(p_unit_id,p_firefighter_id,p_delivered_at::timestamptz,nullif(trim(p_size),''),nullif(trim(p_brand),''),nullif(trim(p_notes),'')) returning id into v_assignment;
  update public.equipment_units set size=nullif(trim(p_size),''),brand=nullif(trim(p_brand),'') where id=p_unit_id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(p_unit_id,v_assignment,p_firefighter_id,'assigned',jsonb_build_object('delivered_at',p_delivered_at,'size',p_size,'brand',p_brand),nullif(trim(p_notes),''));
  return v_assignment;
exception when unique_violation then raise exception 'La unidad ya tiene una asignación activa o pendiente de revisión.';
end $$;
revoke all on function public.assign_unit(uuid,uuid,date,text,text,text) from public, anon;
grant execute on function public.assign_unit(uuid,uuid,date,text,text,text) to authenticated;

create or replace function public.assign_uniform(p_uniform_id uuid,p_firefighter_id uuid,p_delivered_at date default current_date,p_notes text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare component record; unit_row record; inserted integer:=0; v_required integer:=0;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para asignar uniformes.'; end if;
  if p_delivered_at is null or length(coalesce(p_notes,''))>2000 then raise exception 'Revisá la fecha y las observaciones.'; end if;
  perform 1 from public.firefighters where id=p_firefighter_id and active for update;
  if not found then raise exception 'El bombero no existe o no está activo.'; end if;
  if not exists(select 1 from public.uniforms where id=p_uniform_id and active) then raise exception 'La plantilla no existe o está inactiva.'; end if;
  if not exists(select 1 from public.uniform_components where uniform_id=p_uniform_id) then raise exception 'La plantilla no tiene componentes.'; end if;
  perform u.id from public.equipment_units u
    where u.equipment_type_id in (select equipment_type_id from public.uniform_components where uniform_id=p_uniform_id)
      and u.ownership='station' and u.lifecycle='active' and u.condition not in ('out_of_service','review')
      and not exists(select 1 from public.assignments a where a.equipment_unit_id=u.id and a.status in ('active','pending_review'))
    order by u.id for update;
  for component in select equipment_type_id,sum(quantity)::integer as quantity from public.uniform_components where uniform_id=p_uniform_id group by equipment_type_id loop
    v_required:=v_required+component.quantity;
    if (select count(*) from public.equipment_units u where u.equipment_type_id=component.equipment_type_id and u.ownership='station' and u.lifecycle='active' and u.condition not in ('out_of_service','review') and not exists(select 1 from public.assignments a where a.equipment_unit_id=u.id and a.status in ('active','pending_review'))) < component.quantity then
      raise exception 'No hay unidades disponibles suficientes para todos los componentes; no se realizó la asignación.';
    end if;
  end loop;
  for component in select equipment_type_id,sum(quantity)::integer as quantity from public.uniform_components where uniform_id=p_uniform_id group by equipment_type_id loop
    for unit_row in select u.id,u.size,u.brand from public.equipment_units u where u.equipment_type_id=component.equipment_type_id and u.ownership='station' and u.lifecycle='active' and u.condition not in ('out_of_service','review') and not exists(select 1 from public.assignments a where a.equipment_unit_id=u.id and a.status in ('active','pending_review')) order by u.created_at,u.id limit component.quantity for update loop
      perform public.assign_unit(unit_row.id,p_firefighter_id,p_delivered_at,unit_row.size,unit_row.brand,p_notes);
      inserted:=inserted+1;
    end loop;
  end loop;
  if inserted<>v_required then raise exception 'No se pudieron asignar todos los componentes de la plantilla.'; end if;
  insert into public.movements(firefighter_id,movement_type,details,notes) values(p_firefighter_id,'assigned',jsonb_build_object('uniform_id',p_uniform_id,'components_assigned',inserted),p_notes);
  return inserted;
end $$;
revoke all on function public.assign_uniform(uuid,uuid,date,text) from public, anon;
grant execute on function public.assign_uniform(uuid,uuid,date,text) to authenticated;

commit;
