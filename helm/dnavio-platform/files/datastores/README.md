# Datastore init scripts

Loaded into ConfigMaps by `templates/postgres/configmap.yaml` and
`templates/mongo/configmap.yaml`, and executed by the official images'
`docker-entrypoint-initdb.d` mechanism — **once, on first start of an empty
data volume**. Changing a script here does not alter an already-initialised
database; schema changes to a running store need a migration.

| File | Owner | Source |
|------|-------|--------|
| `postgres/001_schema.sql` | T4.2 (DML/FRS) | `D-NAVIO-Project/d-navio-t4.2` → `db/postgres/001_schema.sql` @ `f3f4034` |
| `mongo/10-t42-init.js` | T4.2 (DML/FRS) | `D-NAVIO-Project/d-navio-t4.2` → `db/mongo/init.js` @ `f3f4034` |
| `mongo/00-app-user.js` | Platform | Creates the least-privilege application user |

The T4.2 files are byte-identical copies. Do not edit them here: change them
in `d-navio-t4.2` and re-sync, updating the commit reference above.
