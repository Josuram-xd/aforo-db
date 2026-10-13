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

## 8. Versión 2 (octubre 2026)

Después de la primera entrega, el profe pidió un modelo de datos más completo, registro e inicio de sesión, y que los datos no queden públicos. Esta pieza cambia así:

**Objetivo v2:** definir en PostgreSQL (Supabase) el modelo relacional del sistema, con usuarios, roles y seguridad por fila, de forma reproducible con migraciones SQL.

**Requisitos funcionales v2:**
1. Usuarios con registro abierto, inicio de sesión con correo o Google, y tres roles: `admin`, `teacher` y `viewer`. Toda cuenta nueva entra como `viewer`.
2. Modelo relacional de 13 tablas: roles, perfiles, roles por usuario, cursos, salones (con aforo máximo), cámaras, estudiantes, estudiantes por curso, sesiones de clase, eventos, asistencia, alertas y auditoría.
3. Hoy hay un curso, un salón y dos cámaras, pero el modelo permite agregar más sin cambiar el esquema.
4. Cada evento actualiza solo el aforo del salón, el estado del estudiante y su asistencia en la sesión activa. Si se supera el aforo máximo, se abre una alerta.
5. Alerta automática cuando una cámara deja de reportarse.
6. Auditoría de cambios (quién cambió qué y cuándo) y de accesos a datos sensibles.
7. Nadie sin sesión puede leer datos. `viewer` no ve nombres de estudiantes. Solo `aforo-vision`, con su llave de dispositivo, puede registrar eventos.

**No-objetivos v2:** tabla de consentimientos (las autorizaciones firmadas se guardan en físico); datos biométricos en la base de datos (los embeddings no salen del nodo de visión).

**Restricciones v2:** plan gratis de Supabase en una cuenta del equipo; toda modificación como migración en `supabase/migrations/`.

**Métricas de éxito v2:** los advisors de seguridad de Supabase sin errores; los tests de RLS en verde; el dashboard muestra un cambio de aforo en menos de 2 s después del evento.
