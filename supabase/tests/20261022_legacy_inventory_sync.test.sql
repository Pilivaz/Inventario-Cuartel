-- Transactional smoke test for 20261022. Run only after the migration succeeds.
-- Every unit, assignment, movement, and link created here is rolled back.
begin;

do $$
declare
  v_admin uuid;
  v_source_station uuid;
  v_source_personal uuid;
  v_firefighter uuid;
  v_raw jsonb;
  v_type uuid;
  v_unit uuid;
  v_result jsonb;
  v_retry jsonb;
  v_assignment uuid;
begin
  select user_id into v_admin from public.authorized_users order by created_at limit 1;
  select id,firefighter_id,raw_data into v_source_station,v_firefighter,v_raw
    from public.legacy_import_rows where source_sheet like 'Ficha individual · %' order by source_key limit 1;
  select id into v_source_personal from public.legacy_import_rows
    where source_sheet like 'Ficha individual · %' and id<>v_source_station order by source_key limit 1;
  if v_admin is null or v_source_station is null or v_source_personal is null or v_firefighter is null then
    raise exception 'Falta administrador, bombero o filas individuales para la prueba.';
  end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);

  select public.create_type_with_units('PRUEBA VÍNCULO EXISTENTE '||txid_current(),1,'good','Prueba revertida') into v_type;
  select id into v_unit from public.equipment_units where equipment_type_id=v_type limit 1;
  select public.reconcile_legacy_item(v_source_station,v_unit,null,null,null,'Marca prueba','M',current_date,'Vínculo de prueba',true) into v_result;
  v_assignment:=(v_result->>'assignment_id')::uuid;
  if not exists(select 1 from public.legacy_unit_links where legacy_import_row_id=v_source_station and equipment_unit_id=v_unit and assignment_id=v_assignment) then
    raise exception 'No se creó el vínculo auditable de la fila fuente.';
  end if;
  if not exists(select 1 from public.assignments where id=v_assignment and firefighter_id=v_firefighter and status='active') then
    raise exception 'La asignación real no quedó ligada al bombero de la fila.';
  end if;
  select public.reconcile_legacy_item(v_source_station,v_unit,null,null,null,'Otro texto','L',current_date,'Reintento',true) into v_retry;
  if coalesce((v_retry->>'already_linked')::boolean,false) is not true or v_retry->>'assignment_id'<>v_assignment::text then
    raise exception 'El reintento duplicó o cambió el vínculo de la fila.';
  end if;
  if not exists(select 1 from public.legacy_import_rows where id=v_source_station and raw_data=v_raw) then
    raise exception 'La vinculación modificó los datos originales del Excel.';
  end if;
  if not exists(select 1 from public.equipment_units where id=v_unit and ownership='station' and lifecycle='active') then
    raise exception 'La unidad del cuartel no se conserva en el inventario activo.';
  end if;

  select public.reconcile_legacy_item(v_source_personal,null,'PRUEBA PERSONAL '||txid_current(),'firefighter','review',null,null,current_date,'Prueba personal',true) into v_result;
  v_unit:=(v_result->>'equipment_unit_id')::uuid;
  if not exists(select 1 from public.equipment_units where id=v_unit and ownership='firefighter' and owner_firefighter_id=(select firefighter_id from public.legacy_import_rows where id=v_source_personal)) then
    raise exception 'El equipo personal no quedó vinculado a su propietario.';
  end if;
  if exists(select 1 from public.equipment_units where id=v_unit and ownership='station') then
    raise exception 'El equipo personal se contó como stock del cuartel.';
  end if;
  if has_table_privilege('authenticated','public.legacy_unit_links','INSERT') then
    raise exception 'La tabla de vínculos permite escritura directa a authenticated.';
  end if;
end $$;

rollback;
