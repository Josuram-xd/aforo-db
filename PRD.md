# PRD — aforo-db

**Repositorio:** `aforo-db`
**Última actualización:** 26 de septiembre de 2026

## 1. Problema

`aforo-backend` necesita un lugar donde guardar los eventos de entrada/salida y la lista de personas enroladas, sin tener que administrar un servidor de base de datos.

## 2. Objetivo

Definir y aprovisionar (como infraestructura como código) la base de datos que usa el piloto: una tabla DynamoDB capaz de guardar eventos y consultarlos por rango de tiempo, y de saber el estado actual (dentro/fuera) de cada persona enrolada.

## 3. No-objetivos

- No contiene lógica de negocio (eso vive en `aforo-backend`).
- No se conecta directamente a `aforo-vision` ni a `aforo-frontend` — solo `aforo-backend` la usa.
- No necesita replicación multi-región ni alta disponibilidad — es un piloto de un día.

## 4. Usuarios

- `aforo-backend`, como único cliente que lee/escribe esta base de datos.
- Josuram, para desplegarla e inspeccionarla durante el piloto.

## 5. Requisitos funcionales

1. Guardar cada evento resuelto (`eventId`, `personId`, `direction`, cámaras, `confidence`, `method`, `timestamp`).
2. Permitir consultar eventos por rango de tiempo (`from`/`to`).
3. Guardar el roster de personas enroladas (`personId`, `name`) junto con su estado actual (`IN`/`OUT`) y el timestamp de su último evento.
4. Permitir leer y actualizar el aforo actual de forma eficiente, como un contador atómico (entradas − salidas) que incluye también a las personas no identificadas (`BODY_ONLY`). No se deriva del conteo de personas con estado `IN` (ver ADR-004 en `ARCHITECTURE.md`).

## 6. Restricciones

- Debe usar el nivel "Always Free" de DynamoDB (sin costo, independiente del crédito de cuenta nueva de AWS).
- Debe definirse como infraestructura como código (no creada manualmente por consola) para que sea reproducible.
- Presupuesto: 0 COP adicionales — esta pieza no debe generar costo por sí misma.

## 7. Métricas de éxito del piloto

- La tabla soporta el volumen de un día de clase (decenas de eventos) sin fricción.
- Las consultas que necesita `aforo-backend` (por rango de tiempo, por persona, aforo actual) responden en milisegundos.
