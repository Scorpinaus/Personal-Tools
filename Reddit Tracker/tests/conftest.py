from __future__ import annotations

import pytest

from reddit_tracker import create_app


@pytest.fixture
def app(tmp_path):
    app = create_app(
        {
            "TESTING": True,
            "DATABASE_PATH": tmp_path / "reddit_tracker_test.sqlite",
            "REDDIT_CLIENT_ID": "client-id",
            "REDDIT_CLIENT_SECRET": "client-secret",
            "REDDIT_USER_AGENT": "windows:personal.reddit-tracker:test (by /u/test)",
            "RETENTION_HOURS": 48,
            "MAX_PAGES_PER_SEARCH": 1,
        }
    )
    yield app


@pytest.fixture
def client(app):
    return app.test_client()
