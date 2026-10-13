-- Resumen diario por salón para las gráficas del frontend (día calendario en hora de Bogotá).
-- security_invoker: la vista se consulta con los permisos de quien la lee, así que respeta el RLS de events
-- (teacher/admin ven el resumen; viewer y anon no ven filas).
--   entries / exits          cruces de entrada y salida del día
--   face_identified_pct      % de los cruces del día identificados por rostro (method = FACE)
--   peak_occupancy           pico de personas dentro durante el día, calculado con la suma acumulada de
--                            entradas - salidas desde 0 al inicio del día (aproximación: si el día empieza con
--                            gente adentro o hay salidas con el salón vacío, puede diferir del contador real)
--   first_event_at / last_event_at

create or replace view public.daily_occupancy_summary
with (security_invoker = true)
as
with day_events as (
  select
    e.classroom_id,
    (e.occurred_at at time zone 'America/Bogota')::date as day,
    e.occurred_at,
    e.direction,
    e.method,
    sum(case when e.direction = 'ENTRY' then 1 else -1 end)
      over (partition by e.classroom_id, (e.occurred_at at time zone 'America/Bogota')::date
            order by e.occurred_at, e.id
            rows between unbounded preceding and current row) as running_occupancy
  from public.events e
)
select
  d.classroom_id,
  c.name                                                         as classroom_name,
  d.day,
  count(*) filter (where d.direction = 'ENTRY')::integer         as entries,
  count(*) filter (where d.direction = 'EXIT')::integer          as exits,
  count(*) filter (where d.method = 'FACE')::integer             as face_identified,
  round(100.0 * count(*) filter (where d.method = 'FACE') / count(*), 1) as face_identified_pct,
  greatest(max(d.running_occupancy), 0)::integer                 as peak_occupancy,
  min(d.occurred_at)                                             as first_event_at,
  max(d.occurred_at)                                             as last_event_at
from day_events d
join public.classrooms c on c.id = d.classroom_id
group by d.classroom_id, c.name, d.day;

comment on view public.daily_occupancy_summary is
  'Resumen diario por salón (hora de Bogotá): entradas, salidas, % identificado por rostro y pico de aforo. Respeta RLS (security_invoker).';

revoke all on public.daily_occupancy_summary from anon, authenticated;
grant select on public.daily_occupancy_summary to authenticated;
