"""PG16 fixture invariants and actual SQL privilege probes; sanitized output."""
from pathlib import Path
import hashlib
import json
import sys


def main():
    from sqlalchemy import create_engine, text
    from sqlalchemy.engine import make_url
    configs = {name:json.loads(Path('/checks/'+name+'.json').read_text()) for name in ('api','workers','migrator','seed')}
    checks = {}
    snapshot = None
    for name, config in configs.items():
        url = make_url(config['DATABASE_URL'])
        if url.host != 'postgres' or url.database != 'chico_package_test' or url.username != 'chico_'+name:
            raise ValueError('Dedicated fixture destination required')
        engine = create_engine(url, hide_parameters=True)
        with engine.connect() as db:
            assert db.execute(text('SHOW server_version_num')).scalar().startswith('16')
            identity = db.execute(text('SELECT current_user')).scalar()
            assert identity == 'chico_'+name
            assert db.execute(text('SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname=current_user')).scalar() is False
            if name == 'api':
                rows = db.execute(text("SELECT fixture_id, home_team, away_team, source FROM matches WHERE fixture_id='package-v1-match'")).mappings().all()
                odds = db.execute(text("SELECT fixture_id, outcome_key, odds_value::text FROM odds WHERE fixture_id='package-v1-match' ORDER BY outcome_key")).mappings().all()
                assert len(rows) == 1 and len(odds) == 3
                snapshot = hashlib.sha256(json.dumps({'matches':[dict(r) for r in rows], 'odds':[dict(r) for r in odds]},sort_keys=True).encode()).hexdigest()
            db.rollback()
            statement = 'CREATE TABLE public.package_privilege_probe(id integer)'
            if name in ('api','workers','seed'):
                try:
                    db.execute(text(statement))
                except Exception as exc:
                    assert getattr(exc.orig, 'pgcode', None) == '42501'
                    checks[name+'DdlDenied'] = True
                else:
                    raise AssertionError('Unexpected DDL privilege')
                finally:
                    db.rollback()
            else:
                db.execute(text(statement))
                db.rollback()  # probe table never persists
                checks['migratorDdlAllowed'] = True
            if name == 'workers':
                try:
                    db.execute(text('UPDATE users SET username=username WHERE id=-1'))
                except Exception as exc:
                    assert getattr(exc.orig, 'pgcode', None) == '42501'
                    checks['workersUserMutationDenied'] = True
                else:
                    raise AssertionError('Workers must not mutate users')
                finally:
                    db.rollback()
        engine.dispose()
    print(json.dumps({'postgresMajor':16, 'checks':checks, 'fixtureSnapshot':snapshot, 'fixtureCounts':{'matches':1,'odds':3}}))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('Database fixture probe failed: '+type(exc).__name__, file=sys.stderr)
        sys.exit(1)
