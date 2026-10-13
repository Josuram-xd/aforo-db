-- Ajuste tras los advisors de seguridad (task 7.9): ingest_event y camera_heartbeat son solo para el nodo
-- de visión, que llama con la publishable key (rol anon) + X-Device-Key. Una sesión de usuario no las necesita.
revoke execute on function public.ingest_event(jsonb)             from authenticated;
revoke execute on function public.camera_heartbeat(text, boolean) from authenticated;
