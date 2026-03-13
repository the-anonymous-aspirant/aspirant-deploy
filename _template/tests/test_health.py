"""Contract tests for the health endpoint.

Every service must expose GET /health with the standard shape.
See CONVENTIONS.md → API Contract → Health Endpoint.
"""


def test_app_imports():
    """The app module loads without errors."""
    from app.main import app

    assert app is not None


def test_health_returns_200(client):
    response = client.get("/health")
    assert response.status_code == 200


def test_health_response_shape(client):
    """Health response matches the standard contract."""
    data = client.get("/health").json()

    assert "status" in data
    assert "service" in data
    assert "version" in data
    assert "checks" in data
    assert isinstance(data["checks"], dict)


def test_health_status_is_ok_or_degraded(client):
    data = client.get("/health").json()
    assert data["status"] in ("ok", "degraded")
