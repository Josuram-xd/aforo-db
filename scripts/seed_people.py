"""Carga el roster del piloto en la tabla AforoPilot.

Por cada persona del roster crea el item PERSON#<personId> / PROFILE con
status = OUT. Solo guarda personId y name: cualquier otro campo del roster
(por ejemplo, datos biométricos) se ignora y nunca llega a DynamoDB.

Uso:
    python scripts/seed_people.py [ruta_del_roster]

Por defecto lee scripts/roster.json. Variables opcionales: TABLE_NAME
(por defecto AforoPilot) y REGION (por defecto us-east-1).
"""

import json
import os
import sys
import uuid
from pathlib import Path

TABLE_NAME = os.environ.get("TABLE_NAME", "AforoPilot")
REGION = os.environ.get("REGION", "us-east-1")
DEFAULT_ROSTER = Path(__file__).parent / "roster.json"


def load_roster(roster_path):
    """Lee el roster y valida que cada persona tenga personId y name sin repetir."""
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
        # El contrato de eventos (aforo-backend) define personId como UUID: un id como
        # "p001" se guardaría aquí, pero aforo-backend rechazaría sus eventos con 400.
        try:
            uuid.UUID(person_id)
        except ValueError:
            raise ValueError(f"Persona #{i}: personId debe ser un UUID, no {person_id!r}.") from None
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"Persona #{i} ({person_id}): falta name o no es texto.")
        if person_id in seen:
            raise ValueError(f"personId repetido en el roster: {person_id}")
        seen.add(person_id)
        people.append({"personId": person_id, "name": name.strip()})
    return people


def seed(roster_path, table=None):
    """Crea el perfil de cada persona del roster con status = OUT.

    Las personas que ya existen en la tabla se saltan, para no pisar su
    estado si el script se vuelve a correr durante el piloto.
    Devuelve una tupla (creadas, existentes).
    """
    # Se valida todo el roster antes de escribir nada.
    people = load_roster(roster_path)

    if table is None:
        import boto3

        table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE_NAME)

    from botocore.exceptions import ClientError

    created, existing = 0, 0
    for person in people:
        try:
            table.put_item(
                Item={
                    "PK": f"PERSON#{person['personId']}",
                    "SK": "PROFILE",
                    "personId": person["personId"],
                    "name": person["name"],
                    "status": "OUT",
                },
                ConditionExpression="attribute_not_exists(PK)",
            )
            created += 1
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            existing += 1
            print(f"Ya existe, se salta: {person['personId']}")
    return created, existing


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ROSTER
    created, existing = seed(path)
    print(f"Tabla {TABLE_NAME}: {created} personas creadas, {existing} ya existían.")
