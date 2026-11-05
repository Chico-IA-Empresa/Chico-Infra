"""Synthetic transport/filesystem tests only. No PostgreSQL, Docker or AWS calls."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'operations/restore-staging/catalogue'))
import minimal_catalogue as catalogue


def context():
    return {'sourceManifestSHA256': catalogue.SOURCE_SHA256,
            'queryPlanSHA256': catalogue.query_plan_sha256(), 'database': 'synthetic_fixture',
            'systemIdentifier': '1234567890123456789', 'serverVersionNum': 160015}


def gate(**changes):
    return {'version': 160015, 'database': 'synthetic_fixture',
            'systemIdentifier': '1234567890123456789', 'recovery': True,
            'paused': True, 'pauseState': 'paused', 'readOnly': 'on', **changes}


def payload(query_id):
    if query_id == 'C7':
        return {key: 0 for key in catalogue.FIELDS[query_id]}
    if query_id == 'C1':
        return [{'oid': 1, 'name': 'synthetic_fixture', 'encoding': 6, 'collate': 'C',
                 'ctype': 'C', 'provider': 'c', 'iculocale': None, 'collationversion': None,
                 'hasicurules': False, 'template': False, 'allowconnections': True}]
    return []


class Session:
    def __init__(self, *, state=None, response=None, begin_error=False, fail_rollback=False):
        self.statements = []
        self.gates = 0
        self.state = state
        self.response = response
        self.begin_error = begin_error
        self.fail_rollback = fail_rollback

    def execute(self, sql):
        self.statements.append(sql)
        if self.begin_error and sql == catalogue.TRANSACTION:
            raise RuntimeError('synthetic-private-error-must-not-escape')
        if self.fail_rollback and sql == 'ROLLBACK;':
            raise RuntimeError('synthetic-private-rollback-error')

    def query(self, sql, bound):
        self.statements.append(sql)
        if bound != catalogue.MAX_RESPONSE_BYTES:
            raise RuntimeError('transport bound missing')
        if sql == catalogue.GATE_SQL:
            self.gates += 1
            return json.dumps(self.state(self.gates) if self.state else gate()).encode()
        query_id = dict((text, key) for key, text in catalogue.QUERIES)[sql]
        value = self.response(query_id) if self.response else payload(query_id)
        return value if isinstance(value, bytes) else json.dumps(value).encode()


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='chico-catalogue-unit-')
        self.parent = Path(self.temporary.name).resolve()
        self.assertEqual(self.parent.parent, Path(tempfile.gettempdir()).resolve())
        self.assertTrue(self.parent.name.startswith('chico-catalogue-unit-'))
        self.addCleanup(self.temporary.cleanup)
        self.output = self.parent / 'fresh'

    def test_complete_only_after_same_session_rollback_and_private_output(self):
        session = Session()
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = catalogue.collect(session, self.output, context())
        self.assertTrue(result['catalogueComplete'])
        self.assertEqual(result['fixedQueriesCompleted'], 7)
        self.assertEqual(session.statements[0], catalogue.TRANSACTION)
        self.assertEqual(session.statements[-1], 'ROLLBACK;')
        self.assertEqual(session.gates, 9)
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), '')
        manifest = json.loads((self.output / 'manifest-private.json').read_text())
        self.assertEqual(len(manifest['files']), 7)
        self.assertFalse(manifest['dataTreatmentApproved'])
        self.assertEqual(manifest['relationsAndSurfaceCoverage'], 'single-reviewed-database-only')

    def test_failed_initial_gate_never_queries_another_catalogue(self):
        for index, change in enumerate([{'paused': False}, {'pauseState': 'pause requested'}, {'recovery': False}, {'readOnly': 'off'},
                                        {'version': 170000}, {'systemIdentifier': 'different'}]):
            session = Session(state=lambda _, change=change: gate(**change))
            destination = self.parent / ('invalid' + str(index))
            with self.assertRaisesRegex(catalogue.CatalogueError, '^catalogue-incomplete$'):
                catalogue.collect(session, destination, context())
            self.assertEqual(session.statements, [catalogue.TRANSACTION, catalogue.GATE_SQL, 'ROLLBACK;'])
            self.assertFalse((destination / 'manifest-private.json').exists())

    def test_resume_mid_collection_preserves_partial_and_stops_next_query(self):
        session = Session(state=lambda number: gate(paused=number < 3))
        with self.assertRaises(catalogue.CatalogueError):
            catalogue.collect(session, self.output, context())
        self.assertTrue((self.output / 'C1.json').is_file())
        self.assertFalse((self.output / 'C2.json').exists())
        self.assertFalse((self.output / 'manifest-private.json').exists())
        self.assertEqual(session.statements[-1], 'ROLLBACK;')

    def test_free_text_or_password_field_refused_without_logging_value(self):
        marker = 'synthetic-canary-no-real-secret'
        def response(query_id):
            return [{**payload('C1')[0], 'password': marker}] if query_id == 'C1' else payload(query_id)
        session = Session(response=response)
        with self.assertRaisesRegex(catalogue.CatalogueError, '^catalogue-incomplete$') as caught:
            catalogue.collect(session, self.output, context())
        self.assertNotIn(marker, str(caught.exception))
        self.assertFalse((self.output / 'C1.json').exists())
        self.assertNotIn(marker, (self.output / 'failure-private.json').read_text())

    def test_identifier_never_becomes_a_query_or_dynamic_sql(self):
        marker = "synthetic_name'; SELECT pg_catalog.pg_sleep(99); --"
        def response(query_id):
            return [{**payload('C1')[0], 'name': marker}] if query_id == 'C1' else payload(query_id)
        session = Session(response=response)
        catalogue.collect(session, self.output, context())
        self.assertTrue(all(marker not in sql for sql in session.statements))
        self.assertEqual(json.loads((self.output / 'C1.json').read_text())[0]['name'], marker)

    def test_partial_begin_failure_still_attempts_rollback(self):
        session = Session(begin_error=True)
        with self.assertRaisesRegex(catalogue.CatalogueError, '^catalogue-incomplete$'):
            catalogue.collect(session, self.output, context())
        self.assertEqual(session.statements, [catalogue.TRANSACTION, 'ROLLBACK;'])

    def test_rollback_failure_cannot_produce_complete_marker(self):
        with self.assertRaises(catalogue.CatalogueError):
            catalogue.collect(Session(fail_rollback=True), self.output, context())
        self.assertFalse((self.output / 'manifest-private.json').exists())

    def test_existing_output_never_overwritten(self):
        self.output.mkdir()
        (self.output / 'sentinel').write_text('synthetic-preserved')
        session = Session()
        with self.assertRaises(catalogue.CatalogueError):
            catalogue.collect(session, self.output, context())
        self.assertEqual(session.statements, [])
        self.assertEqual((self.output / 'sentinel').read_text(), 'synthetic-preserved')

    def test_missing_private_parent_redacts_path_before_sql(self):
        session = Session()
        with self.assertRaisesRegex(catalogue.CatalogueError, '^private-directory-unavailable$'):
            catalogue.collect(session, self.output / 'synthetic-missing-parent' / 'out', context())
        self.assertEqual(session.statements, [])

    def test_wrong_source_plan_or_conninfo_database_fails_before_sql(self):
        for changes in [{'sourceManifestSHA256': '0' * 64}, {'queryPlanSHA256': '1' * 64},
                        {'database': 'host=foreign user=production'}, {'database': '-hforeign'}]:
            session = Session()
            with self.assertRaises(catalogue.CatalogueError):
                catalogue.collect(session, self.output, {**context(), **changes})
            self.assertEqual(session.statements, [])
            self.assertFalse(self.output.exists())


class DecoderTests(unittest.TestCase):
    def test_bound_duplicate_keys_nan_and_invalid_utf8_refused(self):
        for raw in [b'{"x":1,"x":2}', b'{"x":NaN}', b'\xff',
                    b' ' * (catalogue.MAX_RESPONSE_BYTES + 1)]:
            with self.assertRaises(catalogue.CatalogueError):
                catalogue.decode(raw)

    def test_boolean_not_accepted_as_count_and_unknown_surface_refused(self):
        for value in [{**payload('C7'), 'functions': True}, {**payload('C7'), 'secret': 1},
                      {**payload('C7'), 'functions': -1}]:
            with self.assertRaises(catalogue.CatalogueError):
                catalogue.validate_payload('C7', value)

    def test_record_limit_fails_instead_of_silently_truncating(self):
        with self.assertRaises(catalogue.CatalogueError):
            catalogue.validate_payload('C3', [{}] * (catalogue.MAX_RECORDS + 1))


if __name__ == '__main__':
    unittest.main()
