-- Retención mínima de datos personales (Ley 1581, reemplaza la TTL de v1): un job diario de pg_cron borra
-- los eventos y la asistencia con más de 30 días. Para cambiar el plazo:
--   select cron.alter_job((select jobid from cron.job where jobname = 'purge-old-events'),
--                         command := 'select private.purge_old_data(<días>)');

create extension if not exists pg_cron with schema pg_catalog;

-- Borra eventos y filas de asistencia más antiguos que p_days días. No toca el aforo actual ni el estado
-- IN/OUT de los estudiantes. Devuelve cuántas filas borró de cada tabla (queda en cron.job_run_details).
create or replace function private.purge_old_data(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff     timestamptz;
  v_events     integer;
  v_attendance integer;
begin
  if p_days is null or p_days < 1 then
    raise exception 'p_days debe ser al menos 1' using errcode = '22023';
  end if;
  v_cutoff := now() - make_interval(days => p_days);

  delete from public.events where occurred_at < v_cutoff;
  get diagnostics v_events = row_count;
  delete from public.attendance where last_event_at < v_cutoff;
  get diagnostics v_attendance = row_count;

  return jsonb_build_object('cutoff', v_cutoff, 'events', v_events, 'attendance', v_attendance);
end;
$$;

revoke all on function private.purge_old_data(integer) from public, anon, authenticated;

-- Todos los días a las 03:15 hora de Bogotá (08:15 UTC). Reprogramar con el mismo nombre lo actualiza.
select cron.schedule('purge-old-events', '15 8 * * *', $$select private.purge_old_data(30)$$);
