"""Cliente mínimo de la API REST de Supabase para los scripts de administración.

Usa solo la biblioteca estándar. Lee de variables de entorno (nunca de archivos versionados):
    SUPABASE_URL               URL del proyecto, ej. https://<ref>.supabase.co
    SUPABASE_SERVICE_ROLE_KEY  llave service_role / secret (sb_secret_...). Salta RLS: úsala solo
                               en una máquina de confianza y nunca la subas a git ni al frontend.
"""

import json
import os
import urllib.error
import urllib.request


class SupabaseError(RuntimeError):
    """La API de Supabase respondió con un error."""


def _config():
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        raise SystemExit("Faltan las variables de entorno SUPABASE_URL y/o SUPABASE_SERVICE_ROLE_KEY.")
    if not url.startswith("https://"):
        raise SystemExit("SUPABASE_URL debe empezar por https://")
    return url, key


def request(method, path, body=None, prefer=None):
    """Hace una petición a <SUPABASE_URL>/rest/v1/<path> con la llave de servicio y devuelve el JSON."""
    url, key = _config()
    headers = {"apikey": key, "Content-Type": "application/json", "Accept": "application/json"}
    # Las llaves antiguas (JWT) también van en Authorization; las nuevas sb_secret_ solo en apikey.
    if not key.startswith("sb_"):
        headers["Authorization"] = f"Bearer {key}"
    if prefer:
        headers["Prefer"] = prefer
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(f"{url}/rest/v1/{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise SupabaseError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
    return json.loads(raw) if raw else None


def rpc(function, args=None):
    """Llama a una función de la base de datos (POST /rest/v1/rpc/<function>)."""
    return request("POST", f"rpc/{function}", args or {})
