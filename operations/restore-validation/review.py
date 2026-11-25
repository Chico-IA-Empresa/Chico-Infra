"""Offline review helpers. No AWS, DB connection, model imports, or treatment DML.

Existing operations/dev-database/backup.py remains the manifest authority. Model
AST only supplies candidate review labels; the recovered catalog is authoritative.
All generated reviews are pending until explicitly completed by a technical reviewer.
"""
import argparse
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


class ReviewRejected(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def call_name(node):
    return node.id if isinstance(node, ast.Name) else node.attr if isinstance(node, ast.Attribute) else None


def constant(node):
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


def model_inventory(models):
    """Extract literal SQLAlchemy Column/Table declarations without executing code.

    Inherited columns, dynamic names, migrations and actual DB types are not
    inferred. Missing/unknown fields stay pending in the clone's review ledger.
    """
    models = Path(models).resolve()
    if not models.is_dir():
        raise ReviewRejected('models_directory_required')
    tables, sources = {}, []

    def add(table, name, source):
        if not table or not name:
            return
        key = ('public', table, name)
        if key in tables:
            raise ReviewRejected('duplicate_model_field')
        tables[key] = source

    for path in sorted(models.rglob('*.py')):
        data = path.read_bytes()
        relative = path.relative_to(models).as_posix()
        sources.append({'path': relative, 'sha256': sha(data)})
        tree = ast.parse(data, filename=relative)
        for node in tree.body:
            if isinstance(node, ast.ClassDef):
                table = next((constant(item.value) for item in node.body if isinstance(item, ast.Assign)
                              and any(isinstance(t, ast.Name) and t.id == '__tablename__' for t in item.targets)), None)
                for item in node.body:
                    if isinstance(item, (ast.Assign, ast.AnnAssign)) and isinstance(item.value, ast.Call) and call_name(item.value.func) == 'Column':
                        targets = item.targets if isinstance(item, ast.Assign) else [item.target]
                        name = constant(item.value.args[0]) if item.value.args else None
                        if name is None:
                            name = next((t.id for t in targets if isinstance(t, ast.Name)), None)
                        add(table, name, relative)
            elif isinstance(node, (ast.Assign, ast.AnnAssign)) and isinstance(node.value, ast.Call) and call_name(node.value.func) == 'Table':
                table = constant(node.value.args[0]) if node.value.args else None
                for argument in node.value.args[1:]:
                    if isinstance(argument, ast.Call) and call_name(argument.func) == 'Column' and argument.args:
                        add(table, constant(argument.args[0]), relative)
    return tables, {'files': sources, 'fingerprint': sha(canonical(sources)), 'executedModelCode': False}


def candidates(column, source):
    name = column['name'].lower()
    result = []
    if re.search(r'password|token|secret|oauth|nonce|auth_tag|ciphertext|signature|fingerprint|wrapped_data_key|encryption_key|api_key|private_key|signing_key|access_key', name):
        result.append('credential_or_auth_material_candidate')
    if re.search(r'email|username|full_name|phone|cellphone|tax_id|cpf|pix|google_id|chat_id|telegram_user_id|whatsapp|instagram|tiktok|youtube|avatar|\bbio\b|public_name', name):
        result.append('personal_identifier_candidate')
    if re.search(r'(^|_)user_id$|actor_user_id|follower_id|followed_id', name):
        result.append('user_link_candidate')
    if re.search(r'payload|content|message|notes?|reason|description|raw_json|old_value|new_value', name) or re.search(r'json|bytea', column.get('type', ''), re.I):
        result.append('free_text_or_structured_content_review')
    if source and source.split('/')[0] in {'payments', 'affiliates', 'crm'}:
        result.append('financial_or_crm_business_preservation_review')
    if source and source.split('/')[0] in {'odds', 'matches', 'teams', 'competitions', 'statistics', 'sofascore'}:
        result.append('sports_business_preservation_candidate')
    if source is None:
        result.append('not_found_in_current_model_code')
    return result or ['manual_classification_required']


def columns(manifest):
    result = {}
    for item in manifest.get('columns', []):
        if not isinstance(item, dict) or any(not isinstance(item.get(k), str) or not item[k] for k in ('schema', 'table_name', 'name', 'type')):
            raise ReviewRejected('invalid_catalog_column')
        key = (item['schema'], item['table_name'], item['name'])
        if key in result:
            raise ReviewRejected('duplicate_catalog_column')
        result[key] = item
    if not result:
        raise ReviewRejected('nonempty_existing_manifest_required')
    return result


def classification_template(manifest_bytes, models):
    manifest = json.loads(manifest_bytes)
    catalog, (inventory, binding) = columns(manifest), model_inventory(models)
    entries = []
    for key, item in sorted(catalog.items()):
        source = inventory.get(key)
        entries.append({'schema': key[0], 'table': key[1], 'column': key[2], 'type': item['type'],
                        'modelSource': source, 'candidates': candidates(item, source),
                        'classification': None, 'decision': None, 'rationale': None,
                        'treatmentArtifactSha256': None})
    return {'version': 1, 'manifestSha256': sha(manifest_bytes), 'modelSourceBinding': binding,
            'technicalReview': {'completed': False, 'reviewer': None, 'evidenceReference': None},
            'columns': entries, 'modelFieldsMissingFromClone': [list(key) for key in sorted(set(inventory) - set(catalog))],
            'treatmentApplied': False, 'exportApproved': False}


def validate_classification(manifest_bytes, ledger):
    catalog = columns(json.loads(manifest_bytes))
    if ledger.get('version') != 1 or ledger.get('manifestSha256') != sha(manifest_bytes):
        raise ReviewRejected('classification_snapshot_binding_changed')
    review = ledger.get('technicalReview', {})
    if review.get('completed') is not True or any(not isinstance(review.get(k), str) or not review[k].strip() for k in ('reviewer', 'evidenceReference')):
        raise ReviewRejected('explicit_technical_classification_required')
    seen = set()
    classes = {'business', 'pii', 'credential', 'user_link', 'free_text_or_payload'}
    decisions = {'preserve_business', 'pseudonymize', 'invalidate_credential', 'replace_with_dev_value'}
    for item in ledger.get('columns', []):
        key = (item.get('schema'), item.get('table'), item.get('column'))
        if key not in catalog or key in seen or item.get('type') != catalog[key]['type']:
            raise ReviewRejected('classification_column_coverage_changed')
        seen.add(key)
        classification, decision = item.get('classification'), item.get('decision')
        if classification not in classes or decision not in decisions or not isinstance(item.get('rationale'), str) or not item['rationale'].strip():
            raise ReviewRejected('unresolved_column_classification')
        if classification in {'pii', 'credential'} and decision == 'preserve_business':
            raise ReviewRejected('production_identity_preservation_not_authorized')
        if decision != 'preserve_business' and not re.fullmatch(r'[a-f0-9]{64}', item.get('treatmentArtifactSha256') or ''):
            raise ReviewRejected('reviewed_treatment_artifact_required')
    if seen != set(catalog):
        raise ReviewRejected('classification_column_coverage_changed')
    return {'classificationReviewComplete': True, 'columnsReviewed': len(seen),
            'treatmentApplied': False, 'exportApproved': False, 'businessWritersStarted': False}


def compare_manifests(expected_bytes, actual_bytes, reviewed_expected_sha256):
    if not re.fullmatch(r'[a-f0-9]{64}', reviewed_expected_sha256 or '') or sha(expected_bytes) != reviewed_expected_sha256:
        raise ReviewRejected('unreviewed_baseline_manifest')
    spec = importlib.util.spec_from_file_location('chico_existing_database_manifest', ROOT / 'operations/dev-database/backup.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        module.reconcile(json.loads(expected_bytes), json.loads(actual_bytes))
    except (module.OperationFailed, KeyError, TypeError, ValueError):
        raise ReviewRejected('existing_manifest_reconciliation_failed') from None
    return {'catalogAndCountsEquivalent': True, 'sequenceSafetyVerified': True,
            'baselineManifestSha256': sha(expected_bytes), 'restoredManifestSha256': sha(actual_bytes),
            'rowContentEquivalent': False, 'businessQueriesPending': True, 'exportApproved': False}


def assess_preflight(metadata):
    """Surface execution/compatibility risks without evaluating application code.

    This is a technical review queue, not approval to start a clone or export.
    No risky object is disabled, dropped, executed, or implicitly accepted.
    """
    if metadata.get('version') != 1 or type(metadata.get('serverVersionNum')) is not int:
        raise ReviewRejected('invalid_pg16_catalog_preflight')
    database = metadata['database']
    if not isinstance(database, dict) or any(key not in database for key in (
            'encoding', 'collation', 'ctype', 'localeProvider', 'icuLocale',
            'recordedCollationVersion', 'actualCollationVersion')):
        raise ReviewRejected('incomplete_collation_metadata')
    required = ('inRecovery', 'preloads', 'externalConfigurationPresent', 'extensions',
                'triggers', 'eventTriggers', 'rowSecurity', 'securityDefinerRoutines',
                'foreignTables', 'subscriptions', 'enabledSubscriptions', 'devRoleFlags')
    if any(key not in metadata for key in required):
        raise ReviewRejected('incomplete_execution_surface_metadata')
    if (type(metadata['inRecovery']) is not bool or
            not isinstance(metadata['preloads'], dict) or set(metadata['preloads']) != {'shared', 'session', 'local'} or
            any(not isinstance(v, str) for v in metadata['preloads'].values()) or
            not isinstance(metadata['externalConfigurationPresent'], dict) or
            set(metadata['externalConfigurationPresent']) != {'archiveCommand', 'primaryConninfo'} or
            any(type(v) is not bool for v in metadata['externalConfigurationPresent'].values()) or
            any(not isinstance(metadata[field], list) for field in
                ('extensions', 'triggers', 'eventTriggers', 'rowSecurity', 'securityDefinerRoutines', 'devRoleFlags'))):
        raise ReviewRejected('invalid_execution_surface_metadata')
    blockers, reviews = [], []
    if not 160000 <= metadata['serverVersionNum'] < 170000:
        blockers.append('postgres16_required')
    if metadata['inRecovery'] is not False:
        blockers.append('physical_recovery_completion_required')
    if database['recordedCollationVersion'] != database['actualCollationVersion']:
        blockers.append('database_collation_version_mismatch')
    if database['localeProvider'] not in ('c', 'i'):
        blockers.append('locale_provider_requires_review')
    if any(metadata['preloads'].get(key) for key in ('shared', 'session', 'local')):
        reviews.append('preloaded_libraries')
    if any(metadata['externalConfigurationPresent'].values()):
        reviews.append('external_archive_or_replication_configuration')
    for field in ('triggers', 'eventTriggers', 'rowSecurity', 'securityDefinerRoutines'):
        if metadata[field]:
            reviews.append(field)
    for field in ('foreignTables', 'subscriptions', 'enabledSubscriptions'):
        if type(metadata[field]) is not int or metadata[field] < 0:
            raise ReviewRejected('invalid_execution_surface_count')
        if metadata[field]:
            reviews.append(field)
    extension_names = {item['extname'] for item in metadata['extensions']}
    if extension_names - {'plpgsql', 'pg_trgm', 'pg_stat_statements'}:
        reviews.append('extension_compatibility_and_background_workers')
    if any(any(role.get(key) for key in ('superuser', 'create_db', 'create_role', 'replication', 'bypass_rls'))
           for role in metadata['devRoleFlags']):
        reviews.append('dev_role_elevated_privileges')
    return {'metadataCompatible': not blockers, 'blockingCodes': blockers,
            'technicalReviewRequired': sorted(set(reviews)), 'applicationRowsRead': False,
            'executionSurfaceReviewComplete': False, 'cloneStartAuthorized': False,
            'treatmentApplied': False, 'restoreApproved': False, 'exportApproved': False,
            'businessWritersStarted': False}


def write_new_private(path, value):
    # Never overwrite a prior review/evidence. No raw values are expected here.
    with Path(path).open('xb') as stream:
        os.chmod(path, 0o600)
        stream.write(canonical(value) + b'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    template = sub.add_parser('classification-template')
    template.add_argument('--manifest', required=True, type=Path)
    template.add_argument('--models', required=True, type=Path)
    template.add_argument('--output', required=True, type=Path)
    review = sub.add_parser('check-classification')
    review.add_argument('--manifest', required=True, type=Path)
    review.add_argument('--ledger', required=True, type=Path)
    compare = sub.add_parser('compare')
    compare.add_argument('--expected', required=True, type=Path)
    compare.add_argument('--actual', required=True, type=Path)
    compare.add_argument('--reviewed-expected-sha256', required=True)
    preflight = sub.add_parser('assess-preflight')
    preflight.add_argument('--catalog', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'classification-template':
            result = classification_template(args.manifest.read_bytes(), args.models)
            write_new_private(args.output, result)
            print(json.dumps({'templateCreated': True, 'columnsPending': len(result['columns']), 'treatmentApplied': False}))
        elif args.operation == 'check-classification':
            print(json.dumps(validate_classification(args.manifest.read_bytes(), json.loads(args.ledger.read_bytes()))))
        elif args.operation == 'compare':
            print(json.dumps(compare_manifests(args.expected.read_bytes(), args.actual.read_bytes(), args.reviewed_expected_sha256)))
        else:
            result = assess_preflight(json.loads(args.catalog.read_bytes()))
            print(json.dumps(result))
            # Never turn compatibility alone into a successful executable gate
            # while execution surfaces still have an explicit review queue.
            return 1 if not result['metadataCompatible'] else 2 if result['technicalReviewRequired'] else 0
    except Exception as error:
        code = error.args[0] if isinstance(error, ReviewRejected) else 'private_review_failed'
        print(json.dumps({'success': False, 'code': code}), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
