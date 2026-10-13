"""Deja la base de datos de Supabase lista para un nuevo día del piloto (v2).

Borra todos los eventos, la asistencia y las alertas de prueba, pone el aforo de los salones en 0
y a todos los estudiantes en OUT, en una sola transacción (RPC admin_reset_pilot). Se conservan
estudiantes, cursos, salones, cámaras, sesiones, usuarios y la auditoría: no hace falta volver a
correr seed_students.py. Se usa después del ensayo y antes del día real.
Versión Supabase de reset_pilot.py (v1, DynamoDB), que se retira en la task 10.

Uso:
    python scripts/reset_pilot_supabase.py          # pide escribir BORRAR
    python scripts/reset_pilot_supabase.py --yes    # sin confirmación

Requiere SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en variables de entorno.
"""

import argparse
import os

CONFIRMATION_WORD = "BORRAR"


def reset(client=None):
    """Ejecuta el reinicio y devuelve el conteo de filas borradas por tabla."""
    if client is None:
        import supabase_admin as client
    return client.rpc("admin_reset_pilot")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Reinicia los datos del piloto en Supabase.")
    parser.add_argument("--yes", action="store_true", help="no pedir confirmación")
    args = parser.parse_args()

    if not args.yes:
        print(f"Esto borra TODOS los eventos, la asistencia y las alertas de {os.environ.get('SUPABASE_URL', '(sin SUPABASE_URL)')},")
        print("pone el aforo en 0 y deja a todos los estudiantes en OUT. No se puede deshacer.")
        answer = input(f"Escribe {CONFIRMATION_WORD} para continuar: ")
        if answer.strip() != CONFIRMATION_WORD:
            print("Cancelado, no se borró nada.")
            raise SystemExit(1)

    result = reset()
    print(f"Listo: {result['events']} eventos, {result['attendance']} filas de asistencia y "
          f"{result['alerts']} alertas borradas; aforo en 0 y estudiantes en OUT.")
