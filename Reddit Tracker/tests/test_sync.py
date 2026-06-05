from __future__ import annotations

from reddit_tracker import storage
from reddit_tracker.db import connect_db, init_db
from reddit_tracker.sync import SyncService, matching_fields, post_from_reddit


class FakeRedditClient:
    def __init__(self):
        self.last_rate_limit = {"used": 1.0, "remaining": 42.0, "reset": 60.0}
        self.calls = 0

    def search_subreddit(self, *, subreddit, query, after=None, limit=100):
        self.calls += 1
        return {
            "data": {
                "after": None,
                "children": [
                    {
                        "kind": "t3",
                        "data": {
                            "id": "abc",
                            "name": "t3_abc",
                            "subreddit": subreddit,
                            "author": "poster",
                            "title": "Flask release notes",
                            "selftext": "A local tracker appears.",
                            "url": "https://example.test/flask",
                            "permalink": "/r/python/comments/abc/flask_release_notes/",
                            "score": 8,
                            "num_comments": 2,
                            "created_utc": 1780580000,
                        },
                    },
                    {
                        "kind": "t3",
                        "data": {
                            "id": "def",
                            "name": "t3_def",
                            "subreddit": subreddit,
                            "author": "poster",
                            "title": "Unrelated post",
                            "selftext": "",
                            "url": "https://example.test/other",
                            "permalink": "/r/python/comments/def/unrelated_post/",
                            "score": 1,
                            "num_comments": 0,
                            "created_utc": 1780580001,
                        },
                    },
                ],
            }
        }


def test_matching_fields_honors_case_sensitivity():
    post_data = {"title": "Flask Tracker", "selftext": "backend", "url": "https://example.test"}

    assert matching_fields(post_data, "flask") == ["title"]
    assert matching_fields(post_data, "flask", case_sensitive=True) == []
    assert matching_fields(post_data, "Flask", case_sensitive=True) == ["title"]


def test_removed_or_deleted_posts_clear_content():
    post = post_from_reddit(
        {
            "id": "abc",
            "name": "t3_abc",
            "subreddit": "python",
            "author": "[deleted]",
            "title": "[deleted]",
            "selftext": "[deleted]",
            "url": "https://example.test",
            "permalink": "/r/python/comments/abc/deleted/",
        }
    )

    assert post["deleted"] is True
    assert post["title"] == ""
    assert post["selftext"] == ""
    assert post["url"] == ""


def test_sync_service_saves_matches_and_deduplicates(tmp_path):
    db_path = tmp_path / "tracker.sqlite"
    init_db(db_path)
    with connect_db(db_path) as connection:
        storage.upsert_community(connection, "python")
        storage.upsert_term(connection, "Flask")
        run_id = storage.create_sync_run(connection, 1, 1)
        connection.commit()

    service = SyncService(
        database_path=db_path,
        retention_hours=48,
        max_pages_per_search=1,
        reddit_client_factory=FakeRedditClient,
    )
    stats = service.run(run_id)

    with connect_db(db_path) as connection:
        second_run_id = storage.create_sync_run(connection, 1, 1)
        connection.commit()
    second_stats = service.run(second_run_id)

    with connect_db(db_path) as connection:
        posts = storage.list_posts(connection, include_archived=True)
        latest = storage.latest_sync_run(connection)

    assert stats.posts_seen == 2
    assert stats.posts_saved == 1
    assert stats.matches_saved == 1
    assert second_stats.posts_saved == 0
    assert len(posts) == 1
    assert posts[0]["reddit_id"] == "t3_abc"
    assert latest["status"] == "completed"
