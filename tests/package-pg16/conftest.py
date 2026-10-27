"""Use the Alembic-migrated disposable PG16 schema; never create_all/SQLite."""
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from core.config import settings
from sqlalchemy.engine import make_url


@pytest.fixture
def db_session():
    url = make_url(settings.DATABASE_URL)
    assert url.host == 'postgres' and url.database == 'chico_package_test' and url.username == 'chico_seed'
    engine = create_engine(url, hide_parameters=True)
    with engine.connect() as connection:
        transaction = connection.begin()
        session = Session(bind=connection, join_transaction_mode='create_savepoint', expire_on_commit=False)
        try:
            # Existing test bodies assume an empty odds table. This DELETE is
            # confined to the outer rollback transaction, preserving the seed.
            from models.odds.odds import Odds
            session.query(Odds).delete()
            from models.odds.bookmaker import Bookmaker
            session.query(Bookmaker).filter(Bookmaker.bookmaker_id != 910000001).delete()
            yield session
        finally:
            session.close()
            transaction.rollback()
    engine.dispose()


@pytest.fixture
def match_factory(db_session):
    from datetime import datetime, timezone, timedelta
    from models.matches.match import Match
    def create(**values):
        defaults = dict(fixture_id='package-test-match', home_team='Home', away_team='Away',
                        start_time=datetime.now(timezone.utc) + timedelta(days=1),
                        competition='Fixture', status='PRE_GAME')
        defaults.update(values)
        row = Match(**defaults)
        db_session.add(row)
        db_session.commit()
        return row
    return create


@pytest.fixture
def bookmaker_factory(db_session):
    from models.odds.bookmaker import Bookmaker
    def create(**values):
        row = Bookmaker(**values)
        db_session.add(row)
        db_session.commit()
        return row
    return create
