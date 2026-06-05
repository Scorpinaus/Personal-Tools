from __future__ import annotations

from reddit_tracker import storage
from reddit_tracker.db import connect_db
from reddit_tracker.sync import SyncAlreadyRunning

from .test_storage import sample_post


def test_community_and_term_api(client):
    community_response = client.post("/api/communities", json={"name": "r/Python"})
    term_response = client.post("/api/terms", json={"phrase": "Flask"})
    config_response = client.get("/api/config")

    assert community_response.status_code == 201
    assert community_response.get_json()["community"]["name"] == "python"
    assert term_response.status_code == 201
    assert term_response.get_json()["term"]["phrase"] == "Flask"

    config = config_response.get_json()
    assert config["credentials_ready"] is True
    assert len(config["communities"]) == 1
    assert len(config["terms"]) == 1


def test_invalid_community_is_rejected(client):
    response = client.post("/api/communities", json={"name": "not a subreddit!"})

    assert response.status_code == 400
    assert "error" in response.get_json()


def test_posts_api_filters_and_updates_flags(app, client):
    with connect_db(app.config["DATABASE_PATH"]) as connection:
        term = storage.upsert_term(connection, "Flask")
        post_id, _created = storage.upsert_post(connection, sample_post(), retention_hours=48)
        storage.upsert_post_match(connection, post_id, term["id"], ["title"])
        connection.commit()

    list_response = client.get("/api/posts?q=tracker&read=unread")
    patch_response = client.patch("/api/posts/t3_abc", json={"read": True, "archived": True})
    hidden_response = client.get("/api/posts")
    archived_response = client.get("/api/posts?include_archived=1&read=read")

    assert list_response.status_code == 200
    assert len(list_response.get_json()["posts"]) == 1
    assert patch_response.get_json()["post"]["read"] == 1
    assert patch_response.get_json()["post"]["archived"] == 1
    assert hidden_response.get_json()["posts"] == []
    assert len(archived_response.get_json()["posts"]) == 1


def test_sync_rejects_concurrent_run(app, client):
    class BusySyncManager:
        is_running = True

        def start(self):
            raise SyncAlreadyRunning("A sync is already running.")

    app.extensions["sync_manager"] = BusySyncManager()
    response = client.post("/api/sync")

    assert response.status_code == 409
    assert response.get_json()["error"] == "A sync is already running."
