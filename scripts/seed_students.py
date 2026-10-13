"""Carga el roster del piloto en Supabase: tablas students y course_students.

Cada persona del roster se guarda con su personId como students.id (el mismo id que envía
aforo-vision en los eventos) y queda inscrita en el curso indicado. Solo se guardan personId y
name: cualquier otro campo del roster (por ejemplo, datos biométricos) se ignora.
Reemplaza a seed_people.py (v1, DynamoDB).

Uso:
    python scripts/seed_students.py [ruta_del_roster] [--course PILOTO-AFORO]

Por defecto lee scripts/roster.json (generado por aforo-vision: python -m enrollment.export_roster).
Requiere SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en variables de entorno.
Se puede correr varias veces: los estudiantes existentes solo actualizan su nombre (no se toca
su presence) y las inscripciones repetidas se ignoran.
"""

import argparse
import json
import uuid
from pathlib import Path
from urllib.parse import quote

DEFAULT_ROSTER = Path(__file__).parent / "roster.json"
DEFAULT_COURSE = "PILOTO-AFORO"
MAX_NAME_LENGTH = 120


def load_roster(roster_path):
    """Lee el roster y valida que cada persona tenga personId (UUID) y name, sin repetir."""
    with open(roster_path, encoding="utf-8") as f:
        roster = json.load(f)

    if not isinstance(roster, list):
        raise ValueError("El roster debe ser una lista de personas.")

    people = []
    seen = set()
    for i, entry in enumerate(roster):
        person_id = entry.get("personId") if isinstance(entry, dict) else None
        name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(person_id, str) or not person_id.strip():
            raise ValueError(f"Persona #{i}: falta personId o no es texto.")
        try:
            person_id = str(uuid.UUID(person_id))
        except ValueError:
            raise ValueError(f"Persona #{i}: personId debe ser un UUID, no {person_id!r}.") from None
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"Persona #{i} ({person_id}): falta name o no es texto.")
        if len(name.strip()) > MAX_NAME_LENGTH:
            raise ValueError(f"Persona #{i} ({person_id}): name supera {MAX_NAME_LENGTH} caracteres.")
        if person_id in seen:
            raise ValueError(f"personId repetido en el roster: {person_id}")
        seen.add(person_id)
        people.append({"id": person_id, "full_name": name.strip()})
    return people


def seed(roster_path, course_code=DEFAULT_COURSE, client=None):
    """Crea/actualiza los estudiantes y los inscribe en el curso. Devuelve cuántas personas procesó."""
    # Se valida todo el roster antes de escribir nada.
    people = load_roster(roster_path)
    if client is None:
        import supabase_admin as client

    courses = client.request("GET", f"courses?select=id&code=eq.{quote(course_code)}")
    if not courses:
        raise SystemExit(f"No existe el curso {course_code!r} (revisa la migración seed_catalogs).")
    course_id = courses[0]["id"]

    if people:
        client.request("POST", "students?on_conflict=id", people,
                       prefer="resolution=merge-duplicates,return=minimal")
        client.request("POST", "course_students?on_conflict=course_id,student_id",
                       [{"course_id": course_id, "student_id": p["id"]} for p in people],
                       prefer="resolution=ignore-duplicates,return=minimal")
    return len(people)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Carga roster.json en students y course_students (Supabase).")
    parser.add_argument("roster", nargs="?", type=Path, default=DEFAULT_ROSTER)
    parser.add_argument("--course", default=DEFAULT_COURSE, help="código del curso (por defecto PILOTO-AFORO)")
    args = parser.parse_args()

    total = seed(args.roster, args.course)
    print(f"Listo: {total} estudiantes cargados e inscritos en {args.course}.")
