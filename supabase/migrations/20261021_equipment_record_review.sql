-- Additive, auditable editing and custody review for source rows and physical assignments.
-- This migration does not rewrite or delete existing source rows or inventory records.
begin;

create table if not exists public.legacy_row_reviews (
  id uuid primary key default gen_random_uuid(),
  legacy_import_row_id uuid not null unique references public.legacy_import_rows(id) on delete restrict,
  corrected_data jsonb not null default '{}'::jsonb check (jsonb_typeof(corrected_data) = 'object'),
  custody_status text not null default 'unchanged'
    check (custody_status in ('unchanged','no_longer_with_firefighter')),
  notes text,
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now()
);

create table if not exists public.legacy_row_review_events (
  id uuid primary key default gen_random_uuid(),
  legacy_import_row_id uuid not null references public.legacy_import_rows(id) on delete restrict,
  event_type text not null check (event_type in ('correction_saved','custody_reviewed')),
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  notes text,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists legacy_row_review_events_row_idx
  on public.legacy_row_review_events(legacy_import_row_id, created_at desc);

alter table public.legacy_row_reviews enable row level security;
alter table public.legacy_row_review_events enable row level security;
drop policy if exists "authorized users read legacy row reviews" on public.legacy_row_reviews;
create policy "authorized users read legacy row reviews" on public.legacy_row_reviews
  for select to authenticated using (public.is_authorized_user());
drop policy if exists "authorized users read legacy row review events" on public.legacy_row_review_events;
create policy "authorized users read legacy row review events" on public.legacy_row_review_events
  for select to authenticated using (public.is_authorized_user());
revoke all on public.legacy_row_reviews from anon, authenticated;
revoke all on public.legacy_row_review_events from anon, authenticated;
grant select on public.legacy_row_reviews, public.legacy_row_review_events to authenticated;

create or replace function public.review_legacy_import_row(
  p_legacy_row_id uuid,
  p_corrected_data jsonb,
  p_custody_status text,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_source public.legacy_import_rows%rowtype;
  v_before jsonb := '{}'::jsonb;
  v_after jsonb;
  v_type text;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para revisar fichas.'; end if;
  if p_corrected_data is null or jsonb_typeof(p_corrected_data) <> 'object' then
    raise exception 'Las correcciones deben ser un objeto JSON válido.';
  end if;
  if p_custody_status is null or p_custody_status not in ('unchanged','no_longer_with_firefighter') then
    raise exception 'La situación de custodia no es válida.';
  end if;
  if p_custody_status='no_longer_with_firefighter' and nullif(trim(p_notes),'') is null then
    raise exception 'Indicá el motivo o contexto de la situación de custodia.';
  end if;
  if length(coalesce(p_notes,'')) > 2000 then raise exception 'Las observaciones no pueden superar 2000 caracteres.'; end if;
  select * into v_source from public.legacy_import_rows where id = p_legacy_row_id for update;
  if not found then raise exception 'La fila original no existe.'; end if;
  if v_source.source_sheet not like 'Ficha individual · %' then
    raise exception 'Solo se pueden revisar fichas individuales; los resúmenes originales están protegidos.';
  end if;
  select jsonb_build_object('corrected_data',corrected_data,'custody_status',custody_status,'notes',notes)
    into v_before from public.legacy_row_reviews where legacy_import_row_id = p_legacy_row_id for update;
  v_before := coalesce(v_before, '{}'::jsonb);
  insert into public.legacy_row_reviews(legacy_import_row_id,corrected_data,custody_status,notes,updated_by,updated_at)
    values(p_legacy_row_id,p_corrected_data,p_custody_status,nullif(trim(p_notes),''),auth.uid(),now())
    on conflict(legacy_import_row_id) do update set
      corrected_data=excluded.corrected_data,
      custody_status=excluded.custody_status,
      notes=excluded.notes,
      updated_by=auth.uid(),
      updated_at=now();
  v_after := jsonb_build_object('corrected_data',p_corrected_data,'custody_status',p_custody_status,'notes',nullif(trim(p_notes),''));
  v_type := case when (v_before->>'custody_status') is distinct from p_custody_status
    then 'custody_reviewed' else 'correction_saved' end;
  insert into public.legacy_row_review_events(legacy_import_row_id,event_type,before_data,after_data,notes,actor_id)
    values(p_legacy_row_id,v_type,v_before,v_after,nullif(trim(p_notes),''),auth.uid());
  return jsonb_build_object('legacy_import_row_id',p_legacy_row_id,'custody_status',p_custody_status,'updated_at',now());
end $$;
revoke all on function public.review_legacy_import_row(uuid,jsonb,text,text) from public, anon;
grant execute on function public.review_legacy_import_row(uuid,jsonb,text,text) to authenticated;

-- A pending custody review closes the assignment to the firefighter but reserves the
-- physical unit from being assigned again until its location is confirmed.
alter table public.assignments drop constraint if exists assignments_status_check;
alter table public.assignments add constraint assignments_status_check
  check (status in ('active','returned','lost','pending_review','retired'));
alter table public.assignments drop constraint if exists assignments_check;
alter table public.assignments drop constraint if exists assignments_return_time_check;
alter table public.assignments add constraint assignments_return_time_check
  check ((status = 'active' and returned_at is null) or (status <> 'active' and returned_at is not null));
create unique index if not exists one_unresolved_assignment_per_unit
  on public.assignments(equipment_unit_id) where status in ('active','pending_review');

create or replace function public.update_equipment_assignment(
  p_assignment_id uuid,
  p_delivered_at date,
  p_brand text,
  p_size text,
  p_notes text
) returns void
language plpgsql security definer set search_path = public as $$
declare v public.assignments%rowtype; v_type_name text; v_unit_id uuid;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para editar asignaciones.'; end if;
  if p_delivered_at is null then raise exception 'La fecha de entrega es obligatoria.'; end if;
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
  select name into v_type_name from public.equipment_types t join public.equipment_units u on u.equipment_type_id=t.id where u.id=v.equipment_unit_id;
  update public.assignments set delivered_at=p_delivered_at::timestamptz,
    brand_snapshot=nullif(trim(p_brand),''), size_snapshot=nullif(trim(p_size),''), notes=nullif(trim(p_notes),'')
    where id=v.id;
  update public.equipment_units set brand=nullif(trim(p_brand),''), size=nullif(trim(p_size),'') where id=v.equipment_unit_id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v.equipment_unit_id,v.id,v.firefighter_id,'edited',
      jsonb_build_object('record_type','assignment','element',v_type_name,
        'before',jsonb_build_object('delivered_at',v.delivered_at,'brand',v.brand_snapshot,'size',v.size_snapshot,'notes',v.notes),
        'after',jsonb_build_object('delivered_at',p_delivered_at,'brand',nullif(trim(p_brand),''),'size',nullif(trim(p_size),''),'notes',nullif(trim(p_notes),''))),
      nullif(trim(p_notes),''));
end $$;
revoke all on function public.update_equipment_assignment(uuid,date,text,text,text) from public, anon;
grant execute on function public.update_equipment_assignment(uuid,date,text,text,text) to authenticated;

create or replace function public.resolve_equipment_assignment(
  p_assignment_id uuid,
  p_resolution text,
  p_notes text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v public.assignments%rowtype; v_unit_id uuid;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para actualizar asignaciones.'; end if;
  if p_resolution is null or p_resolution not in ('returned','pending_review') then raise exception 'Elegí devolución al cuartel o ubicación pendiente de revisión.'; end if;
  if p_resolution='pending_review' and nullif(trim(p_notes),'') is null then raise exception 'Dejá una observación para la ubicación pendiente.'; end if;
  if length(coalesce(p_notes,'')) > 2000 then raise exception 'Las observaciones no pueden superar 2000 caracteres.'; end if;
  select equipment_unit_id into v_unit_id from public.assignments where id=p_assignment_id;
  if not found then raise exception 'La asignación ya fue cerrada o no existe.'; end if;
  perform 1 from public.equipment_units where id=v_unit_id and ownership='station' for update;
  if not found then raise exception 'La asignación no corresponde a una unidad del cuartel.'; end if;
  select * into v from public.assignments where id=p_assignment_id for update;
  if not found or v.status <> 'active' then raise exception 'La asignación ya fue cerrada o no existe.'; end if;
  update public.assignments set status=p_resolution,returned_at=now(),notes=concat_ws(E'\n',notes,nullif(trim(p_notes),'')) where id=v.id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v.equipment_unit_id,v.id,v.firefighter_id,
      case when p_resolution='returned' then 'returned' else 'pending_review' end,
      jsonb_build_object('resolution',p_resolution,'previous_status',v.status,'resolved_at',now()),nullif(trim(p_notes),''));
end $$;
revoke all on function public.resolve_equipment_assignment(uuid,text,text) from public, anon;
grant execute on function public.resolve_equipment_assignment(uuid,text,text) to authenticated;

create or replace function public.resolve_pending_assignment(
  p_assignment_id uuid,
  p_resolution text,
  p_notes text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v public.assignments%rowtype; v_unit_id uuid;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para resolver asignaciones.'; end if;
  if p_resolution is null or p_resolution not in ('returned','lost','retired') then raise exception 'La resolución no es válida.'; end if;
  if nullif(trim(p_notes),'') is null then raise exception 'Indicá el motivo de la resolución.'; end if;
  if length(coalesce(p_notes,'')) > 2000 then raise exception 'Las observaciones no pueden superar 2000 caracteres.'; end if;
  select equipment_unit_id into v_unit_id from public.assignments where id=p_assignment_id;
  if not found then raise exception 'La asignación no está pendiente de revisión.'; end if;
  perform 1 from public.equipment_units where id=v_unit_id and ownership='station' for update;
  if not found then raise exception 'La asignación no corresponde a una unidad del cuartel.'; end if;
  select * into v from public.assignments where id=p_assignment_id for update;
  if not found or v.status <> 'pending_review' then raise exception 'La asignación no está pendiente de revisión.'; end if;
  update public.assignments set status=p_resolution,returned_at=now(),notes=concat_ws(E'\n',notes,nullif(trim(p_notes),'')) where id=v.id;
  if p_resolution in ('lost','retired') then
    update public.equipment_units set lifecycle=p_resolution where id=v.equipment_unit_id and lifecycle='active';
    if not found then raise exception 'La unidad ya no está activa en el inventario.'; end if;
  end if;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(v.equipment_unit_id,v.id,v.firefighter_id,p_resolution,
      jsonb_build_object('resolution',p_resolution,'previous_status','pending_review','resolved_at',now()),nullif(trim(p_notes),''));
end $$;
revoke all on function public.resolve_pending_assignment(uuid,text,text) from public, anon;
grant execute on function public.resolve_pending_assignment(uuid,text,text) to authenticated;

create or replace function public.update_equipment_unit(
  p_unit_id uuid,
  p_brand text,
  p_size text,
  p_condition text,
  p_notes text
) returns void
language plpgsql security definer set search_path = public as $$
declare v public.equipment_units%rowtype;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para editar unidades.'; end if;
  if p_condition is null or p_condition not in ('good','regular','bad','out_of_service','review') then raise exception 'El estado de conservación no es válido.'; end if;
  if length(coalesce(p_brand,''))>200 or length(coalesce(p_size,''))>100 or length(coalesce(p_notes,''))>2000 then
    raise exception 'Revisá la longitud de marca, talle u observaciones.';
  end if;
  select * into v from public.equipment_units where id=p_unit_id and ownership='station' for update;
  if not found then raise exception 'La unidad física no existe.'; end if;
  if v.lifecycle <> 'active' then raise exception 'Solo se pueden editar unidades activas.'; end if;
  update public.equipment_units set brand=nullif(trim(p_brand),''),size=nullif(trim(p_size),''),condition=p_condition,notes=nullif(trim(p_notes),'') where id=v.id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    select v.id,a.id,a.firefighter_id,'edited',
      jsonb_build_object('record_type','equipment_unit',
        'before',jsonb_build_object('brand',v.brand,'size',v.size,'condition',v.condition,'notes',v.notes),
        'after',jsonb_build_object('brand',nullif(trim(p_brand),''),'size',nullif(trim(p_size),''),'condition',p_condition,'notes',nullif(trim(p_notes),''))),
      nullif(trim(p_notes),'' )
    from (select id,firefighter_id from public.assignments where equipment_unit_id=v.id and status in ('active','pending_review') order by created_at desc limit 1) a;
  if not found then
    insert into public.movements(equipment_unit_id,movement_type,details,notes)
      values(v.id,'edited',jsonb_build_object('record_type','equipment_unit',
        'before',jsonb_build_object('brand',v.brand,'size',v.size,'condition',v.condition,'notes',v.notes),
        'after',jsonb_build_object('brand',nullif(trim(p_brand),''),'size',nullif(trim(p_size),''),'condition',p_condition,'notes',nullif(trim(p_notes),''))),nullif(trim(p_notes),''));
  end if;
end $$;
revoke all on function public.update_equipment_unit(uuid,text,text,text,text) from public, anon;
grant execute on function public.update_equipment_unit(uuid,text,text,text,text) to authenticated;

create or replace function public.retire_unit(p_unit_id uuid,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_assignment public.assignments%rowtype; v_unit public.equipment_units%rowtype; v_has_assignment boolean := false;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para dar de baja unidades.'; end if;
  if nullif(trim(p_notes),'') is null then raise exception 'Indicá el motivo de la baja.'; end if;
  if length(p_notes) > 2000 then raise exception 'El motivo no puede superar 2000 caracteres.'; end if;
  select * into v_unit from public.equipment_units where id=p_unit_id for update;
  if not found or v_unit.ownership<>'station' or v_unit.lifecycle<>'active' then raise exception 'La unidad no existe, no pertenece al cuartel o ya está fuera del inventario activo.'; end if;
  select * into v_assignment from public.assignments where equipment_unit_id=p_unit_id and status='pending_review' for update;
  if found then raise exception 'Resolvé primero la ubicación pendiente de la unidad.'; end if;
  select * into v_assignment from public.assignments where equipment_unit_id=p_unit_id and status='active' for update;
  v_has_assignment := found;
  update public.equipment_units set lifecycle='retired' where id=p_unit_id and lifecycle='active';
  if not found then raise exception 'La unidad no existe o ya fue dada de baja.'; end if;
  if v_has_assignment then
    update public.assignments set status='retired',returned_at=now(),notes=concat_ws(E'\n',notes,nullif(trim(p_notes),'')) where id=v_assignment.id;
  end if;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
    values(p_unit_id,case when v_has_assignment then v_assignment.id else null end,
      case when v_has_assignment then v_assignment.firefighter_id else null end,'retired',
      jsonb_build_object('reason',trim(p_notes),'closed_assignment',v_has_assignment,'retired_at',now()),trim(p_notes));
end $$;
revoke all on function public.retire_unit(uuid,text) from public, anon;
grant execute on function public.retire_unit(uuid,text) to authenticated;

create or replace function public.assign_unit(p_unit_id uuid,p_firefighter_id uuid,p_delivered_at date default current_date,p_size text default null,p_brand text default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_assignment uuid; v_active boolean;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para asignar unidades.'; end if;
  if p_delivered_at is null or length(coalesce(p_size,''))>100 or length(coalesce(p_brand,''))>200 or length(coalesce(p_notes,''))>2000 then
    raise exception 'Revisá la fecha, el talle, la marca y las observaciones.';
  end if;
  select active into v_active from public.firefighters where id=p_firefighter_id for update;
  if not found or not v_active then raise exception 'El bombero no existe o no está activo.'; end if;
  perform 1 from public.equipment_units where id=p_unit_id and ownership='station' and lifecycle='active' and condition <> 'out_of_service' for update;
  if not found then raise exception 'La unidad no pertenece al cuartel, está fuera de servicio o no está disponible.'; end if;
  if exists(select 1 from public.assignments where equipment_unit_id=p_unit_id and status in ('active','pending_review')) then
    raise exception 'La unidad ya está asignada o pendiente de revisión.';
  end if;
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
  -- Lock every candidate in a stable order before checking stock. Concurrent assignments
  -- then wait and re-evaluate availability; duplicate component types are aggregated.
  perform u.id from public.equipment_units u
    where u.equipment_type_id in (select equipment_type_id from public.uniform_components where uniform_id=p_uniform_id)
      and u.ownership='station' and u.lifecycle='active' and u.condition<>'out_of_service'
      and not exists(select 1 from public.assignments a where a.equipment_unit_id=u.id and a.status in ('active','pending_review'))
    order by u.id for update;
  for component in select equipment_type_id,sum(quantity)::integer as quantity from public.uniform_components where uniform_id=p_uniform_id group by equipment_type_id loop
    v_required:=v_required+component.quantity;
    if (select count(*) from public.equipment_units u where u.equipment_type_id=component.equipment_type_id and u.ownership='station' and u.lifecycle='active' and u.condition<>'out_of_service' and not exists(select 1 from public.assignments a where a.equipment_unit_id=u.id and a.status in ('active','pending_review'))) < component.quantity then
      raise exception 'No hay unidades disponibles suficientes para todos los componentes; no se realizó la asignación.';
    end if;
  end loop;
  for component in select equipment_type_id,sum(quantity)::integer as quantity from public.uniform_components where uniform_id=p_uniform_id group by equipment_type_id loop
    for unit_row in select u.id,u.size,u.brand from public.equipment_units u where u.equipment_type_id=component.equipment_type_id and u.ownership='station' and u.lifecycle='active' and u.condition<>'out_of_service' and not exists(select 1 from public.assignments a where a.equipment_unit_id=u.id and a.status in ('active','pending_review')) order by u.created_at,u.id limit component.quantity for update loop
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

-- Guard the legacy convenience RPCs too: ownership, state change, audit event and
-- physical-unit lifecycle must be committed together under the same unit lock.
create or replace function public.return_unit(p_assignment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.assignments%rowtype;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para devolver unidades.'; end if;
  select a.* into v from public.assignments a join public.equipment_units u on u.id=a.equipment_unit_id
    where a.id=p_assignment_id and u.ownership='station' for update of u;
  if not found then raise exception 'La asignación no existe o no corresponde a una unidad del cuartel.'; end if;
  select * into v from public.assignments where id=p_assignment_id for update;
  if v.status<>'active' then raise exception 'La asignación ya fue cerrada o no existe.'; end if;
  update public.assignments set status='returned',returned_at=now() where id=v.id;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details)
    values(v.equipment_unit_id,v.id,v.firefighter_id,'returned',jsonb_build_object('returned_at',now()));
end $$;
revoke all on function public.return_unit(uuid) from public, anon;
grant execute on function public.return_unit(uuid) to authenticated;

create or replace function public.report_lost_unit(p_assignment_id uuid,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.assignments%rowtype;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para registrar pérdidas.'; end if;
  if length(coalesce(p_notes,''))>2000 then raise exception 'Las observaciones no pueden superar 2000 caracteres.'; end if;
  select a.* into v from public.assignments a join public.equipment_units u on u.id=a.equipment_unit_id
    where a.id=p_assignment_id and u.ownership='station' for update of u;
  if not found then raise exception 'La asignación no existe o no corresponde a una unidad del cuartel.'; end if;
  select * into v from public.assignments where id=p_assignment_id for update;
  if v.status<>'active' then raise exception 'La asignación ya fue cerrada o no existe.'; end if;
  update public.assignments set status='lost',returned_at=now(),notes=concat_ws(E'\n',notes,nullif(trim(p_notes),'')) where id=v.id;
  update public.equipment_units set lifecycle='lost' where id=v.equipment_unit_id and lifecycle='active';
  if not found then raise exception 'La unidad ya no forma parte del inventario activo.'; end if;
  insert into public.movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,notes)
    values(v.equipment_unit_id,v.id,v.firefighter_id,'lost',nullif(trim(p_notes),''));
end $$;
revoke all on function public.report_lost_unit(uuid,text) from public, anon;
grant execute on function public.report_lost_unit(uuid,text) to authenticated;

alter table public.movements drop constraint if exists movements_movement_type_check;
alter table public.movements add constraint movements_movement_type_check
  check (movement_type in ('registered','assigned','returned','lost','retired','condition_changed','edited','imported','pending_review'));

-- Keep source workbook rows append-only. Corrections live in the review tables above;
-- imports are atomic and may add missing rows but can never replace original cells.
drop policy if exists "auth users manage legacy imports" on public.legacy_import_rows;
drop policy if exists "authorized users read legacy rows" on public.legacy_import_rows;
create policy "authorized users read legacy rows" on public.legacy_import_rows
  for select to authenticated using (public.is_authorized_user());
revoke all on public.legacy_import_rows from public, anon, authenticated;
grant select on public.legacy_import_rows to authenticated;

create or replace function public.import_individual_legacy_rows(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb;
  v_key text;
  v_sheet text;
  v_source_row integer;
  v_firefighter_id uuid;
  v_raw jsonb;
  v_keys text[] := array[]::text[];
  v_inserted integer := 0;
  v_existing integer := 0;
  v_saved integer;
  v_people integer;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para importar fichas.'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) not between 1 and 10000 then
    raise exception 'El archivo no contiene un conjunto válido de filas individuales.';
  end if;
  select count(distinct value->>'firefighter_id') into v_people from jsonb_array_elements(p_rows);
  if v_people <> 22 then raise exception 'La importación debe corresponder a las 22 personas activas validadas.'; end if;

  -- Validate the entire batch, including any pre-existing source key, before writing.
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_key := nullif(trim(v_row->>'source_key'),'');
    v_sheet := v_row->>'source_sheet';
    v_source_row := nullif(v_row->>'source_row','')::integer;
    v_firefighter_id := nullif(v_row->>'firefighter_id','')::uuid;
    v_raw := v_row->'raw_data';
    if v_key is null or v_sheet is null or v_sheet not like 'Ficha individual · %' or v_source_row is null or v_source_row < 1
       or v_firefighter_id is null or v_raw is null or jsonb_typeof(v_raw) <> 'object' then
      raise exception 'Una fila no tiene identificadores y datos originales válidos.';
    end if;
    if v_key = any(v_keys) then raise exception 'El archivo contiene claves de origen duplicadas: %.',v_key; end if;
    v_keys := array_append(v_keys,v_key);
    if not exists(select 1 from public.firefighters f where f.id=v_firefighter_id and f.active) then
      raise exception 'Una fila no está vinculada a un bombero activo existente.';
    end if;
    if exists(select 1 from public.legacy_import_rows r where r.source_key=v_key and
      (r.source_sheet is distinct from v_sheet or r.source_row is distinct from v_source_row or
       r.firefighter_id is distinct from v_firefighter_id or r.raw_data is distinct from v_raw)) then
      raise exception 'La clave % ya existe con datos distintos. No se modificó ninguna fila.',v_key;
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    insert into public.legacy_import_rows(source_key,source_sheet,source_row,firefighter_id,raw_data)
    values(v_row->>'source_key',v_row->>'source_sheet',(v_row->>'source_row')::integer,
      (v_row->>'firefighter_id')::uuid,v_row->'raw_data')
    on conflict(source_key) do nothing;
    get diagnostics v_saved = row_count;
    v_inserted := v_inserted + v_saved;
  end loop;

  -- A concurrent importer may have won a source-key race; verify its values before commit.
  for v_row in select value from jsonb_array_elements(p_rows) loop
    if not exists(select 1 from public.legacy_import_rows r where r.source_key=v_row->>'source_key'
      and r.source_sheet=v_row->>'source_sheet' and r.source_row=(v_row->>'source_row')::integer
      and r.firefighter_id=(v_row->>'firefighter_id')::uuid and r.raw_data=v_row->'raw_data') then
      raise exception 'La verificación posterior detectó una fila fuente distinta. Se revirtió este lote.';
    end if;
  end loop;
  v_existing := jsonb_array_length(p_rows) - v_inserted;
  return jsonb_build_object('inserted',v_inserted,'already_present',v_existing,'verified',jsonb_array_length(p_rows));
end $$;
revoke all on function public.import_individual_legacy_rows(jsonb) from public, anon;
grant execute on function public.import_individual_legacy_rows(jsonb) to authenticated;

-- The older two-summary import RPC remains available for compatibility, but is append-only.
create or replace function public.import_legacy_data(p_people jsonb,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare person jsonb; source_row jsonb; v_person_id uuid; v_no text; v_name text; v_inserted integer := 0; v_saved integer;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if jsonb_typeof(p_people) <> 'array' or jsonb_typeof(p_rows) <> 'array'
     or jsonb_array_length(p_people) <> 22 or jsonb_array_length(p_rows) <> 44 then
    raise exception 'Se requieren 22 personas y 44 filas originales.';
  end if;
  for person in select value from jsonb_array_elements(p_people) loop
    v_no:=nullif(trim(person->>'personnel_no'),''); v_name:=nullif(trim(person->>'full_name'),'');
    if v_no is null or v_name is null then raise exception 'Cada persona debe tener legajo y nombre.'; end if;
    insert into public.firefighters(personnel_no,full_name,rank,active,notes)
      values(v_no,v_name,null,true,'Importado desde CSV; cargo no identificado automáticamente.')
      on conflict(personnel_no) do nothing;
  end loop;
  for source_row in select value from jsonb_array_elements(p_rows) loop
    v_no:=nullif(trim(source_row->>'personnel_no'),'');
    select id into v_person_id from public.firefighters where personnel_no=v_no and active;
    if v_person_id is null then raise exception 'No existe el legajo activo % del registro original.',v_no; end if;
    insert into public.legacy_import_rows(source_key,source_sheet,source_row,firefighter_id,raw_data)
      values(source_row->>'source_key',source_row->>'source_sheet',(source_row->>'source_row')::integer,v_person_id,source_row->'raw_data')
      on conflict(source_key) do nothing;
    get diagnostics v_saved = row_count;
    v_inserted := v_inserted + v_saved;
  end loop;
  return jsonb_build_object('people_processed',jsonb_array_length(p_people),'source_rows_saved',v_inserted,
    'source_rows_already_present',jsonb_array_length(p_rows)-v_inserted);
end $$;
revoke all on function public.import_legacy_data(jsonb,jsonb) from public, anon;
grant execute on function public.import_legacy_data(jsonb,jsonb) to authenticated;

-- Reads remain available through RLS. Every write goes through an authorized RPC,
-- keeping the unit, assignment, movement, and template changes in one transaction.
drop policy if exists "auth users manage firefighters" on public.firefighters;
drop policy if exists "authorized users read firefighters" on public.firefighters;
create policy "authorized users read firefighters" on public.firefighters
  for select to authenticated using (public.is_authorized_user());
drop policy if exists "auth users manage equipment types" on public.equipment_types;
drop policy if exists "authorized users read equipment types" on public.equipment_types;
create policy "authorized users read equipment types" on public.equipment_types
  for select to authenticated using (public.is_authorized_user());
drop policy if exists "auth users manage units" on public.equipment_units;
drop policy if exists "authorized users read units" on public.equipment_units;
create policy "authorized users read units" on public.equipment_units
  for select to authenticated using (public.is_authorized_user());
drop policy if exists "auth users manage uniforms" on public.uniforms;
drop policy if exists "authorized users read uniforms" on public.uniforms;
create policy "authorized users read uniforms" on public.uniforms
  for select to authenticated using (public.is_authorized_user());
drop policy if exists "auth users manage uniform components" on public.uniform_components;
drop policy if exists "authorized users read uniform components" on public.uniform_components;
create policy "authorized users read uniform components" on public.uniform_components
  for select to authenticated using (public.is_authorized_user());

revoke all on public.firefighters, public.equipment_types, public.equipment_units,
  public.assignments, public.uniforms, public.uniform_components, public.movements from public, anon, authenticated;
grant select on public.firefighters, public.equipment_types, public.equipment_units,
  public.assignments, public.uniforms, public.uniform_components, public.movements to authenticated;
revoke all on public.authorized_users from public, anon, authenticated;
grant select on public.authorized_users to authenticated;

create or replace function public.create_firefighter(p_full_name text,p_personnel_no text,p_rank text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para registrar bomberos.'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'El nombre del bombero es obligatorio.'; end if;
  if length(p_full_name)>200 or length(coalesce(p_personnel_no,''))>40 or length(coalesce(p_rank,''))>100 then
    raise exception 'Revisá la longitud de nombre, legajo o cargo.';
  end if;
  insert into public.firefighters(full_name,personnel_no,rank,active)
    values(trim(p_full_name),nullif(trim(p_personnel_no),''),nullif(trim(p_rank),''),true) returning id into v_id;
  insert into public.movements(firefighter_id,movement_type,details)
    values(v_id,'registered',jsonb_build_object('record_type','firefighter','personnel_no',nullif(trim(p_personnel_no),'')));
  return v_id;
exception when unique_violation then raise exception 'Ya existe un bombero con ese legajo.';
end $$;
revoke all on function public.create_firefighter(text,text,text) from public, anon;
grant execute on function public.create_firefighter(text,text,text) to authenticated;

-- Guarded condition update used by the inventory view; it cannot alter personal,
-- retired, or lost equipment, and the audit row is committed with the change.
create or replace function public.set_unit_condition(p_unit_id uuid,p_condition text,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.equipment_units%rowtype; v_firefighter uuid;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para editar unidades.'; end if;
  if p_condition is null or p_condition not in ('good','regular','bad','out_of_service','review') then raise exception 'Estado inválido.'; end if;
  if length(coalesce(p_notes,''))>2000 then raise exception 'Las observaciones no pueden superar 2000 caracteres.'; end if;
  select * into v from public.equipment_units where id=p_unit_id and ownership='station' and lifecycle='active' for update;
  if not found then raise exception 'La unidad no existe o ya no pertenece al inventario activo del cuartel.'; end if;
  select firefighter_id into v_firefighter from public.assignments where equipment_unit_id=v.id and status in ('active','pending_review') order by created_at desc limit 1;
  update public.equipment_units set condition=p_condition where id=v.id;
  insert into public.movements(equipment_unit_id,firefighter_id,movement_type,details,notes)
    values(v.id,v_firefighter,'condition_changed',jsonb_build_object('before',v.condition,'after',p_condition),nullif(trim(p_notes),''));
end $$;
revoke all on function public.set_unit_condition(uuid,text,text) from public, anon;
grant execute on function public.set_unit_condition(uuid,text,text) to authenticated;

commit;
