# Cuartel · Inventario de Bomberos Voluntarios de Corral de Bustos

Aplicación web en React, TypeScript y Supabase para administrar el padrón, unidades físicas, asignaciones, uniformes y movimientos del cuartel.

## Requisitos y puesta en marcha

- Node.js compatible con Vite 6 y npm.
- Un proyecto Supabase con el esquema y las migraciones de este repositorio.
- Una cuenta creada por el administrador en Supabase Auth e incluida en `authorized_users`. El registro público debe permanecer desactivado.

```powershell
npm install
Copy-Item .env.example .env.local
# Completar VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY en .env.local
npm run dev
```

Para validar la compilación de producción, ejecutar `npm run build`.

## Seguridad y configuración

- El cliente utiliza únicamente `VITE_SUPABASE_URL` y la clave pública `VITE_SUPABASE_ANON_KEY`.
- Nunca guardar ni publicar una clave `service_role` en el frontend, `.env.local`, GitHub o documentación.
- `.env.local` está excluido de Git. Configurar las variables de entorno por separado en cada entorno de despliegue.
- Las tablas mantienen RLS; las operaciones de inventario se ejecutan mediante funciones autorizadas de Supabase.
- No habilitar registros públicos. El administrador crea y autoriza las cuentas desde Supabase.

## Datos y operaciones

- Las fichas importadas se conservan como fuente histórica en `legacy_import_rows`. Las hojas generales son resúmenes y no se vuelven a importar como inventario.
- Las unidades físicas viven en `equipment_units`; las entregas se registran en `assignments`; las acciones auditadas se conservan en `movements`.
- Los totales del inventario se calculan desde las unidades y asignaciones. Una asignación, devolución, pérdida o baja se procesa mediante RPC para mantener coherencia.
- Gala y Fajina organizan unidades físicas existentes mediante plantillas; no duplican el stock.
- La baja de un tipo de elemento es lógica: retira sus unidades activas, cierra asignaciones abiertas y conserva registros e historial. Los tipos archivados se pueden restaurar; sus unidades permanecen dadas de baja hasta que se registren nuevamente.

## Migraciones de Supabase

Los archivos en `supabase/migrations/` son migraciones aditivas y forman parte del control de versiones. En una instalación existente, revisar qué migraciones ya se aplicaron y ejecutar solamente las pendientes, una sola vez, desde el SQL Editor de Supabase. No volver a ejecutar una migración ya aplicada ni borrar/recrear tablas para actualizar el proyecto.

La migración `20261025_equipment_type_archive.sql` agrega `equipment_types.archived_at` y las RPC autorizadas `archive_equipment_type` y `restore_equipment_type`. No elimina ni reemplaza datos. Debe aplicarse antes de usar la baja de tipos en la interfaz. La restauración del tipo no reactiva unidades ni reabre asignaciones.

## Flujo sugerido

1. Iniciar sesión con la cuenta autorizada.
2. Usar **Bomberos** para consultar fichas y asignaciones activas.
3. Usar **Inventario** para revisar cantidades, responsables, estados y unidades disponibles.
4. Usar **Uniformes** para administrar las plantillas Gala/Fajina y sus componentes.
5. Confirmar cuidadosamente devoluciones, pérdidas y bajas; cada operación conserva su historial.
6. Para quitar un tipo de elemento de la vista de inventario, usar el botón de papelera, revisar el impacto y escribir un motivo. Los tipos dados de baja quedan en el desplegable de archivo.

## Respaldo

Antes de cambios operativos importantes, exportar o respaldar los datos desde las herramientas de Supabase. Las migraciones y el código no contienen copias de los datos del cuartel.
