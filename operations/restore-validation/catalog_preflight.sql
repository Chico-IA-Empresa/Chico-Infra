-- PG16 metadata only. Run in the recovered, network-none clone BEFORE querying
-- application relations/functions, restoring logical SQL, or enabling writers.
-- Never select role passwords, subscription conninfo, FDW options, job commands,
-- routine bodies, trigger arguments, table rows, or arbitrary setting values.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL statement_timeout = '60s';
WITH user_relations AS (
  SELECT c.oid, n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname !~ '^pg_toast' AND n.nspname !~ '^pg_temp_'
)
SELECT json_build_object(
  'version', 1,
  'serverVersionNum', current_setting('server_version_num')::integer,
  'inRecovery', pg_is_in_recovery(),
  'database', json_build_object(
    'encoding', pg_encoding_to_char(d.encoding), 'collation', d.datcollate,
    'ctype', d.datctype, 'localeProvider', d.datlocprovider,
    'icuLocale', d.daticulocale, 'recordedCollationVersion', d.datcollversion,
    'actualCollationVersion', pg_database_collation_actual_version(d.oid)
  ),
  'preloads', json_build_object(
    'shared', current_setting('shared_preload_libraries'),
    'session', current_setting('session_preload_libraries'),
    'local', current_setting('local_preload_libraries')
  ),
  'externalConfigurationPresent', json_build_object(
    'archiveCommand', current_setting('archive_command') <> '',
    'primaryConninfo', current_setting('primary_conninfo') <> ''
  ),
  'extensions', (SELECT coalesce(json_agg(e ORDER BY e.extname), '[]') FROM
    (SELECT extname, extversion FROM pg_extension) e),
  'triggers', (SELECT coalesce(json_agg(t ORDER BY t.schema, t.table_name, t.name), '[]') FROM
    (SELECT r.nspname AS schema, r.relname AS table_name, t.tgname AS name,
      t.tgenabled AS enabled, t.tgtype AS type_bits, pn.nspname AS function_schema,
      p.proname AS function_name, p.prosecdef AS security_definer
     FROM pg_trigger t JOIN user_relations r ON r.oid=t.tgrelid
     JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace
     WHERE NOT t.tgisinternal) t),
  'eventTriggers', (SELECT coalesce(json_agg(t ORDER BY t.name), '[]') FROM
    (SELECT evtname AS name, evtevent AS event, evtenabled AS enabled
     FROM pg_event_trigger) t),
  'rowSecurity', (SELECT coalesce(json_agg(r ORDER BY r.schema, r.table_name), '[]') FROM
    (SELECT r.nspname AS schema, r.relname AS table_name,
      r.relrowsecurity AS enabled, r.relforcerowsecurity AS forced,
      (SELECT count(*) FROM pg_policy p WHERE p.polrelid=r.oid) AS policies
     FROM user_relations r WHERE r.relrowsecurity OR r.relforcerowsecurity
       OR EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=r.oid)) r),
  'securityDefinerRoutines', (SELECT coalesce(json_agg(p ORDER BY p.schema, p.name, p.arguments), '[]') FROM
    (SELECT n.nspname AS schema, p.proname AS name,
      pg_get_function_identity_arguments(p.oid) AS arguments, l.lanname AS language
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     JOIN pg_language l ON l.oid=p.prolang
     WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog', 'information_schema')) p),
  'foreignTables', (SELECT count(*) FROM pg_foreign_table f JOIN user_relations r ON r.oid=f.ftrelid),
  'subscriptions', (SELECT count(*) FROM pg_subscription s WHERE s.subdbid=d.oid),
  'enabledSubscriptions', (SELECT count(*) FROM pg_subscription s WHERE s.subdbid=d.oid AND s.subenabled),
  'publicDatabasePrivileges', (SELECT coalesce(json_agg(a.privilege_type ORDER BY a.privilege_type), '[]')
    FROM aclexplode(coalesce(d.datacl, acldefault('d',d.datdba))) a WHERE a.grantee=0),
  'devRoleFlags', (SELECT coalesce(json_agg(r ORDER BY r.name), '[]') FROM
    (SELECT rolname AS name, rolsuper AS superuser, rolcreatedb AS create_db,
      rolcreaterole AS create_role, rolreplication AS replication,
      rolbypassrls AS bypass_rls, rolcanlogin AS login
     FROM pg_roles WHERE rolname IN
       ('dev_admin','dev_migrator','dev_api','dev_workers','dev_backup','dev_proof')) r)
)
FROM pg_database d WHERE d.datname=current_database();
ROLLBACK;
