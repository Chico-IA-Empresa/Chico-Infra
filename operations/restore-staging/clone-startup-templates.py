"""Prepare inert PG16 clone-startup templates. Never start or edit a cluster."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

spec = importlib.util.spec_from_file_location('private_config', Path(__file__).with_name('prepare-private-config.py'))
private = importlib.util.module_from_spec(spec)
spec.loader.exec_module(private)

SETTINGS = {'max_connections': (1, 262143), 'max_worker_processes': (0, 262143),
            'max_wal_senders': (0, 262143), 'max_prepared_transactions': (0, 262143),
            'max_locks_per_transaction': (10, 2147483647)}
RESTORE_COMMAND = ('/usr/local/bin/pgbackrest --config=/config --stanza=main --repo=1 '
                   '--archive-async=n --log-level-console=off --log-level-file=off archive-get %f "%p"')
START_ARGV = ['/usr/lib/postgresql/16/bin/postgres', '-D', '/pgdata', '-c', 'config_file=/scripts/clone/postgresql.conf']
CLIENT_OPTIONS = '-c session_preload_libraries= -c local_preload_libraries= -c search_path=pg_catalog -c default_transaction_read_only=on'


def render(control, source_sha256):
    if (set(control) != {'schema', 'postgresMajor', 'systemIdentifier', 'sourceManifestSHA256', 'settings'} or
            control['schema'] != 1 or control['postgresMajor'] != 16 or
            not re.fullmatch(r'[a-f0-9]{64}', source_sha256) or control['sourceManifestSHA256'] != source_sha256 or
            not isinstance(control['systemIdentifier'], str) or not control['systemIdentifier'].isdigit() or
            not 0 < int(control['systemIdentifier']) < 2 ** 64 or not isinstance(control['settings'], dict) or
            set(control['settings']) != set(SETTINGS)):
        raise ValueError('Reviewed PG16 control metadata required')
    for name, (minimum, maximum) in SETTINGS.items():
        value = control['settings'][name]
        if type(value) is not int or not minimum <= value <= maximum:
            raise ValueError('Control setting requires numeric review')
    values = {
        'data_directory': "'/pgdata'", 'hba_file': "'/scripts/clone/pg_hba.conf'",
        'ident_file': "'/scripts/clone/pg_ident.conf'", 'listen_addresses': "''",
        'unix_socket_directories': "'/tmp/socket'", 'unix_socket_permissions': '0700',
        'ssl': 'off', 'ssl_passphrase_command': "''", 'external_pid_file': "''",
        'shared_preload_libraries': "''", 'session_preload_libraries': "''", 'local_preload_libraries': "''",
        'archive_mode': 'off', 'archive_command': "''", 'archive_library': "''",
        'archive_cleanup_command': "''", 'recovery_end_command': "''",
        'primary_conninfo': "''", 'primary_slot_name': "''",
        'recovery_target': "'immediate'", 'recovery_target_timeline': "'current'",
        'recovery_target_action': "'pause'", 'hot_standby': 'on',
        'max_logical_replication_workers': '0', 'max_sync_workers_per_subscription': '0',
        'autovacuum': 'off', 'default_transaction_read_only': 'on', 'jit': 'off',
        'logging_collector': 'off', 'log_destination': "'stderr'", 'log_statement': "'none'",
        'log_min_error_statement': "'panic'", 'restore_command': "'" + RESTORE_COMMAND + "'",
        **{name: str(control['settings'][name]) for name in SETTINGS},
    }
    config = ''.join(f'{name} = {value}\n' for name, value in values.items()).encode()
    return {'postgresql.conf': config,
            'pg_hba.conf': b'local all postgres peer\nlocal all all reject\nhost all all 0.0.0.0/0 reject\nhost all all ::/0 reject\n',
            'pg_ident.conf': b''}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--control-settings', type=Path, required=True)
    parser.add_argument('--control-sha256', required=True)
    parser.add_argument('--source-manifest-sha256', required=True)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--gid', type=int, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() != 0 or not 0 < args.uid < 2 ** 31 or not 0 < args.gid < 2 ** 31:
        raise ValueError('Reviewed Linux root and nonroot image UID/GID required')
    private.cipher.require_private_tmpfs(args.directory)
    if args.directory.name != 'clone' or args.control_settings != args.directory.parent / 'control-settings.json':
        raise ValueError('Exact private template paths required')
    if os.path.lexists(args.directory):
        raise ValueError('Fresh template directory required')
    raw = private.read_private(args.control_settings, 65536)
    control = private.pinned_json(raw, args.control_sha256)
    templates = render(control, args.source_manifest_sha256)
    args.directory.mkdir(mode=0o700)
    for name, contents in templates.items():
        private.write_config(args.directory / name, contents, args.uid, args.gid)
    os.chown(args.directory, args.uid, args.gid)
    print(json.dumps({'templatesReady': True, 'clusterStarted': False, 'databaseRestored': False,
                      'autoConfQuarantineStillRequired': True, 'startupResourceReviewStillRequired': True,
                      'sourceManifestSHA256': args.source_manifest_sha256, 'controlSHA256': args.control_sha256}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'Clone templates failed: {type(error).__name__}; configuration material omitted') from None
