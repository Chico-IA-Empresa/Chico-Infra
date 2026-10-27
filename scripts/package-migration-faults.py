"""Fault injection only in the named synthetic PG16 database; restore head exactly."""
import json
import os
import subprocess
from pathlib import Path
import sys
sys.path.insert(0,'/app')

from core.package_runtime import load
load()
from core.config import settings
from scripts.package_migrate import guard_target
from sqlalchemy import create_engine, text, inspect
guard_target(settings.DATABASE_URL,settings.ENVIRONMENT)
engine=create_engine(settings.DATABASE_URL,hide_parameters=True)

def run():
    return subprocess.run([sys.executable,'scripts/package_migrate.py'],capture_output=True,text=True)

with engine.connect() as db:
    heads=list(db.execute(text('SELECT version_num FROM alembic_version')).scalars())
    assert heads==['retire20260926']
    tables=sorted(inspect(db).get_table_names())
    assert db.execute(text('SELECT pg_try_advisory_lock(762023005)')).scalar()
    try:
        locked=run()
        assert locked.returncode==1 and 'ValueError' in locked.stderr
    finally:
        db.execute(text('SELECT pg_advisory_unlock(762023005)'));db.commit()
    # Explicit fault, never an automatic migration stamp. No user/application
    # data is touched. finally restores the recorded head even if assertion fails.
    try:
        db.execute(text("UPDATE alembic_version SET version_num='package_orphan_fault'"));db.commit()
        orphan=run()
        assert orphan.returncode==1 and 'ValueError' in orphan.stderr
        assert list(db.execute(text('SELECT version_num FROM alembic_version')).scalars())==['package_orphan_fault']
        assert sorted(inspect(db).get_table_names())==tables
    finally:
        db.rollback()
        db.execute(text('UPDATE alembic_version SET version_num=:head'),{'head':heads[0]});db.commit()
    final=run()
    assert final.returncode==0
    print(json.dumps({'advisoryLockRefusedExit':locked.returncode,'orphanRefusedExit':orphan.returncode,
                      'orphanNotStamped':True,'schemaUnchanged':True,'restoredHead':heads,'finalNoopExit':final.returncode}))
engine.dispose()
