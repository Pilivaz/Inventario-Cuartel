-- Cuartel · inventario y trazabilidad. Ejecutar una sola vez en Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.firefighters (
  id uuid primary key default gen_random_uuid(),
  personnel_no text unique,
  full_name text not null check (length(trim(full_name)) > 0),
  rank text,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.authorized_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'admin' check (role in ('admin','operator')),
  created_at timestamptz not null default now()
);
alter table public.authorized_users enable row level security;
insert into public.authorized_users(user_id,role)
select id,'admin' from auth.users where email_confirmed_at is not null
on conflict(user_id) do nothing;
create or replace function public.is_authorized_user()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.authorized_users where user_id=auth.uid())
$$;
grant execute on function public.is_authorized_user() to authenticated;

create table if not exists public.equipment_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.equipment_units (
  id uuid primary key default gen_random_uuid(),
  equipment_type_id uuid not null references public.equipment_types(id) on delete restrict,
  unit_code text not null unique default ('EQ-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  condition text not null default 'good' check (condition in ('good','regular','bad','out_of_service','review')),
  ownership text not null default 'station' check (ownership in ('station','firefighter','review')),
  owner_firefighter_id uuid references public.firefighters(id) on delete restrict,
  lifecycle text not null default 'active' check (lifecycle in ('active','lost','retired')),
  brand text,
  size text,
  notes text,
  created_at timestamptz not null default now(),
  check ((ownership = 'firefighter' and owner_firefighter_id is not null) or ownership <> 'firefighter')
);
create index if not exists equipment_units_type_idx on public.equipment_units(equipment_type_id);
create index if not exists equipment_units_stock_idx on public.equipment_units(ownership,lifecycle,condition);

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  equipment_unit_id uuid not null references public.equipment_units(id) on delete restrict,
  firefighter_id uuid not null references public.firefighters(id) on delete restrict,
  delivered_at timestamptz not null default now(),
  returned_at timestamptz,
  status text not null default 'active' check (status in ('active','returned','lost')),
  size_snapshot text,
  brand_snapshot text,
  notes text,
  recorded_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check ((status = 'active' and returned_at is null) or (status <> 'active' and returned_at is not null))
);
create unique index if not exists one_open_assignment_per_unit on public.assignments(equipment_unit_id) where status = 'active';
create index if not exists assignments_recent_idx on public.assignments(delivered_at desc);
create index if not exists assignments_person_idx on public.assignments(firefighter_id,delivered_at desc);

create table if not exists public.uniforms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.uniform_components (
  id uuid primary key default gen_random_uuid(),
  uniform_id uuid not null references public.uniforms(id) on delete cascade,
  equipment_type_id uuid not null references public.equipment_types(id) on delete restrict,
  quantity integer not null default 1 check (quantity > 0),
  position integer not null default 0,
  unique(uniform_id,equipment_type_id)
);

create table if not exists public.movements (
  id uuid primary key default gen_random_uuid(),
  equipment_unit_id uuid references public.equipment_units(id) on delete restrict,
  assignment_id uuid references public.assignments(id) on delete restrict,
  firefighter_id uuid references public.firefighters(id) on delete restrict,
  movement_type text not null check (movement_type in ('registered','assigned','returned','lost','retired','condition_changed','edited','imported')),
  details jsonb not null default '{}'::jsonb,
  notes text,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists movements_recent_idx on public.movements(created_at desc);

-- Conserva los CSV recibidos como referencia sin contabilizarlos como stock ni asignaciones verificadas.
create table if not exists public.legacy_import_rows (
  id uuid primary key default gen_random_uuid(),
  source_key text not null unique,
  source_sheet text not null,
  source_row integer not null,
  firefighter_id uuid references public.firefighters(id) on delete set null,
  raw_data jsonb not null,
  imported_at timestamptz not null default now()
);
create index if not exists legacy_rows_person_idx on public.legacy_import_rows(firefighter_id);

-- Existing confirmed accounts are allow-listed above. Disable public signups in Supabase Auth too.
alter table public.firefighters enable row level security;
alter table public.equipment_types enable row level security;
alter table public.equipment_units enable row level security;
alter table public.assignments enable row level security;
alter table public.uniforms enable row level security;
alter table public.uniform_components enable row level security;
alter table public.movements enable row level security;
alter table public.legacy_import_rows enable row level security;

drop policy if exists "users read own authorization" on public.authorized_users;
create policy "users read own authorization" on public.authorized_users for select to authenticated using (user_id = auth.uid());
drop policy if exists "auth users manage firefighters" on public.firefighters;
create policy "auth users manage firefighters" on public.firefighters for all to authenticated using (public.is_authorized_user()) with check (public.is_authorized_user());
drop policy if exists "auth users manage equipment types" on public.equipment_types;
create policy "auth users manage equipment types" on public.equipment_types for all to authenticated using (public.is_authorized_user()) with check (public.is_authorized_user());
drop policy if exists "auth users manage units" on public.equipment_units;
create policy "auth users manage units" on public.equipment_units for all to authenticated using (public.is_authorized_user()) with check (public.is_authorized_user());
drop policy if exists "auth users read assignments" on public.assignments;
create policy "auth users read assignments" on public.assignments for select to authenticated using (public.is_authorized_user());
drop policy if exists "auth users read uniforms" on public.uniforms;
create policy "auth users manage uniforms" on public.uniforms for all to authenticated using (public.is_authorized_user()) with check (public.is_authorized_user());
drop policy if exists "auth users read uniform components" on public.uniform_components;
create policy "auth users manage uniform components" on public.uniform_components for all to authenticated using (public.is_authorized_user()) with check (public.is_authorized_user());
drop policy if exists "auth users read movements" on public.movements;
create policy "auth users read movements" on public.movements for select to authenticated using (public.is_authorized_user());
drop policy if exists "auth users manage legacy imports" on public.legacy_import_rows;
create policy "auth users manage legacy imports" on public.legacy_import_rows for all to authenticated using (public.is_authorized_user()) with check (public.is_authorized_user());

create or replace function public.assign_unit(p_unit_id uuid,p_firefighter_id uuid,p_delivered_at date default current_date,p_size text default null,p_brand text default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_assignment uuid;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if not exists(select 1 from firefighters where id=p_firefighter_id and active) then raise exception 'El bombero no está activo.'; end if;
  if not exists(select 1 from equipment_units where id=p_unit_id and ownership='station' and lifecycle='active' and condition <> 'out_of_service') then raise exception 'La unidad no pertenece al cuartel, está fuera de servicio o no está disponible.'; end if;
  insert into assignments(equipment_unit_id,firefighter_id,delivered_at,size_snapshot,brand_snapshot,notes)
  values(p_unit_id,p_firefighter_id,p_delivered_at::timestamptz,p_size,p_brand,p_notes) returning id into v_assignment;
  insert into movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details,notes)
  values(p_unit_id,v_assignment,p_firefighter_id,'assigned',jsonb_build_object('delivered_at',p_delivered_at,'size',p_size,'brand',p_brand),p_notes);
  return v_assignment;
exception when unique_violation then raise exception 'La unidad ya tiene una asignación activa.';
end $$;

create or replace function public.create_type_with_units(p_name text,p_quantity integer,p_condition text default 'good',p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_type uuid; v_unit uuid; i integer;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if p_quantity < 1 or p_quantity > 500 then raise exception 'La cantidad debe ser de 1 a 500 unidades.'; end if;
  if p_condition not in ('good','regular','bad','out_of_service','review') then raise exception 'Estado inválido.'; end if;
  insert into equipment_types(name,notes) values(trim(p_name),p_notes) returning id into v_type;
  for i in 1..p_quantity loop
    insert into equipment_units(equipment_type_id,condition,ownership,lifecycle,notes) values(v_type,p_condition,'station','active',p_notes) returning id into v_unit;
    insert into movements(equipment_unit_id,movement_type,details,notes) values(v_unit,'registered',jsonb_build_object('equipment_type_id',v_type,'condition',p_condition),p_notes);
  end loop;
  return v_type;
end $$;

create or replace function public.add_equipment_units(p_type_id uuid,p_quantity integer,p_condition text default 'good',p_notes text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_unit uuid; i integer;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if p_quantity < 1 or p_quantity > 500 then raise exception 'La cantidad debe ser de 1 a 500 unidades.'; end if;
  if p_condition not in ('good','regular','bad','out_of_service','review') then raise exception 'Estado inválido.'; end if;
  if not exists(select 1 from equipment_types where id=p_type_id) then raise exception 'El tipo de elemento no existe.'; end if;
  for i in 1..p_quantity loop
    insert into equipment_units(equipment_type_id,condition,ownership,lifecycle,notes) values(p_type_id,p_condition,'station','active',p_notes) returning id into v_unit;
    insert into movements(equipment_unit_id,movement_type,details,notes) values(v_unit,'registered',jsonb_build_object('equipment_type_id',p_type_id,'condition',p_condition),p_notes);
  end loop;
  return p_quantity;
end $$;

-- Idempotent and transactional import: upsert the original sheet rows without converting
-- ambiguous cells into physical stock or active assignments.
create or replace function public.import_legacy_data(p_people jsonb,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare person jsonb; source_row jsonb; v_person_id uuid; v_people integer := 0; v_rows integer := 0; v_no text; v_name text;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if jsonb_typeof(p_people) <> 'array' or jsonb_typeof(p_rows) <> 'array' then raise exception 'El formato de importación no es válido.'; end if;
  if jsonb_array_length(p_people) <> 22 then raise exception 'El padrón debe contener las 22 personas del CSV recibido.'; end if;
  if jsonb_array_length(p_rows) <> 44 then raise exception 'La importación debe conservar 22 filas originales de cada hoja.'; end if;
  for person in select * from jsonb_array_elements(p_people) loop
    v_no := nullif(trim(person->>'personnel_no'),''); v_name := nullif(trim(person->>'full_name'),'');
    if v_no is null or v_name is null then raise exception 'Cada persona debe tener legajo y nombre.'; end if;
    insert into firefighters(personnel_no,full_name,rank,active,notes)
      values(v_no,v_name,null,true,'Importado desde CSV; cargo no identificado automáticamente.')
      on conflict(personnel_no) do nothing;
    v_people := v_people + 1;
  end loop;
  for source_row in select * from jsonb_array_elements(p_rows) loop
    v_no := nullif(trim(source_row->>'personnel_no'),'');
    select id into v_person_id from firefighters where personnel_no=v_no;
    if v_person_id is null then raise exception 'No existe el legajo % al que corresponde un registro original.', v_no; end if;
    insert into legacy_import_rows(source_key,source_sheet,source_row,firefighter_id,raw_data)
      values(source_row->>'source_key',source_row->>'source_sheet',(source_row->>'source_row')::integer,v_person_id,source_row->'raw_data')
      on conflict(source_key) do update set source_sheet=excluded.source_sheet,source_row=excluded.source_row,firefighter_id=excluded.firefighter_id,raw_data=excluded.raw_data,imported_at=now();
    v_rows := v_rows + 1;
  end loop;
  return jsonb_build_object('people_processed',v_people,'source_rows_saved',v_rows);
end $$;

create or replace function public.update_firefighter(p_firefighter_id uuid,p_full_name text,p_personnel_no text,p_rank text)
returns void language plpgsql security definer set search_path = public as $$
declare v_old firefighters%rowtype;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  select * into v_old from firefighters where id=p_firefighter_id;
  if not found then raise exception 'El bombero no existe.'; end if;
  update firefighters set full_name=trim(p_full_name),personnel_no=nullif(trim(p_personnel_no),''),rank=nullif(trim(p_rank),''),updated_at=now() where id=p_firefighter_id;
  insert into movements(firefighter_id,movement_type,details) values(p_firefighter_id,'edited',jsonb_build_object('before',jsonb_build_object('full_name',v_old.full_name,'personnel_no',v_old.personnel_no,'rank',v_old.rank),'after',jsonb_build_object('full_name',trim(p_full_name),'personnel_no',nullif(trim(p_personnel_no),''),'rank',nullif(trim(p_rank),''))));
end $$;

create or replace function public.return_unit(p_assignment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v assignments%rowtype;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  update assignments set status='returned',returned_at=now() where id=p_assignment_id and status='active' returning * into v;
  if not found then raise exception 'La asignación ya fue cerrada o no existe.'; end if;
  insert into movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,details) values(v.equipment_unit_id,v.id,v.firefighter_id,'returned',jsonb_build_object('returned_at',now()));
end $$;

create or replace function public.report_lost_unit(p_assignment_id uuid,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v assignments%rowtype;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  update assignments set status='lost',returned_at=now(),notes=concat_ws(E'\n',notes,p_notes) where id=p_assignment_id and status='active' returning * into v;
  if not found then raise exception 'La asignación ya fue cerrada o no existe.'; end if;
  update equipment_units set lifecycle='lost' where id=v.equipment_unit_id;
  insert into movements(equipment_unit_id,assignment_id,firefighter_id,movement_type,notes) values(v.equipment_unit_id,v.id,v.firefighter_id,'lost',p_notes);
end $$;

create or replace function public.set_unit_condition(p_unit_id uuid,p_condition text,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if p_condition not in ('good','regular','bad','out_of_service','review') then raise exception 'Estado inválido.'; end if;
  update equipment_units set condition=p_condition where id=p_unit_id returning condition into v_old;
  if not found then raise exception 'La unidad no existe.'; end if;
  insert into movements(equipment_unit_id,movement_type,details,notes) values(p_unit_id,'condition_changed',jsonb_build_object('condition',p_condition),p_notes);
end $$;

create or replace function public.retire_unit(p_unit_id uuid,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if exists(select 1 from assignments where equipment_unit_id=p_unit_id and status='active') then raise exception 'Devolvé o resolvé la asignación antes de dar de baja esta unidad.'; end if;
  update equipment_units set lifecycle='retired' where id=p_unit_id and lifecycle='active';
  if not found then raise exception 'La unidad no existe o ya no está activa.'; end if;
  insert into movements(equipment_unit_id,movement_type,notes) values(p_unit_id,'retired',p_notes);
end $$;

grant execute on function public.assign_unit(uuid,uuid,date,text,text,text) to authenticated;
grant execute on function public.create_type_with_units(text,integer,text,text) to authenticated;
grant execute on function public.add_equipment_units(uuid,integer,text,text) to authenticated;
grant execute on function public.import_legacy_data(jsonb,jsonb) to authenticated;
grant execute on function public.update_firefighter(uuid,text,text,text) to authenticated;
grant execute on function public.return_unit(uuid) to authenticated;
grant execute on function public.report_lost_unit(uuid,text) to authenticated;
grant execute on function public.set_unit_condition(uuid,text,text) to authenticated;
grant execute on function public.retire_unit(uuid,text) to authenticated;
revoke execute on function public.is_authorized_user() from public,anon;
revoke execute on function public.assign_unit(uuid,uuid,date,text,text,text) from public,anon;
revoke execute on function public.create_type_with_units(text,integer,text,text) from public,anon;
revoke execute on function public.add_equipment_units(uuid,integer,text,text) from public,anon;
revoke execute on function public.import_legacy_data(jsonb,jsonb) from public,anon;
revoke execute on function public.update_firefighter(uuid,text,text,text) from public,anon;
revoke execute on function public.return_unit(uuid) from public,anon;
revoke execute on function public.report_lost_unit(uuid,text) from public,anon;
revoke execute on function public.set_unit_condition(uuid,text,text) from public,anon;
revoke execute on function public.retire_unit(uuid,text) from public,anon;

-- Funciones añadidas para edición del catálogo y uniformes.
create or replace function public.update_equipment_type(p_type_id uuid,p_name text,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'El nombre del elemento es obligatorio.'; end if;
  select name into v_old from equipment_types where id=p_type_id;
  if not found then raise exception 'El elemento no existe.'; end if;
  update equipment_types set name=trim(p_name),notes=p_notes,updated_at=now() where id=p_type_id;
  insert into movements(movement_type,details) values('edited',jsonb_build_object('equipment_type_id',p_type_id,'before_name',v_old,'after_name',trim(p_name)));
end $$;
grant execute on function public.update_equipment_type(uuid,text,text) to authenticated;
revoke execute on function public.update_equipment_type(uuid,text,text) from public,anon;

create or replace function public.save_uniform_template(p_uniform_id uuid,p_name text,p_notes text,p_components jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uniform uuid:=p_uniform_id; item jsonb;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if nullif(trim(p_name),'') is null or jsonb_typeof(p_components)<>'array' then raise exception 'Nombre y componentes válidos son obligatorios.'; end if;
  if v_uniform is null then insert into uniforms(name,notes) values(trim(p_name),p_notes) returning id into v_uniform;
  else update uniforms set name=trim(p_name),notes=p_notes,active=true where id=v_uniform; if not found then raise exception 'La plantilla no existe.'; end if; delete from uniform_components where uniform_id=v_uniform; end if;
  for item in select * from jsonb_array_elements(p_components) loop
    if not exists(select 1 from equipment_types where id=(item->>'equipment_type_id')::uuid) then raise exception 'La plantilla contiene un elemento inexistente.'; end if;
    insert into uniform_components(uniform_id,equipment_type_id,quantity,position) values(v_uniform,(item->>'equipment_type_id')::uuid,greatest(1,least(100,(item->>'quantity')::integer)),coalesce((item->>'position')::integer,0));
  end loop;
  insert into movements(movement_type,details) values('edited',jsonb_build_object('uniform_id',v_uniform,'template_name',trim(p_name),'components',p_components));
  return v_uniform;
end $$;
grant execute on function public.save_uniform_template(uuid,text,text,jsonb) to authenticated;
revoke execute on function public.save_uniform_template(uuid,text,text,jsonb) from public,anon;

create or replace function public.assign_uniform(p_uniform_id uuid,p_firefighter_id uuid,p_delivered_at date default current_date,p_notes text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare component record; unit_row record; inserted integer:=0;
begin
  if not public.is_authorized_user() then raise exception 'La cuenta no está autorizada para operar el inventario.'; end if;
  if not exists(select 1 from firefighters where id=p_firefighter_id and active) then raise exception 'El bombero no está activo.'; end if;
  if not exists(select 1 from uniforms where id=p_uniform_id and active) then raise exception 'La plantilla no existe o está inactiva.'; end if;
  for component in select equipment_type_id,quantity from uniform_components where uniform_id=p_uniform_id loop
    if (select count(*) from equipment_units u where u.equipment_type_id=component.equipment_type_id and u.ownership='station' and u.lifecycle='active' and u.condition<>'out_of_service' and not exists(select 1 from assignments a where a.equipment_unit_id=u.id and a.status='active')) < component.quantity then raise exception 'No hay unidades disponibles suficientes para todos los componentes; no se realizó la asignación.'; end if;
  end loop;
  for component in select equipment_type_id,quantity from uniform_components where uniform_id=p_uniform_id loop
    for unit_row in select u.id,u.size,u.brand from equipment_units u where u.equipment_type_id=component.equipment_type_id and u.ownership='station' and u.lifecycle='active' and u.condition<>'out_of_service' and not exists(select 1 from assignments a where a.equipment_unit_id=u.id and a.status='active') order by u.created_at,u.id limit component.quantity for update loop
      perform public.assign_unit(unit_row.id,p_firefighter_id,p_delivered_at,unit_row.size,unit_row.brand,p_notes);
      inserted:=inserted+1;
    end loop;
  end loop;
  insert into movements(firefighter_id,movement_type,details,notes) values(p_firefighter_id,'assigned',jsonb_build_object('uniform_id',p_uniform_id,'components_assigned',inserted),p_notes);
  return inserted;
end $$;
grant execute on function public.assign_uniform(uuid,uuid,date,text) to authenticated;
revoke execute on function public.assign_uniform(uuid,uuid,date,text) from public,anon;


