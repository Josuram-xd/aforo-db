"""Deja la tabla AforoPilot lista para un nuevo día del piloto.

Borra todos los eventos (EVENT#<fecha>), pone el contador AFORO / CURRENT
en 0 y deja a todas las personas en status = OUT, sin lastEventAt. El roster
(los PROFILE) se conserva: no hace falta volver a correr seed_people.py.
Se usa después del ensayo y antes del día real.

Uso:
    python scripts/reset_pilot.py          # pide confirmación
    python scripts/reset_pilot.py --yes    # sin confirmación

Variables opcionales: TABLE_NAME (por defecto AforoPilot) y REGION
(por defecto us-east-1).
"""

import argparse
import os

TABLE_NAME = os.environ.get("TABLE_NAME", "AforoPilot")
REGION = os.environ.get("REGION", "us-east-1")
CONFIRMATION_WORD = "BORRAR"


def scan_keys(table):
    """Devuelve las claves (PK, SK) de todos los items de la tabla.

    Solo proyecta PK y SK para gastar la menor capacidad de lectura posible;
    sigue la paginación del Scan hasta el final.
    """
    kwargs = {
        "ProjectionExpression": "PK, SK",
    }
    keys = []
    while True:
        response = table.scan(**kwargs)
        keys.extend({"PK": item["PK"], "SK": item["SK"]} for item in response.get("Items", []))
        if "LastEvaluatedKey" not in response:
            return keys
        kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def reset(table=None):
    """Borra los eventos, pone el aforo en 0 y a todas las personas en OUT.

    Devuelve una tupla (eventos_borrados, personas_reiniciadas).
    """
    if table is None:
        import boto3

        table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE_NAME)

    keys = scan_keys(table)
    event_keys = [k for k in keys if k["PK"].startswith("EVENT#")]
    person_keys = [k for k in keys if k["PK"].startswith("PERSON#") and k["SK"] == "PROFILE"]

    # batch_writer agrupa los borrados de 25 en 25 y reintenta los que DynamoDB no procese.
    with table.batch_writer() as batch:
        for key in event_keys:
            batch.delete_item(Key=key)

    # Contador como recién creado: sin lastUpdated, el dashboard no muestra una hora vieja.
    table.put_item(Item={"PK": "AFORO", "SK": "CURRENT", "currentOccupancy": 0})

    for key in person_keys:
        table.update_item(
            Key=key,
            UpdateExpression="SET #status = :out REMOVE lastEventAt",
            # "status" es palabra reservada de DynamoDB.
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={":out": "OUT"},
        )

    return len(event_keys), len(person_keys)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Reinicia los datos del piloto en la tabla AforoPilot.")
    parser.add_argument("--yes", action="store_true", help="no pedir confirmación")
    args = parser.parse_args()

    if not args.yes:
        print(f"Esto borra TODOS los eventos de la tabla {TABLE_NAME} ({REGION}), pone el aforo en 0")
        print("y deja a todas las personas en OUT. No se puede deshacer.")
        answer = input(f"Escribe {CONFIRMATION_WORD} para continuar: ")
        if answer.strip() != CONFIRMATION_WORD:
            print("Cancelado, no se borró nada.")
            raise SystemExit(1)

    events, people = reset()
    print(f"Tabla {TABLE_NAME}: {events} eventos borrados, aforo en 0, {people} personas en OUT.")
