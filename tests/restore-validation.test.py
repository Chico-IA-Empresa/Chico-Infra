"""Offline B3 metadata/classification tests. No backend imports, DB or AWS calls."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('restore_review', ROOT / 'operations/restore-validation/review.py')
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


def manifest():
    value = {key: [] for key in ('extensions', 'views', 'functions', 'userTypes', 'alembic', 'indexes', 'constraints', 'sequenceDefinitions', 'sequences')}
    value.update(encoding='UTF8', collation='C', ctype='C', largeObjects={'objects': 0, 'bytes': 0},
                 tables=[{'schema': 'public', 'name': 'users', 'rows': 2}],
                 columns=[{'schema': 'public', 'table_name': 'users', 'name': 'email', 'type': 'text'},
                          {'schema': 'public', 'table_name': 'users', 'name': 'hashed_password', 'type': 'text'}])
    return value


def catalog():
    return {'version': 1, 'serverVersionNum': 160013, 'inRecovery': False,
            'database': {'encoding': 'UTF8', 'collation': 'C', 'ctype': 'C', 'localeProvider': 'c',
                         'icuLocale': None, 'recordedCollationVersion': None, 'actualCollationVersion': None},
            'preloads': {'shared': '', 'session': '', 'local': ''},
            'externalConfigurationPresent': {'archiveCommand': False, 'primaryConninfo': False},
            'extensions': [{'extname': 'plpgsql', 'extversion': '1.0'}], 'triggers': [],
            'eventTriggers': [], 'rowSecurity': [], 'securityDefinerRoutines': [],
            'foreignTables': 0, 'subscriptions': 0, 'enabledSubscriptions': 0, 'devRoleFlags': []}


def models(directory):
    path = Path(directory) / 'users'
    path.mkdir()
    (path / 'user.py').write_text('''raise RuntimeError("MODEL MUST NEVER EXECUTE")
class User(Base):
    __tablename__ = "users"
    email = Column(String, nullable=False)
    hashed_password = Column(String)
    new_code_field = Column(String)
followers = Table("followers", metadata,
    Column("follower_id", Integer), Column("followed_id", Integer))
''')


class RestoreValidationTests(unittest.TestCase):
    def test_model_inventory_is_static_and_includes_association_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            models(directory)
            inventory, binding = review.model_inventory(directory)
            self.assertIn(('public', 'followers', 'follower_id'), inventory)
            self.assertIn(('public', 'users', 'email'), inventory)
            self.assertFalse(binding['executedModelCode'])
            self.assertEqual(len(binding['fingerprint']), 64)

    def test_template_covers_clone_not_only_current_code_and_defaults_pending(self):
        data = manifest()
        data['columns'].append({'schema': 'public', 'table_name': 'old_legacy', 'name': 'raw_payload', 'type': 'jsonb'})
        with tempfile.TemporaryDirectory() as directory:
            models(directory)
            template = review.classification_template(review.canonical(data), directory)
        self.assertFalse(template['technicalReview']['completed'])
        self.assertEqual(len(template['columns']), 3)
        self.assertTrue(all(c['classification'] is None and c['decision'] is None for c in template['columns']))
        self.assertIn(['public', 'users', 'new_code_field'], template['modelFieldsMissingFromClone'])
        unknown = next(c for c in template['columns'] if c['table'] == 'old_legacy')
        self.assertIn('not_found_in_current_model_code', unknown['candidates'])
        self.assertIn('free_text_or_structured_content_review', unknown['candidates'])

    def test_classification_requires_complete_bound_technical_review_not_new_human_gate(self):
        data = review.canonical(manifest())
        with tempfile.TemporaryDirectory() as directory:
            models(directory)
            ledger = review.classification_template(data, directory)
        with self.assertRaises(review.ReviewRejected):
            review.validate_classification(data, ledger)
        ledger['technicalReview'] = {'completed': True, 'reviewer': 'authorized technical agent', 'evidenceReference': 'private-review-reference'}
        for item in ledger['columns']:
            item.update(classification='credential' if item['column'] == 'hashed_password' else 'pii',
                        decision='replace_with_dev_value', rationale='Technical Dev treatment; preserve schema/links.',
                        treatmentArtifactSha256='a' * 64)
        result = review.validate_classification(data, ledger)
        self.assertTrue(result['classificationReviewComplete'])
        self.assertFalse(result['treatmentApplied'])
        self.assertFalse(result['exportApproved'])
        for mutation in (
            lambda x: x.update(manifestSha256='0' * 64),
            lambda x: x['columns'].pop(),
            lambda x: x['columns'].append(copy.deepcopy(x['columns'][0])),
            lambda x: x['columns'][0].update(decision='preserve_business'),
            lambda x: x['columns'][0].update(treatmentArtifactSha256=None),
            lambda x: x['columns'][0].update(classification='unknown'),
        ):
            changed = copy.deepcopy(ledger)
            mutation(changed)
            with self.assertRaises(review.ReviewRejected):
                review.validate_classification(data, changed)

    def test_known_sensitive_and_business_hints_are_candidates_only(self):
        self.assertIn('credential_or_auth_material_candidate', review.candidates({'name': 'token_hash'}, 'auth/refresh_token.py'))
        self.assertIn('personal_identifier_candidate', review.candidates({'name': 'private_chat_id'}, 'telegram/telegram_binding.py'))
        hints = review.candidates({'name': 'amount_cents', 'type': 'integer'}, 'payments/payment_charge.py')
        self.assertEqual(hints, ['financial_or_crm_business_preservation_review'])
        self.assertNotIn('credential_or_auth_material_candidate', review.candidates({'name': 'market_key'}, 'odds/odds.py'))

    def test_compare_reuses_existing_manifest_and_never_claims_row_content_equivalence(self):
        expected = review.canonical(manifest())
        result = review.compare_manifests(expected, expected, review.sha(expected))
        self.assertTrue(result['catalogAndCountsEquivalent'])
        self.assertFalse(result['rowContentEquivalent'])
        self.assertTrue(result['businessQueriesPending'])
        changed = manifest()
        changed['tables'][0]['rows'] += 1
        with self.assertRaises(review.ReviewRejected):
            review.compare_manifests(expected, review.canonical(changed), review.sha(expected))
        with self.assertRaises(review.ReviewRejected):
            review.compare_manifests(expected, expected, '0' * 64)

    def test_metadata_flags_execution_surfaces_without_executing_or_accepting_them(self):
        value = catalog()
        self.assertTrue(review.assess_preflight(value)['metadataCompatible'])
        value.update(triggers=[{'name': 'synthetic'}], eventTriggers=[{'name': 'synthetic'}],
                     rowSecurity=[{}], securityDefinerRoutines=[{}], foreignTables=1, enabledSubscriptions=1)
        value['preloads']['shared'] = 'pg_cron'
        value['extensions'].append({'extname': 'pg_cron'})
        result = review.assess_preflight(value)
        for name in ('triggers', 'eventTriggers', 'rowSecurity', 'securityDefinerRoutines', 'foreignTables', 'enabledSubscriptions', 'preloaded_libraries', 'extension_compatibility_and_background_workers'):
            self.assertIn(name, result['technicalReviewRequired'])
        self.assertFalse(result['restoreApproved'])
        self.assertFalse(result['applicationRowsRead'])

    def test_compatibility_and_incomplete_metadata_fail_closed(self):
        for mutation in (
            lambda x: x.update(serverVersionNum=180000), lambda x: x.update(inRecovery=True),
            lambda x: x['database'].update(recordedCollationVersion='old', actualCollationVersion='new'),
        ):
            value = catalog()
            mutation(value)
            self.assertFalse(review.assess_preflight(value)['metadataCompatible'])
        for mutation in (lambda x: x.pop('triggers'), lambda x: x.update(preloads={}), lambda x: x.update(foreignTables=-1)):
            value = catalog()
            mutation(value)
            with self.assertRaises(review.ReviewRejected):
                review.assess_preflight(value)

    def test_generated_review_never_overwrites_existing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ledger.json'
            review.write_new_private(path, {'pending': True})
            with self.assertRaises(FileExistsError):
                review.write_new_private(path, {'pending': False})
            self.assertTrue(json.loads(path.read_bytes())['pending'])

    def test_cli_error_does_not_echo_private_manifest_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private.json'
            path.write_text('{"sensitive-marker-should-not-echo":true}')
            result = subprocess.run([sys.executable, str(ROOT / 'operations/restore-validation/review.py'), 'assess-preflight', '--catalog', str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn('sensitive-marker', result.stdout + result.stderr)

    def test_cli_compatible_metadata_with_risk_queue_does_not_release_export(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'catalog.json'
            metadata = catalog()
            metadata['triggers'] = [{'name': 'synthetic'}]
            path.write_text(json.dumps(metadata))
            result = subprocess.run([sys.executable, str(ROOT / 'operations/restore-validation/review.py'), 'assess-preflight', '--catalog', str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            body = json.loads(result.stdout)
            self.assertTrue(body['metadataCompatible'])
            self.assertFalse(body['exportApproved'])
            self.assertFalse(body['cloneStartAuthorized'])
            self.assertFalse(body['executionSurfaceReviewComplete'])


if __name__ == '__main__':
    unittest.main()
