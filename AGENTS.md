# AGENTS.md — aforo-db

Este archivo le dice a los asistentes de IA cómo comportarse dentro de este repositorio.

## Qué es este repositorio

`aforo-db` define, como infraestructura como código, la tabla DynamoDB que usa `aforo-backend` para guardar eventos de entrada/salida y el estado de las personas enroladas. **No** contiene lógica de negocio ni código de aplicación — solo la definición de la infraestructura.

Antes de proponer cambios, lee `PRD.md` y `ARCHITECTURE.md` (en inglés), especialmente el diseño de tabla única (single-table design) y los patrones de acceso ya definidos.

## Reglas de git (obligatorias, sin excepciones)

1. **Ninguna IA puede hacer commit ni push.** Ningún asistente (Claude Code, Cursor, Copilot, Codex, Gemini, etc.) ejecuta `git commit`, `git push`, `git merge`, `git rebase`, `git tag` ni `git reset`, ni crea o fusiona PRs, ni por terminal ni por herramientas MCP/API de GitHub. El agente deja los cambios en el árbol de trabajo y, si ayuda, **propone** el mensaje de commit (formato de `TASKS.md`); el commit y el push los hace siempre una persona.
2. **Nadie puede tener `Co-Authored-By` de una IA.** Ningún commit ni PR puede incluir líneas `Co-Authored-By: Claude ...` (ni de ninguna otra IA), `noreply@anthropic.com` ni "Generated with Claude Code". Esto aplica también a las personas: si el mensaje propuesto trae esa línea, se borra antes de commitear.
3. **Cómo se hace cumplir:**
   - `.githooks/commit-msg` rechaza localmente esos mensajes. Actívalo una vez por clon: `git config core.hooksPath .githooks`.
   - `.github/workflows/no-ai-coauthor.yml` falla en GitHub si algún commit del historial los tiene.
   - `.claude/settings.json` desactiva la coautoría automática de Claude Code y le bloquea `git commit`/`git push`.
   No desactives ni modifiques estos tres archivos sin que el usuario lo pida explícitamente.

## Reglas para el agente

1. **No crees recursos manualmente en la consola de AWS.** Todo cambio a la base de datos debe expresarse como código (plantilla SAM o Terraform) en `infra/`, para que sea reproducible.
2. **Mantente dentro del nivel "Always Free" de DynamoDB.** No agregues configuraciones que generen costo (por ejemplo, capacidad aprovisionada alta, réplicas globales, backups continuos innecesarios) sin avisar explícitamente que eso rompe el presupuesto de 0 COP adicionales de esta pieza.
3. **Respeta el diseño de tabla única.** No propongas dividir en múltiples tablas sin una razón concreta — el volumen de datos de este piloto (un curso, un día) no lo justifica.
4. **Cualquier cambio a los atributos de un item (eventos o personas) debe avisarse explícitamente a `aforo-backend`**, ya que ese repo depende de esta forma de los datos para sus handlers.
5. **No agregues autenticación, IAM roles nuevos, ni políticas de acceso** salvo que el usuario lo pida — mantén el alcance mínimo necesario para que `aforo-backend` pueda leer/escribir la tabla.
6. **Textos para humanos (comentarios de documentación) van en español**; nombres de recursos, atributos y claves van en inglés, siguiendo el resto del proyecto.

## Herramientas que el agente puede usar libremente

- Lectura/escritura de archivos dentro de este repositorio.
- Búsqueda web para verificar límites y precios vigentes del nivel gratuito de DynamoDB.

## Herramientas que requieren confirmación explícita del usuario

- Cualquier despliegue real (`sam deploy`, `terraform apply`, o equivalente) — el usuario debe confirmar antes de crear recursos en su cuenta de AWS.
- Eliminar o recrear la tabla (`DeleteTable`), ya que eso borraría los datos del piloto.
