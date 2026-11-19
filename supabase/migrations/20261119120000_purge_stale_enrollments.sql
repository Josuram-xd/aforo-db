-- Si el nodo de visión está apagado, las fotos de rostro no deben quedarse en la nube:
-- a los 10 minutos se borran y el estudiante pasa a 'failed' (repite "Registrar rostro").

create or replace function private.purge_stale_enrollments()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from private.enrollment_captures where created_at < now() - interval '10 minutes';

  update public.students
     set enrollment_status = 'failed', enrollment_updated_at = now()
   where enrollment_status = 'pending'
     and not exists (select 1 from private.enrollment_captures c where c.student_id = students.id);
end;
$$;

revoke all on function private.purge_stale_enrollments() from public, anon, authenticated;

select cron.schedule('purge-stale-enrollments', '* * * * *', $$select private.purge_stale_enrollments()$$);
