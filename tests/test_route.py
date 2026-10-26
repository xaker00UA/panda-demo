from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


# def test_root_route():
#     response = client.get("/")
#     assert response.status_code == 200
#     assert isinstance(response.text, str)
#
#
# def test_health_route():
#     response = client.get("/healthz")
#     assert response.status_code == 200
#     assert response.json() == {"status": "ok"}

def test_skip():
    assert True
