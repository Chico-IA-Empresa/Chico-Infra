"""Bounded Linux CI/session adapter for fixed SQL only. No AWS or secret resolution.

Operational use additionally needs the independently reviewed host/container,
image/lease/source/process approvals; this adapter never supplies those approvals.
"""
import os
import re
import selectors
import subprocess
import sys
import time
from pathlib import Path
import minimal_catalogue as catalogue

PSQL = '/usr/lib/postgresql/16/bin/psql'
PGOPTIONS = ('-c session_preload_libraries= -c local_preload_libraries= '
             '-c search_path=pg_catalog -c default_transaction_read_only=on')


class PsqlSession:
    def __init__(self, container_id, database, socket, stderr_path):
        if (sys.platform != 'linux' or not re.fullmatch('[a-f0-9]{64}', container_id) or
                not re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,62}', database) or
                socket not in {'/tmp/source-socket', '/tmp/standby-socket'}):
            raise catalogue.CatalogueError('session-context')
        # CI uses two fixed local socket locations. A real-clone socket adapter
        # must be reviewed separately rather than widening this fixture seam.
        self.pending = b''
        self.closed = False
        self.started = False
        self.selector = selectors.DefaultSelector()
        descriptor = os.open(Path(stderr_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        self.error_stream = os.fdopen(descriptor, 'wb')
        command = ['/usr/bin/docker', 'exec', '--interactive', '--user', '999', container_id,
                   '/usr/bin/env', '-i', 'PATH=/usr/lib/postgresql/16/bin:/usr/bin:/bin',
                   'LANG=C.UTF-8', 'LC_ALL=C.UTF-8', 'PGOPTIONS=' + PGOPTIONS,
                   PSQL, '-X', '--quiet', '--tuples-only', '--no-align', '--no-password',
                   '--set=ON_ERROR_STOP=1', '--host=' + socket, '--port=5432' if socket == '/tmp/source-socket' else '--port=5433',
                   '--username=postgres', '--dbname=' + database]
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=self.error_stream, bufsize=0,
                                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'})
            self.selector.register(self.process.stdout, selectors.EVENT_READ)
        except Exception:
            self.error_stream.close()
            self.selector.close()
            raise catalogue.CatalogueError('session-launch') from None

    def _send(self, sql):
        if self.closed or self.process.poll() is not None:
            raise catalogue.CatalogueError('session-closed')
        try:
            self.process.stdin.write((sql + '\n').encode())
            self.process.stdin.flush()
        except OSError:
            raise catalogue.CatalogueError('session-write') from None

    def execute(self, sql):
        if sql == catalogue.TRANSACTION and not self.started:
            self.started = True
            self._send(sql)
        elif sql == 'ROLLBACK;' and self.started:
            self._send('ROLLBACK;\n\\q')
            try:
                self.process.stdin.close()
                if self.process.wait(timeout=5) != 0:
                    raise catalogue.CatalogueError('session-rollback')
                self.closed = True
            except subprocess.TimeoutExpired:
                raise catalogue.CatalogueError('session-rollback-timeout') from None
        else:
            raise catalogue.CatalogueError('unreviewed-session-command')

    def query(self, sql, max_bytes):
        if not self.started or sql not in {catalogue.GATE_SQL, *(text for _, text in catalogue.QUERIES)} or max_bytes != catalogue.MAX_RESPONSE_BYTES:
            raise catalogue.CatalogueError('unreviewed-query')
        self._send(sql)
        deadline = time.monotonic() + 20
        while True:
            if b'\n' in self.pending:
                line, self.pending = self.pending.split(b'\n', 1)
                if len(line) > max_bytes or self.pending.strip():
                    raise catalogue.CatalogueError('response-framing')
                return line
            if len(self.pending) > max_bytes:
                raise catalogue.CatalogueError('response-bound')
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise catalogue.CatalogueError('response-timeout')
            chunk = os.read(self.process.stdout.fileno(), min(65536, max_bytes + 1 - len(self.pending)))
            if not chunk:
                raise catalogue.CatalogueError('session-terminated')
            self.pending += chunk

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.selector.close()
        self.process.stdout.close()
        self.error_stream.close()
