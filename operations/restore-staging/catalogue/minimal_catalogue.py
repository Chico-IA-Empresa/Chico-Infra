"""PRIVATE CANDIDATE: fixed PG16 catalogue reads; no connection/AWS/restore on import.

Session adapter, native SQL validation and operational approval are separate gates.
Never expose collected identifiers, JSON, stderr or private output hashes to a model.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat

SOURCE_SHA256 = '7ac1be9389a13451de43f559f112ac9736f7b179dbfd5b8619c95f28230e3bb6'
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_RECORDS = 100_000
TRANSACTION = ("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; "
               "SET LOCAL search_path = pg_catalog; "
               "SET LOCAL statement_timeout = '15s'; "
               "SET LOCAL lock_timeout = '2s'; "
               "SET LOCAL idle_in_transaction_session_timeout = '30s';")
GATE_SQL = """SELECT pg_catalog.jsonb_build_object(
 'version', pg_catalog.current_setting('server_version_num')::integer,
 'database', pg_catalog.current_database(),
 'systemIdentifier', s.system_identifier::text,
 'recovery', pg_catalog.pg_is_in_recovery(),
 'paused', CASE WHEN pg_catalog.pg_is_in_recovery() THEN pg_catalog.pg_is_wal_replay_paused() ELSE false END,
 'pauseState', CASE WHEN pg_catalog.pg_is_in_recovery() THEN pg_catalog.pg_get_wal_replay_pause_state() ELSE 'not in recovery' END,
 'readOnly', pg_catalog.current_setting('transaction_read_only'))
FROM pg_catalog.pg_control_system() AS s;"""

# Every column is enumerated. Never interpolate recovered identifiers into SQL.
# No pg_stats/statistic, pg_authid, definitions, connection options or business rows.
USER_RELATIONS = """FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
AND c.relkind IN ('r','p','v','m','f','S')"""


def aggregate(select):
    # to_jsonb applies only to this explicit built-in record, never to a user type.
    return ("SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(q)), '[]'::jsonb) "
            "FROM (" + select + ") AS q;")


QUERIES = (
    ('C1', aggregate("""SELECT d.oid::bigint AS oid, d.datname::text AS name,
      d.encoding, d.datcollate AS collate, d.datctype AS ctype,
      d.datlocprovider::text AS provider, d.daticulocale AS icuLocale,
      d.datcollversion AS collationVersion, (d.daticurules IS NOT NULL) AS hasIcuRules,
      d.datistemplate AS template, d.datallowconn AS allowConnections
      FROM pg_catalog.pg_database AS d
      ORDER BY d.oid""")),
    ('C2', aggregate("""SELECT e.oid::bigint AS oid, e.extname::text AS name,
      e.extversion AS version, e.extnamespace::bigint AS namespace
      FROM pg_catalog.pg_extension AS e ORDER BY e.oid""")),
    ('C3', aggregate("""SELECT c.oid::bigint AS oid, n.oid::bigint AS namespace,
      n.nspname::text AS schema, c.relname::text AS name, c.relkind::text AS kind,
      c.relpersistence::text AS persistence, c.relispartition AS partition,
      c.relrowsecurity AS rowSecurity, c.relforcerowsecurity AS forceRowSecurity
      """ + USER_RELATIONS + " ORDER BY c.oid")),
    ('C4', aggregate("""SELECT a.attrelid::bigint AS relation, a.attnum::integer AS number,
      a.attname::text AS name, a.atttypid::bigint AS type, a.atttypmod AS modifier,
      a.attnotnull AS notNull, a.attidentity::text AS identity,
      a.attgenerated::text AS generated, a.atthasdef AS hasDefault,
      a.attisdropped AS dropped, t.typname::text AS typeName,
      t.typtype::text AS typeKind, t.typcategory::text AS typeCategory
      FROM pg_catalog.pg_attribute AS a
      JOIN pg_catalog.pg_class AS c ON c.oid=a.attrelid
      JOIN pg_catalog.pg_namespace AS n ON n.oid=c.relnamespace
      LEFT JOIN pg_catalog.pg_type AS t ON t.oid=a.atttypid
      WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      AND c.relkind IN ('r','p','v','m','f','S') AND a.attnum>0
      ORDER BY a.attrelid,a.attnum""")),
    ('C5', aggregate("""SELECT k.oid::bigint AS oid, k.contype::text AS kind,
      k.conrelid::bigint AS relation, k.contypid::bigint AS domain,
      k.confrelid::bigint AS foreignRelation, k.conkey AS columns,
      k.confkey AS foreignColumns, k.convalidated AS validated,
      k.condeferrable AS deferrable, k.condeferred AS deferred
      FROM pg_catalog.pg_constraint AS k
      JOIN pg_catalog.pg_namespace AS n ON n.oid=k.connamespace
      WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      ORDER BY k.oid""")),
    ('C6', aggregate("""SELECT i.indexrelid::bigint AS oid, i.indrelid::bigint AS relation,
      i.indisunique AS unique, i.indisprimary AS primary, i.indisvalid AS valid,
      i.indisready AS ready, i.indnatts::integer AS attributes,
      i.indnkeyatts::integer AS keyAttributes, i.indkey::smallint[] AS columns,
      (i.indexprs IS NOT NULL) AS hasExpressions, (i.indpred IS NOT NULL) AS hasPredicate
      FROM pg_catalog.pg_index AS i
      JOIN pg_catalog.pg_class AS c ON c.oid=i.indrelid
      JOIN pg_catalog.pg_namespace AS n ON n.oid=c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      ORDER BY i.indexrelid""")),
    ('C7', """SELECT pg_catalog.jsonb_build_object(
      'functions', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_proc AS p
         JOIN pg_catalog.pg_namespace AS n ON n.oid=p.pronamespace
         WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')),
      'triggers', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_trigger),
      'eventTriggers', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_event_trigger),
      'foreignServers', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_foreign_server),
      'userMappings', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_user_mapping),
      'subscriptions', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_subscription),
      'roleDatabaseSettings', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_db_role_setting),
      'largeObjectMetadata', (SELECT pg_catalog.count(*) FROM pg_catalog.pg_largeobject_metadata));"""),
)
FIELDS = {
    'C1': {'oid','name','encoding','collate','ctype','provider','iculocale','collationversion','hasicurules','template','allowconnections'},
    'C2': {'oid','name','version','namespace'},
    'C3': {'oid','namespace','schema','name','kind','persistence','partition','rowsecurity','forcerowsecurity'},
    'C4': {'relation','number','name','type','modifier','notnull','identity','generated','hasdefault','dropped','typename','typekind','typecategory'},
    'C5': {'oid','kind','relation','domain','foreignrelation','columns','foreigncolumns','validated','deferrable','deferred'},
    'C6': {'oid','relation','unique','primary','valid','ready','attributes','keyattributes','columns','hasexpressions','haspredicate'},
    'C7': {'functions','triggers','eventTriggers','foreignServers','userMappings','subscriptions','roleDatabaseSettings','largeObjectMetadata'},
}
BOOL_FIELDS = {'hasicurules','template','allowconnections','partition','rowsecurity','forcerowsecurity','notnull','hasdefault','dropped',
               'validated','deferrable','deferred','unique','primary','valid','ready','hasexpressions','haspredicate'}
INT_FIELDS = {'oid','namespace','encoding','relation','number','type','modifier','domain','foreignrelation',
              'attributes','keyattributes'}
ARRAY_FIELDS = {'columns','foreigncolumns'}
NULL_FIELDS = {'iculocale','collationversion','typename','typekind','typecategory','columns','foreigncolumns'}


class CatalogueError(Exception):
    """Fixed error code only: never include SQL, identifiers or values in str()."""
    def __init__(self, code):
        super().__init__(code)


def query_plan_sha256():
    return hashlib.sha256(json.dumps([TRANSACTION, GATE_SQL, QUERIES],
                                    separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogueError('duplicate-json-key')
        result[key] = value
    return result


def decode(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_RESPONSE_BYTES:
        raise CatalogueError('response-bound')
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(CatalogueError('json-constant')))
    except (UnicodeError, ValueError, RecursionError):
        raise CatalogueError('invalid-json') from None


def validate_payload(query_id, value):
    if query_id == 'C7':
        if not isinstance(value, dict) or set(value) != FIELDS[query_id] or any(type(v) is not int or v < 0 for v in value.values()):
            raise CatalogueError('surface-count-schema')
        return value
    if not isinstance(value, list) or len(value) > MAX_RECORDS or (query_id == 'C1' and not value):
        raise CatalogueError('catalogue-record-bound')
    for row in value:
        if not isinstance(row, dict) or set(row) != FIELDS[query_id]:
            raise CatalogueError('catalogue-field-allowlist')
        for key, field in row.items():
            if field is None and key in NULL_FIELDS:
                continue
            if key in BOOL_FIELDS:
                valid = type(field) is bool
            elif key in INT_FIELDS:
                valid = type(field) is int and -(2**31) <= field < 2**63
            elif key in ARRAY_FIELDS:
                valid = isinstance(field, list) and len(field) <= 32 and all(type(v) is int and 0 <= v <= 32767 for v in field)
            else:
                try:
                    valid = isinstance(field, str) and len(field.encode('utf-8')) <= 1024
                except UnicodeError:
                    valid = False
            if not valid:
                raise CatalogueError('catalogue-field-type')
    return value


def validate_gate(value, context):
    if not isinstance(value, dict) or set(value) != {'version','database','systemIdentifier','recovery','paused','pauseState','readOnly'}:
        raise CatalogueError('recovery-gate-schema')
    if (type(value['version']) is not int or not 160000 <= value['version'] < 170000 or
            value['version'] != context['serverVersionNum'] or value['database'] != context['database'] or
            value['systemIdentifier'] != context['systemIdentifier'] or value['recovery'] is not True or
            value['paused'] is not True or value['pauseState'] != 'paused' or value['readOnly'] != 'on'):
        raise CatalogueError('recovery-gate-failed')


def validate_context(context):
    if (not isinstance(context, dict) or set(context) != {'sourceManifestSHA256','queryPlanSHA256','database','systemIdentifier','serverVersionNum'} or
            context['sourceManifestSHA256'] != SOURCE_SHA256 or context['queryPlanSHA256'] != query_plan_sha256() or
            not isinstance(context['database'], str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}', context['database']) or
            not isinstance(context['systemIdentifier'], str) or not re.fullmatch(r'[1-9][0-9]{0,19}', context['systemIdentifier']) or
            type(context['serverVersionNum']) is not int or not 160000 <= context['serverVersionNum'] < 170000):
        raise CatalogueError('catalogue-context')


def write_new(directory, name, value):
    raw = (json.dumps(value, separators=(',', ':'), ensure_ascii=True, allow_nan=False) + '\n').encode()
    fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def collect(session, directory, context):
    """Explicit caller only. Session adapter must enforce bounds BEFORE buffering.

    Caller must already have human/source/IAM/lease/image/host approvals. This
    library is no authorization engine and supplies no live connection adapter.
    Session.execute accepts only TRANSACTION/ROLLBACK; query returns bounded UTF8
    bytes for one fixed SQL statement in the SAME live read-only transaction.
    """
    validate_context(context)
    try:
        directory = Path(directory)
        if not directory.is_absolute() or directory.exists() or directory.is_symlink():
            raise CatalogueError('fresh-private-directory')
        for parent_path in directory.parents:
            if parent_path.is_symlink():
                raise CatalogueError('symlink-parent')
        parent = directory.parent.stat()
        if os.name == 'posix' and (parent.st_uid != os.geteuid() or stat.S_IMODE(parent.st_mode) != 0o700):
            raise CatalogueError('private-parent')
        directory.mkdir(mode=0o700)
    except (OSError, TypeError, ValueError):
        raise CatalogueError('private-directory-unavailable') from None
    completed = []
    begun = False
    try:
        begun = True
        session.execute(TRANSACTION)
        validate_gate(decode(session.query(GATE_SQL, MAX_RESPONSE_BYTES)), context)
        for query_id, sql in QUERIES:
            # Paused state is rechecked before each read and once after all reads.
            validate_gate(decode(session.query(GATE_SQL, MAX_RESPONSE_BYTES)), context)
            payload = validate_payload(query_id, decode(session.query(sql, MAX_RESPONSE_BYTES)))
            reference = write_new(directory, query_id + '.json', payload)
            completed.append({'query': query_id, **reference})
        validate_gate(decode(session.query(GATE_SQL, MAX_RESPONSE_BYTES)), context)
        session.execute('ROLLBACK;')
        begun = False
        write_new(directory, 'manifest-private.json', {'schema': 1, 'context': context, 'files': completed,
                  'catalogueComplete': True, 'businessRowsQueried': False, 'dataTreatmentApproved': False,
                  'relationsAndSurfaceCoverage': 'single-reviewed-database-only',
                  'realSourceIntegrityProvenByThisCollector': False})
        return {'catalogueComplete': True, 'fixedQueriesCompleted': len(completed), 'privateOutputOnly': True}
    except Exception:
        if begun:
            try:
                session.execute('ROLLBACK;')
            except Exception:
                pass
        try:
            write_new(directory, 'failure-private.json', {'catalogueComplete': False,
                      'completedQueryIds': [r['query'] for r in completed], 'partialPreserved': True})
        except OSError:
            pass
        raise CatalogueError('catalogue-incomplete') from None
