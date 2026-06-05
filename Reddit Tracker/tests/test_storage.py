from __future__ import annotations

from reddit_tracker import storage
from reddit_tracker.db import connect_db, init_db


def sample_post(reddit_id: str = "t3_abc") -> dict:
    return {
        "reddit_id": reddit_id,
        "reddit_short_id": reddit_id.replace("t3_", ""),
        "subreddit": "python",
        "author": "example_author",
        "title": "Flask project tracker",
        "selftext": "A small local dashboard.",
        "url": "https://example.test/post",
        "permalink": "https://www.reddit.com/r/python/comments/abc/flask_project_tracker/",
        "score": 12,
        "num_comments": 3,
        "created_utc": 1780580000,
        "over_18": False,
        "spoiler": False,
        "removed": False,
        "deleted": False,
    }


def test_schema_upsert_and_deduplicate_posts(tmp_path):
    db_path = tmp_path / "tracker.sqlite"
    init_db(db_path)
    with connect_db(db_path) as connection:
        community = storage.upsert_community(connection, "r/Python")
        term = storage.upsert_term(connection, "Flask")
        post_id, created = storage.upsert_post(connection, sample_post(), retention_hours=48)
        match_created = storage.upsert_post_match(connection, post_id, term["id"], ["title"])
        duplicate_id, duplicate_created = storage.upsert_post(
            connection,
            sample_post(),
            retention_hours=48,
        )
        connection.commit()

        posts = storage.list_posts(connection)

    assert community["name"] == "python"
    assert created is True
    assert match_created is True
    assert duplicate_id == post_id
    assert duplicate_created is False
    assert len(posts) == 1
    assert posts[0]["matched_terms"] == "Flask"


def test_purge_expired_content_keeps_metadata(tmp_path):
    db_path = tmp_path / "tracker.sqlite"
    init_db(db_path)
    with connect_db(db_path) as connection:
        post_id, _created = storage.upsert_post(connection, sample_post(), retention_hours=48)
        connection.execute(
            "UPDATE posts SET content_expires_at = ? WHERE id = ?",
            ("2026-01-01T00:00:00+00:00", post_id),
        )
        purged = storage.purge_expired_content(
            connection,
            now_iso="2026-01-03T00:00:00+00:00",
        )
        row = connection.execute("SELECT * FROM posts WHERE id = ?", (post_id,)).fetchone()

    assert purged == 1
    assert row["subreddit"] == "python"
    assert row["reddit_id"] == "t3_abc"
    assert row["title"] == ""
    assert row["selftext"] == ""
    assert row["url"] == ""
    assert row["content_expires_at"] is None
