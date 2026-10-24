-- Safe smoke test for the secured RPCs added by 20261021.
-- Run only AFTER the migration succeeds. All test rows are rolled back at the end.
begin;

do $$
declare
  v_admin uuid;
  v_firefighter uuid;
  v_type uuid;
  v_unit_a uuid;
  v_unit_b uuid;
  v_unit_c uuid;
  v_assignment uuid;
  v_uniform uuid;
  v_assigned_components integer;
  v_rejected boolean := false;
  v_source_id uuid;
  v_source_raw jsonb;
begin
  select user_id into v_admin from public.authorized_users order by created_at limit 1;
  select id into v_firefighter from public.firefighters where active order by personnel_no limit 1;
  if v_admin is null or v_firefighter is null then raise exception 'Falta el administrador autorizado o un bombero activo.'; end if;

  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);

  select public.create_type_with_units('PRUEBA TRANSACCIONAL '||txid_current(),3,'good','Prueba revertida al final') into v_type;
  select id into v_unit_a from public.equipment_units where equipment_type_id=v_type order by created_at,id limit 1;
  select id into v_unit_b from public.equipment_units where equipment_type_id=v_type order by created_at,id offset 1 limit 1;
  select id into v_unit_c from public.equipment_units where equipment_type_id=v_type order by created_at,id offset 2 limit 1;
  if v_unit_a is null or v_unit_b is null or v_unit_c is null then raise exception 'No se crearon tres unidades de prueba.'; end if;

  perform public.update_equipment_unit(v_unit_a,'Marca prueba','M','regular','Edición de humo');
  select public.assign_unit(v_unit_a,v_firefighter,current_date,'M','Marca prueba','Asignación de humo') into v_assignment;
  begin
    perform public.assign_unit(v_unit_a,v_firefighter,current_date,'M','Marca prueba','Debe rechazarse duplicado');
  exception when others then v_rejected:=true;
  end;
  if not v_rejected then raise exception 'La base permitió asignar la misma unidad dos veces.'; end if;
  v_rejected:=false;
  perform public.update_equipment_assignment(v_assignment,current_date,'Marca editada','L','Edición de asignación');
  perform public.resolve_equipment_assignment(v_assignment,'returned','Devolución de prueba');
  if not exists(select 1 from public.assignments where id=v_assignment and status='returned' and returned_at is not null) then raise exception 'La devolución no cerró la asignación.'; end if;
  if not exists(select 1 from public.equipment_units where id=v_unit_a and brand='Marca editada' and size='L' and condition='regular') then raise exception 'La edición no quedó sincronizada en la unidad.'; end if;
  perform public.retire_unit(v_unit_a,'Baja de prueba');
  if not exists(select 1 from public.equipment_units where id=v_unit_a and lifecycle='retired') then raise exception 'La baja no excluyó la unidad.'; end if;

  select public.assign_unit(v_unit_b,v_firefighter,current_date,null,null,'Prueba de pérdida') into v_assignment;
  perform public.report_lost_unit(v_assignment,'Pérdida de prueba');
  if not exists(select 1 from public.assignments a join public.equipment_units u on u.id=a.equipment_unit_id where a.id=v_assignment and a.status='lost' and u.lifecycle='lost') then raise exception 'La pérdida no cerró la asignación y excluyó la unidad.'; end if;

  select public.save_uniform_template(null,'PLANTILLA DE PRUEBA '||txid_current(),'Prueba revertida',jsonb_build_array(jsonb_build_object('equipment_type_id',v_type,'quantity',1,'position',0))) into v_uniform;
  select public.assign_uniform(v_uniform,v_firefighter,current_date,'Asignación de uniforme de prueba') into v_assigned_components;
  if v_assigned_components<>1 then raise exception 'La plantilla no asignó el componente esperado.'; end if;
  if not exists(select 1 from public.assignments where equipment_unit_id=v_unit_c and firefighter_id=v_firefighter and status='active') then raise exception 'El componente del uniforme no tiene asignación real.'; end if;
  select id into v_assignment from public.assignments where equipment_unit_id=v_unit_c and status='active';
  perform public.resolve_equipment_assignment(v_assignment,'returned','Devolución de uniforme de prueba');

  select public.assign_unit(v_unit_c,v_firefighter,current_date,null,null,'Prueba de ubicación') into v_assignment;
  perform public.resolve_equipment_assignment(v_assignment,'pending_review','Ubicación de prueba');
  if not exists(select 1 from public.assignments where id=v_assignment and status='pending_review') then raise exception 'La situación pendiente no quedó registrada.'; end if;
  v_rejected:=false;
  begin
    perform public.assign_unit(v_unit_c,v_firefighter,current_date,null,null,'Debe quedar bloqueado');
  exception when others then v_rejected:=true;
  end;
  if not v_rejected then raise exception 'La unidad pendiente de ubicación se pudo reasignar.'; end if;
  perform public.resolve_pending_assignment(v_assignment,'returned','Devolución confirmada de prueba');

  select id,raw_data into v_source_id,v_source_raw from public.legacy_import_rows where source_sheet like 'Ficha individual · %' order by source_key limit 1;
  perform public.review_legacy_import_row(v_source_id,jsonb_build_object('test_correction','prueba'),'unchanged','Prueba revertida');
  if not exists(select 1 from public.legacy_import_rows where id=v_source_id and raw_data=v_source_raw) then raise exception 'La revisión alteró los datos fuente originales.'; end if;
  v_rejected:=false;
  begin
    perform public.review_legacy_import_row((select id from public.legacy_import_rows where source_sheet not like 'Ficha individual · %' limit 1),'{}','unchanged',null);
  exception when others then v_rejected:=true;
  end;
  if not v_rejected then raise exception 'Se permitió modificar un resumen original.'; end if;

  v_admin:=gen_random_uuid();
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  begin
    perform public.update_equipment_unit(v_unit_c,'No autorizado',null,'good',null);
  exception when others then v_rejected:=true;
  end;
  if not v_rejected then raise exception 'Una cuenta no autorizada pudo editar una unidad.'; end if;
  if has_table_privilege('authenticated','public.equipment_units','UPDATE') then raise exception 'Authenticated conserva UPDATE directo sobre equipment_units.'; end if;
end $$;

rollback;
