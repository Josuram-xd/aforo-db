"""Crea (o revoca) la llave de dispositivo de un salón para aforo-vision.

Genera una llave aleatoria de 256 bits, guarda en la base de datos SOLO su hash SHA-256
(private.device_keys, vía la RPC admin_register_device_key) y la muestra UNA sola vez para
configurarla en el nodo de visión como AFORO_DEVICE_KEY (archivo .env de aforo-vision, nunca en git).
Si se pierde, se revoca y se crea otra.

Uso:
    python scripts/create_device_key.py "Salón del piloto" [--label aforo-vision-laptop]
    python scripts/create_device_key.py "Salón del piloto" --revoke

Requiere SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en variables de entorno.
"""

import argparse
import hashlib
import secrets


def generate_key():
    """Devuelve (llave_en_claro, hash_sha256_hex). La llave es URL-safe y tiene 256 bits de entropía."""
    key = secrets.token_urlsafe(32)
    return key, hashlib.sha256(key.encode("utf-8")).hexdigest()


def create(classroom, label, client=None):
    if client is None:
        import supabase_admin as client
    key, key_hash = generate_key()
    client.rpc("admin_register_device_key",
               {"p_classroom_name": classroom, "p_label": label, "p_key_hash": key_hash})
    return key


def revoke(classroom, client=None):
    if client is None:
        import supabase_admin as client
    return client.rpc("admin_revoke_device_keys", {"p_classroom_name": classroom})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Crea o revoca la llave de dispositivo de un salón.")
    parser.add_argument("classroom", help='nombre del salón, ej. "Salón del piloto"')
    parser.add_argument("--label", default="aforo-vision", help="etiqueta para reconocer la llave")
    parser.add_argument("--revoke", action="store_true", help="revoca todas las llaves activas del salón")
    args = parser.parse_args()

    if args.revoke:
        print(f"{revoke(args.classroom)} llave(s) revocada(s) en {args.classroom!r}.")
    else:
        new_key = create(args.classroom, args.label)
        print("Llave creada. Cópiala ahora: no se vuelve a mostrar y en la base de datos solo queda su hash.")
        print(f"\nAFORO_DEVICE_KEY={new_key}\n")
        print("Ponla en el .env de aforo-vision (nunca en git ni en pilot.yaml).")
