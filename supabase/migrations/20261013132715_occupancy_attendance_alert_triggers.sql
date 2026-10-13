-- Triggers de operación: updated_at y efectos de cada evento (aforo, estado del estudiante,
-- asistencia de la sesión y alerta de aforo).

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'courses', 'classrooms', 'cameras', 'students', 'class_sessions'] loop
    execute format(
      'create trigger set_updated_at before update on public.%I for each row execute function private.set_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Efectos de cada evento
-- ---------------------------------------------------------------------------

-- Se ejecuta una vez por evento nuevo (los duplicados no llegan aquí: ingest_event usa on conflict do nothing).
--  1. Aforo atómico del salón: +1 en ENTRY, -1 en EXIT, nunca < 0 (ADR-004/ADR-008). El UPDATE bloquea la
--     fila del salón, así que eventos simultáneos se aplican uno tras otro sin perder conteos.
--  2. presence del estudiante identificado (solo si el evento es más reciente que el último aplicado).
--  3. Fila de attendance de la sesión.
--  4. Alerta capacity_exceeded: se abre al superar max_capacity y se cierra sola al volver a estar dentro.
create or replace function private.apply_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_occupancy integer;
  v_capacity  integer;
  v_room_name text;
  v_is_entry  boolean := new.direction = 'ENTRY';
begin
  update public.classrooms
     set current_occupancy    = greatest(current_occupancy + case when v_is_entry then 1 else -1 end, 0),
         occupancy_updated_at = greatest(occupancy_updated_at, new.occurred_at)
   where id = new.classroom_id
  returning current_occupancy, max_capacity, name into v_occupancy, v_capacity, v_room_name;

  if new.student_id is not null then
    update public.students
       set presence      = case when v_is_entry then 'IN' else 'OUT' end,
           last_event_at = new.occurred_at
     where id = new.student_id
       and (last_event_at is null or last_event_at <= new.occurred_at);

    if new.session_id is not null then
      insert into public.attendance as a
             (session_id, student_id, first_entry_at, last_exit_at, last_event_at, status)
      values (
        new.session_id, new.student_id,
        case when v_is_entry then new.occurred_at end,
        case when not v_is_entry then new.occurred_at end,
        new.occurred_at,
        case when v_is_entry then 'present' else 'left' end
      )
      on conflict (session_id, student_id) do update
        set first_entry_at = least(a.first_entry_at, excluded.first_entry_at),     -- least/greatest ignoran null
            last_exit_at   = greatest(a.last_exit_at, excluded.last_exit_at),
            status         = case when excluded.last_event_at >= a.last_event_at then excluded.status else a.status end,
            last_event_at  = greatest(a.last_event_at, excluded.last_event_at),
            updated_at     = now();
    end if;
  end if;

  if v_occupancy > v_capacity then
    insert into public.alerts (classroom_id, type, severity, message)
    values (new.classroom_id, 'capacity_exceeded', 'critical',
            format('%s superó su aforo máximo: %s de %s personas', v_room_name, v_occupancy, v_capacity))
    on conflict (classroom_id) where type = 'capacity_exceeded' and resolved_at is null do nothing;
  else
    update public.alerts
       set resolved_at = now()
     where classroom_id = new.classroom_id and type = 'capacity_exceeded' and resolved_at is null;
  end if;

  return null;
end;
$$;

revoke all on function private.apply_event()    from public, anon, authenticated;
revoke all on function private.set_updated_at() from public, anon, authenticated;

create trigger apply_event
  after insert on public.events
  for each row execute function private.apply_event();
