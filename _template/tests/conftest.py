import pytest
from fastapi.testclient import TestClient

from app.database import Base, engine, get_db, SessionLocal
from app.main import app


@pytest.fixture(autouse=True)
def setup_db():
    """Ensure all tables exist before tests run."""
    Base.metadata.create_all(bind=engine)
    yield


@pytest.fixture()
def db():
    """Provide a database session that rolls back after each test."""
    session = SessionLocal()
    session.begin_nested()
    try:
        yield session
    finally:
        session.rollback()
        session.close()


@pytest.fixture()
def client(db):
    """Provide a FastAPI test client with the test DB session injected."""

    def override_get_db():
        try:
            yield db
        finally:
            pass

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()
