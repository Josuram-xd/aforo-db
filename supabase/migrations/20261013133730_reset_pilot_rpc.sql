-- Reinicio del piloto (scripts/reset_pilot_supabase.py): borra eventos, asistencia y alertas de prueba, pone el
-- aforo de todos los salones en 0 y a todos los estudiantes en OUT. Conserva estudiantes, cursos, salones,
-- cámaras, sesiones, usuarios y la auditoría. Todo en una transacción. Solo service_role puede llamarla.

create or replace function public.admin_reset_pilot()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_events     integer;
  v_attendance integer;
  v_alerts     integer;
begin
  delete from public.events where true;
  get diagnostics v_events = row_count;
  delete from public.attendance where true;
  get diagnostics v_attendance = row_count;
  delete from public.alerts where true;
  get diagnostics v_alerts = row_count;

  update public.classrooms set current_occupancy = 0, occupancy_updated_at = null where true;
  update public.students   set presence = 'OUT', last_event_at = null where true;

  return jsonb_build_object('events', v_events, 'attendance', v_attendance, 'alerts', v_alerts);
end;
$$;

revoke all on function public.admin_reset_pilot() from public, anon, authenticated;
grant execute on function public.admin_reset_pilot() to service_role;
