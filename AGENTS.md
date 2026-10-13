# AGENTS.md — aforo-db

Este archivo le dice a los asistentes de IA cómo comportarse dentro de este repositorio.

## Qué es este repositorio

`aforo-db` define, como infraestructura como código, la base de datos del sistema de aforo: en v1 la tabla DynamoDB que usa `aforo-backend`; en v2 el esquema PostgreSQL de Supabase (tablas, triggers, funciones y políticas RLS). **No** contiene lógica de negocio ni código de aplicación — solo la definición de la infraestructura.

Antes de proponer cambios, lee `PRD.md` y `ARCHITECTURE.md` (en inglés), especialmente el diseño de tabla única (single-table design) y los patrones de acceso ya definidos.

> **Versión 2 en curso (oct 2026):** la base de datos pasa a PostgreSQL en Supabase, con esquema relacional, login y RLS (`ARCHITECTURE.md` sección 7, `TASKS.md` tasks 7-10). Mientras dure la migración conviven las dos versiones: las reglas marcadas **(v2)** aplican al trabajo en `supabase/`.

## Reglas de git (obligatorias, sin excepciones)

1. **Una rama por task.** Los asistentes de IA pueden hacer commit y push, pero **solo en ramas de trabajo**, nunca en `main`. Nombre de la rama: `task-<n>-<descripcion-corta>` (ej. `task-7-supabase-schema`). Si la task depende de otra que aún no está en `main`, la rama sale de la rama de esa task (PRs encadenados).
2. **Un commit por subtarea**, con el mensaje exacto de `TASKS.md` y el sufijo `[x.y]`; en ese mismo commit se marca `[x]` en `TASKS.md`.
3. **Prohibido para la IA:** `git merge`, `git rebase`, `git reset --hard`, `git tag`, `push --force` y push a `main`; tampoco fusionar PRs. Puede **abrir** el PR de la rama hacia `main` (o hacia la rama de la que depende); la revisión y el merge los hace siempre una persona.
4. **Nadie puede tener `Co-Authored-By` de una IA.** Ningún commit ni PR puede incluir líneas `Co-Authored-By: Claude ...` (ni de ninguna otra IA), `noreply@anthropic.com` ni "Generated with Claude Code". El autor es el usuario configurado en git.
5. **Cómo se hace cumplir:**
   - `.githooks/commit-msg` rechaza localmente esos mensajes. Actívalo una vez por clon: `git config core.hooksPath .githooks`. No se usa `--no-verify`.
   - `.github/workflows/no-ai-coauthor.yml` falla en GitHub si algún commit del historial los tiene.
   - `.claude/settings.json` desactiva la coautoría automática de Claude Code y bloquea merge, rebase, force push y push a `main`.
   No desactives ni modifiques estos tres archivos sin que el usuario lo pida explícitamente.

## Reglas para el agente

1. **No crees recursos manualmente en la consola de AWS.** Todo cambio a la base de datos v1 debe expresarse como código (plantilla SAM o Terraform) en `infra/`, para que sea reproducible. **(v2)** Igual en Supabase: todo cambio de esquema, función o política va como migración SQL en `supabase/migrations/`, nunca editando tablas a mano en el dashboard.
2. **Mantente en los niveles gratuitos.** v1: "Always Free" de DynamoDB. **(v2)** Plan Free de Supabase (500 MB de base de datos; el proyecto se pausa tras una semana sin uso). Si algo genera costo, avísalo antes.
3. **(v2) Modelo relacional.** Las ~13 tablas de `ARCHITECTURE.md` sección 7.3 son el modelo acordado. No las fusiones de nuevo en una tabla ni agregues tablas de relleno: cada tabla nueva debe tener un uso real en el sistema. La tabla única de v1 se respeta solo mientras siga desplegada.
4. **Cualquier cambio a columnas de `events`, `students` o `classrooms` (o a los items de v1) debe avisarse explícitamente** a `aforo-vision` (que escribe eventos), `aforo-frontend` (que los lee) y `aforo-backend`.
5. **(v2) Seguridad obligatoria en cada migración:** RLS activado en toda tabla nueva con políticas por rol (`admin`, `teacher`, `viewer`); `anon` sin acceso a tablas; funciones `security definer` con `set search_path = ''`; la `service_role` key nunca en el frontend ni en git; ningún dato biométrico en la base de datos. Después de cada migración, correr los advisors de Supabase.
6. **Textos para humanos (comentarios de documentación) van en español**; nombres de recursos, atributos y claves van en inglés, siguiendo el resto del proyecto.

## Herramientas que el agente puede usar libremente

- Lectura/escritura de archivos dentro de este repositorio.
- Búsqueda web para verificar límites y precios vigentes del nivel gratuito de DynamoDB.

## Herramientas que requieren confirmación explícita del usuario

- Cualquier despliegue real (`sam deploy`, `terraform apply`, o equivalente) — el usuario debe confirmar antes de crear recursos en su cuenta de AWS.
- **(v2)** Aplicar migraciones al proyecto real de Supabase, crear o revocar llaves de dispositivo y cambiar roles de usuarios.
- Eliminar o recrear la tabla (`DeleteTable`), ya que eso borraría los datos del piloto.
