-- Add a guarded, auditable active/inactive toggle for firefighters.
-- Apply only after reviewing the migration; it preserves all existing rows.
begin;

create or replace function public.set_firefighter_active(
  p_firefighter_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_active boolean;
begin
  if not public.is_authorized_user() then
    raise exception 'La cuenta no está autorizada para operar el inventario.';
  end if;
  if p_active is null then
    raise exception 'El estado activo es obligatorio.';
  end if;

  select active into v_old_active
  from public.firefighters
  where id = p_firefighter_id
  for update;
  if not found then
    raise exception 'El bombero no existe.';
  end if;
  if v_old_active = p_active then
    return;
  end if;
  if not p_active and exists (
    select 1 from public.assignments
    where firefighter_id = p_firefighter_id and status = 'active'
  ) then
    raise exception 'No se puede dar de baja a un bombero con equipamiento asignado; resolvé primero las asignaciones activas.';
  end if;

  update public.firefighters
  set active = p_active, updated_at = now()
  where id = p_firefighter_id;

  insert into public.movements (firefighter_id, movement_type, details)
  values (
    p_firefighter_id,
    'edited',
    jsonb_build_object('field', 'active', 'before', v_old_active, 'after', p_active)
  );
end;
$$;

revoke all on function public.set_firefighter_active(uuid, boolean) from public, anon;
grant execute on function public.set_firefighter_active(uuid, boolean) to authenticated;

commit;
