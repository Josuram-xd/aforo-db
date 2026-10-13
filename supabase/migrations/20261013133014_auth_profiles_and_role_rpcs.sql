-- Cuentas y roles. Supabase Auth se encarga del registro, las contraseñas (bcrypt, en auth.users) y Google;
-- aquí solo se crea el perfil y el rol inicial, y se exponen las RPCs de administración.

-- ¿El usuario actual tiene una cuenta activa con alguno de estos roles? La usan las políticas RLS y las RPCs.
-- Una cuenta desactivada (profiles.is_active = false) responde false a todo: pierde todos sus permisos.
-- security definer para leer user_roles/profiles sin pasar por su propio RLS (evita recursión).
create or replace function private.has_any_role(variadic role_codes text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.roles r    on r.id = ur.role_id
    join public.profiles p on p.id = ur.user_id
    where ur.user_id = (select auth.uid())
      and p.is_active
      and r.code = any (role_codes)
  );
$$;

-- Registro: cada cuenta nueva (correo o Google) recibe su perfil y el rol viewer (sin datos personales).
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    left(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), 120),
    left(new.raw_user_meta_data ->> 'avatar_url', 500)
  );
  insert into public.user_roles (user_id, role_id)
  select new.id, r.id from public.roles r where r.code = 'viewer';
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Cambia el rol de un usuario (solo admin activo). Un admin no puede quitarse a sí mismo el rol admin,
-- así siempre queda al menos un administrador.
create or replace function public.set_user_role(p_user_id uuid, p_role_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede cambiar roles' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) and p_role_code <> 'admin' then
    raise exception 'no puedes quitarte tu propio rol de administrador' using errcode = '22023';
  end if;
  if not exists (select 1 from public.roles where code = p_role_code) then
    raise exception 'rol desconocido: %', left(p_role_code, 20) using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'usuario desconocido' using errcode = '22023';
  end if;

  delete from public.user_roles where user_id = p_user_id;
  insert into public.user_roles (user_id, role_id, granted_by)
  select p_user_id, r.id, (select auth.uid()) from public.roles r where r.code = p_role_code;
end;
$$;

-- Activa o desactiva una cuenta (solo admin activo). Una cuenta inactiva pierde todos sus permisos en RLS
-- de inmediato, y al desactivarla se cierran sus sesiones (no puede renovar el token).
create or replace function public.set_user_active(p_user_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.has_any_role('admin') then
    raise exception 'solo un administrador puede activar o desactivar cuentas' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'no puedes desactivar tu propia cuenta' using errcode = '22023';
  end if;
  if p_active is null then
    raise exception 'p_active es obligatorio' using errcode = '22023';
  end if;

  update public.profiles set is_active = p_active where id = p_user_id;
  if not found then
    raise exception 'usuario desconocido' using errcode = '22023';
  end if;
  if not p_active then
    delete from auth.sessions where user_id = p_user_id;   -- borra también sus refresh tokens (cascade)
  end if;
end;
$$;

-- Permisos
revoke all on function private.has_any_role(text[])          from public, anon, authenticated;
revoke all on function private.handle_new_user()             from public, anon, authenticated;
revoke all on function public.set_user_role(uuid, text)      from public, anon, authenticated;
revoke all on function public.set_user_active(uuid, boolean) from public, anon, authenticated;

-- Las políticas RLS se evalúan con el rol del usuario: necesita usar el schema private y has_any_role.
-- private sigue sin exponerse por la API (no está en los schemas de PostgREST).
grant usage on schema private to authenticated;
grant execute on function private.has_any_role(text[])          to authenticated;
grant execute on function public.set_user_role(uuid, text)      to authenticated;
grant execute on function public.set_user_active(uuid, boolean) to authenticated;
