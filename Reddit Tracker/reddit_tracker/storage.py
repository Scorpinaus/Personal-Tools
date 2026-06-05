from __future__ import annotations

import json
import re
import sqlite3
from collections.abc import Iterable
from typing import Any

from .db import utcnow, utcnow_plus

SUBREDDIT_RE = re.compile(r"^[A-Za-z0-9_]{2,21}$")


def row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    return dict(row) if row is not None else None


def normalize_subreddit(value: str) -> str:
    name = (value or "").strip()
    name = re.sub(r"^https?://(www\.)?reddit\.com/r/", "", name, flags=re.IGNORECASE)
    name = name.strip().strip("/")
    if name.lower().startswith("r/"):
        name = name[2:]
    name = name.strip().strip("/")
    if not SUBREDDIT_RE.fullmatch(name):
        raise ValueError("Use a subreddit name like python or r/python.")
    return name.lower()


def normalize_term(value: str) -> str:
    phrase = (value or "").strip()
    if not phrase:
        raise ValueError("Search term cannot be empty.")
    if len(phrase) > 512:
        raise ValueError("Search term must be 512 characters or fewer.")
    return phrase


def list_communities(connection: sqlite3.Connection, active_only: bool = False) -> list[dict[str, Any]]:
    query = "SELECT * FROM communities"
    params: list[Any] = []
    if active_only:
        query += " WHERE active = 1"
    query += " ORDER BY name ASC"
    return [dict(row) for row in connection.execute(query, params)]


def upsert_community(connection: sqlite3.Connection, name: str, active: bool = True) -> dict[str, Any]:
    now = utcnow()
    normalized = normalize_subreddit(name)
    connection.execute(
        """
        INSERT INTO communities (name, active, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            active = excluded.active,
            updated_at = excluded.updated_at
        """,
        (normalized, int(active), now, now),
    )
    return dict(
        connection.execute("SELECT * FROM communities WHERE name = ?", (normalized,)).fetchone()
    )


def update_community(
    connection: sqlite3.Connection,
    community_id: int,
    *,
    name: str | None = None,
    active: bool | None = None,
) -> dict[str, Any] | None:
    existing = connection.execute("SELECT * FROM communities WHERE id = ?", (community_id,)).fetchone()
    if existing is None:
        return None

    new_name = normalize_subreddit(name) if name is not None else existing["name"]
    new_active = int(active) if active is not None else existing["active"]
    connection.execute(
        """
        UPDATE communities
        SET name = ?, active = ?, updated_at = ?
        WHERE id = ?
        """,
        (new_name, new_active, utcnow(), community_id),
    )
    return row_to_dict(connection.execute("SELECT * FROM communities WHERE id = ?", (community_id,)).fetchone())


def delete_community(connection: sqlite3.Connection, community_id: int) -> bool:
    cursor = connection.execute("DELETE FROM communities WHERE id = ?", (community_id,))
    return cursor.rowcount > 0


def list_terms(connection: sqlite3.Connection, active_only: bool = False) -> list[dict[str, Any]]:
    query = "SELECT * FROM terms"
    if active_only:
        query += " WHERE active = 1"
    query += " ORDER BY phrase COLLATE NOCASE ASC"
    return [dict(row) for row in connection.execute(query)]


def upsert_term(
    connection: sqlite3.Connection,
    phrase: str,
    *,
    active: bool = True,
    case_sensitive: bool = False,
) -> dict[str, Any]:
    now = utcnow()
    normalized = normalize_term(phrase)
    connection.execute(
        """
        INSERT INTO terms (phrase, active, case_sensitive, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(phrase) DO UPDATE SET
            active = excluded.active,
            case_sensitive = excluded.case_sensitive,
            updated_at = excluded.updated_at
        """,
        (normalized, int(active), int(case_sensitive), now, now),
    )
    return dict(connection.execute("SELECT * FROM terms WHERE phrase = ?", (normalized,)).fetchone())


def update_term(
    connection: sqlite3.Connection,
    term_id: int,
    *,
    phrase: str | None = None,
    active: bool | None = None,
    case_sensitive: bool | None = None,
) -> dict[str, Any] | None:
    existing = connection.execute("SELECT * FROM terms WHERE id = ?", (term_id,)).fetchone()
    if existing is None:
        return None

    new_phrase = normalize_term(phrase) if phrase is not None else existing["phrase"]
    new_active = int(active) if active is not None else existing["active"]
    new_case_sensitive = (
        int(case_sensitive) if case_sensitive is not None else existing["case_sensitive"]
    )
    connection.execute(
        """
        UPDATE terms
        SET phrase = ?, active = ?, case_sensitive = ?, updated_at = ?
        WHERE id = ?
        """,
        (new_phrase, new_active, new_case_sensitive, utcnow(), term_id),
    )
    return row_to_dict(connection.execute("SELECT * FROM terms WHERE id = ?", (term_id,)).fetchone())


def delete_term(connection: sqlite3.Connection, term_id: int) -> bool:
    cursor = connection.execute("DELETE FROM terms WHERE id = ?", (term_id,))
    return cursor.rowcount > 0


def create_sync_run(
    connection: sqlite3.Connection,
    communities_count: int,
    terms_count: int,
) -> int:
    cursor = connection.execute(
        """
        INSERT INTO sync_runs (started_at, status, communities_count, terms_count)
        VALUES (?, 'running', ?, ?)
        """,
        (utcnow(), communities_count, terms_count),
    )
    return int(cursor.lastrowid)


def finish_sync_run(
    connection: sqlite3.Connection,
    run_id: int,
    *,
    status: str,
    requests_made: int,
    posts_seen: int,
    posts_saved: int,
    matches_saved: int,
    errors: Iterable[str],
    rate_limit: dict[str, float | None] | None = None,
) -> None:
    rate_limit = rate_limit or {}
    connection.execute(
        """
        UPDATE sync_runs
        SET finished_at = ?,
            status = ?,
            requests_made = ?,
            posts_seen = ?,
            posts_saved = ?,
            matches_saved = ?,
            errors = ?,
            rate_limit_used = ?,
            rate_limit_remaining = ?,
            rate_limit_reset = ?
        WHERE id = ?
        """,
        (
            utcnow(),
            status,
            requests_made,
            posts_seen,
            posts_saved,
            matches_saved,
            json.dumps(list(errors)),
            rate_limit.get("used"),
            rate_limit.get("remaining"),
            rate_limit.get("reset"),
            run_id,
        ),
    )


def latest_sync_run(connection: sqlite3.Connection) -> dict[str, Any] | None:
    row = connection.execute("SELECT * FROM sync_runs ORDER BY id DESC LIMIT 1").fetchone()
    if row is None:
        return None
    data = dict(row)
    data["errors"] = json.loads(data.get("errors") or "[]")
    return data


def upsert_post(
    connection: sqlite3.Connection,
    post: dict[str, Any],
    *,
    retention_hours: int,
) -> tuple[int, bool]:
    reddit_id = post["reddit_id"]
    existing = connection.execute("SELECT id FROM posts WHERE reddit_id = ?", (reddit_id,)).fetchone()
    created = existing is None
    now = utcnow()
    content_expires_at = None
    if not post["deleted"] and not post["removed"]:
        content_expires_at = utcnow_plus(retention_hours)

    connection.execute(
        """
        INSERT INTO posts (
            reddit_id, reddit_short_id, subreddit, author, title, selftext, url, permalink,
            score, num_comments, created_utc, over_18, spoiler, removed, deleted,
            first_seen_at, last_seen_at, content_expires_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(reddit_id) DO UPDATE SET
            subreddit = excluded.subreddit,
            author = excluded.author,
            title = excluded.title,
            selftext = excluded.selftext,
            url = excluded.url,
            permalink = excluded.permalink,
            score = excluded.score,
            num_comments = excluded.num_comments,
            created_utc = excluded.created_utc,
            over_18 = excluded.over_18,
            spoiler = excluded.spoiler,
            removed = excluded.removed,
            deleted = excluded.deleted,
            last_seen_at = excluded.last_seen_at,
            content_expires_at = excluded.content_expires_at,
            updated_at = excluded.updated_at
        """,
        (
            reddit_id,
            post["reddit_short_id"],
            post["subreddit"],
            post["author"],
            post["title"],
            post["selftext"],
            post["url"],
            post["permalink"],
            post["score"],
            post["num_comments"],
            post["created_utc"],
            int(post["over_18"]),
            int(post["spoiler"]),
            int(post["removed"]),
            int(post["deleted"]),
            now,
            now,
            content_expires_at,
            now,
        ),
    )
    post_id = connection.execute("SELECT id FROM posts WHERE reddit_id = ?", (reddit_id,)).fetchone()["id"]
    return int(post_id), created


def upsert_post_match(
    connection: sqlite3.Connection,
    post_id: int,
    term_id: int,
    matched_fields: list[str],
) -> bool:
    existing = connection.execute(
        "SELECT id FROM post_matches WHERE post_id = ? AND term_id = ?",
        (post_id, term_id),
    ).fetchone()
    created = existing is None
    now = utcnow()
    connection.execute(
        """
        INSERT INTO post_matches (post_id, term_id, matched_fields, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(post_id, term_id) DO UPDATE SET
            matched_fields = excluded.matched_fields,
            last_seen_at = excluded.last_seen_at
        """,
        (post_id, term_id, ",".join(sorted(set(matched_fields))), now, now),
    )
    return created


def purge_expired_content(connection: sqlite3.Connection, *, now_iso: str | None = None) -> int:
    now_iso = now_iso or utcnow()
    cursor = connection.execute(
        """
        UPDATE posts
        SET author = '',
            title = '',
            selftext = '',
            url = '',
            content_expires_at = NULL,
            updated_at = ?
        WHERE content_expires_at IS NOT NULL
          AND content_expires_at <= ?
        """,
        (now_iso, now_iso),
    )
    return cursor.rowcount


def list_posts(
    connection: sqlite3.Connection,
    *,
    subreddit: str | None = None,
    term_id: int | None = None,
    text: str | None = None,
    include_archived: bool = False,
    read_state: str = "all",
    limit: int = 100,
) -> list[dict[str, Any]]:
    where = []
    params: list[Any] = []

    if subreddit:
        where.append("p.subreddit = ?")
        params.append(normalize_subreddit(subreddit))
    if term_id is not None:
        where.append(
            "EXISTS (SELECT 1 FROM post_matches pm_filter WHERE pm_filter.post_id = p.id AND pm_filter.term_id = ?)"
        )
        params.append(term_id)
    if text:
        where.append("(p.title LIKE ? OR p.selftext LIKE ? OR p.url LIKE ? OR p.subreddit LIKE ?)")
        needle = f"%{text}%"
        params.extend([needle, needle, needle, needle])
    if not include_archived:
        where.append("p.archived = 0")
    if read_state == "read":
        where.append("p.read = 1")
    elif read_state == "unread":
        where.append("p.read = 0")

    sql = """
        SELECT
            p.*,
            GROUP_CONCAT(DISTINCT t.phrase) AS matched_terms,
            GROUP_CONCAT(DISTINCT pm.matched_fields) AS matched_fields
        FROM posts p
        LEFT JOIN post_matches pm ON pm.post_id = p.id
        LEFT JOIN terms t ON t.id = pm.term_id
    """
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " GROUP BY p.id ORDER BY p.created_utc DESC, p.last_seen_at DESC LIMIT ?"
    params.append(limit)

    return [dict(row) for row in connection.execute(sql, params)]


def update_post_flags(
    connection: sqlite3.Connection,
    reddit_id: str,
    *,
    read: bool | None = None,
    archived: bool | None = None,
) -> dict[str, Any] | None:
    existing = connection.execute("SELECT * FROM posts WHERE reddit_id = ?", (reddit_id,)).fetchone()
    if existing is None:
        return None

    new_read = int(read) if read is not None else existing["read"]
    new_archived = int(archived) if archived is not None else existing["archived"]
    connection.execute(
        """
        UPDATE posts
        SET read = ?, archived = ?, updated_at = ?
        WHERE reddit_id = ?
        """,
        (new_read, new_archived, utcnow(), reddit_id),
    )
    return row_to_dict(connection.execute("SELECT * FROM posts WHERE reddit_id = ?", (reddit_id,)).fetchone())
