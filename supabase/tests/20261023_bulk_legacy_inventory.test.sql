-- Transactional smoke test for the one-time inventory reconciliation.
-- Runs the idempotent RPC twice, checks counts/source preservation, and rolls back.
begin;
do $$
declare
  v_admin uuid;
  v_source uuid;
  v_source_data jsonb;
  v_source_rows integer;
  v_summary_rows integer;
  v_units_before integer;
  v_assignments_before integer;
  v_units_after_first integer;
  v_assignments_after_first integer;
  v_units_after_second integer;
  v_assignments_after_second integer;
  v_first jsonb;
  v_second jsonb;
begin
  select user_id into v_admin from public.authorized_users order by created_at limit 1;
  select id,raw_data into v_source,v_source_data from public.legacy_import_rows
    where source_sheet like 'Ficha individual · %' and firefighter_id is not null order by source_key limit 1;
  select count(*) into v_source_rows from public.legacy_import_rows where source_sheet like 'Ficha individual · %';
  select count(*) into v_summary_rows from public.legacy_import_rows where source_sheet not like 'Ficha individual · %';
  select count(*) into v_units_before from public.equipment_units;
  select count(*) into v_assignments_before from public.assignments;
  if v_admin is null or v_source is null or v_source_rows<>794 or v_summary_rows<>44 then
    raise exception 'Precondición fallida: esperaba admin, fila individual, 794 fichas y 44 resúmenes; fichas %, resúmenes %.',v_source_rows,v_summary_rows;
  end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);

  select public.reconcile_all_legacy_equipment(true) into v_first;
  select count(*) into v_units_after_first from public.equipment_units;
  select count(*) into v_assignments_after_first from public.assignments;
  select public.reconcile_all_legacy_equipment(true) into v_second;
  select count(*) into v_units_after_second from public.equipment_units;
  select count(*) into v_assignments_after_second from public.assignments;

  if v_units_after_first-v_units_before <> (v_first->>'physical_units_created')::integer then
    raise exception 'El total de unidades no coincide con la respuesta del RPC.';
  end if;
  if v_assignments_after_first-v_assignments_before <> (v_first->>'physical_units_created')::integer then
    raise exception 'El total de asignaciones no coincide con las unidades creadas.';
  end if;
  if v_units_after_second<>v_units_after_first or v_assignments_after_second<>v_assignments_after_first then
    raise exception 'La segunda ejecución no fue idempotente.';
  end if;
  if coalesce((v_second->>'physical_units_created')::integer,0)<>0 then
    raise exception 'La segunda ejecución informó unidades nuevas.';
  end if;
  if not exists(select 1 from public.legacy_import_rows where id=v_source and raw_data=v_source_data) then
    raise exception 'El contenido original de una ficha cambió.';
  end if;
  if (select count(*) from public.legacy_import_rows where source_sheet not like 'Ficha individual · %')<>44 then
    raise exception 'Las 44 filas de resumen cambiaron.';
  end if;
  if exists(select 1 from public.equipment_units u where u.notes='Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.' and (u.condition<>'review' or u.ownership<>'station')) then
    raise exception 'Una unidad reconciliada no conservó la condición o propiedad esperada.';
  end if;
  if exists(select 1 from public.assignments a where a.notes='Unidad física existente según la ficha original. Conservación pendiente de revisión; ver valores fuente en la ficha.' and a.delivered_at is not null) then
    raise exception 'Se inventó una fecha de entrega histórica.';
  end if;
  if has_table_privilege('authenticated','public.legacy_unit_link_extras','INSERT') then
    raise exception 'El usuario autenticado puede escribir directamente en los vínculos secundarios.';
  end if;
end $$;
rollback;
