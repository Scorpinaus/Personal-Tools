from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path

SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS communities (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS terms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    phrase TEXT NOT NULL UNIQUE COLLATE NOCASE,
    active INTEGER NOT NULL DEFAULT 1,
    case_sensitive INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS posts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    reddit_id TEXT NOT NULL UNIQUE,
    reddit_short_id TEXT NOT NULL,
    subreddit TEXT NOT NULL,
    author TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    selftext TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL DEFAULT '',
    permalink TEXT NOT NULL DEFAULT '',
    score INTEGER NOT NULL DEFAULT 0,
    num_comments INTEGER NOT NULL DEFAULT 0,
    created_utc INTEGER NOT NULL DEFAULT 0,
    over_18 INTEGER NOT NULL DEFAULT 0,
    spoiler INTEGER NOT NULL DEFAULT 0,
    removed INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    content_expires_at TEXT,
    read INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_posts_subreddit ON posts(subreddit);
CREATE INDEX IF NOT EXISTS idx_posts_created_utc ON posts(created_utc DESC);
CREATE INDEX IF NOT EXISTS idx_posts_archived_read ON posts(archived, read);

CREATE TABLE IF NOT EXISTS post_matches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    matched_fields TEXT NOT NULL,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    UNIQUE(post_id, term_id)
);

CREATE INDEX IF NOT EXISTS idx_post_matches_term_id ON post_matches(term_id);

CREATE TABLE IF NOT EXISTS sync_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    communities_count INTEGER NOT NULL DEFAULT 0,
    terms_count INTEGER NOT NULL DEFAULT 0,
    requests_made INTEGER NOT NULL DEFAULT 0,
    posts_seen INTEGER NOT NULL DEFAULT 0,
    posts_saved INTEGER NOT NULL DEFAULT 0,
    matches_saved INTEGER NOT NULL DEFAULT 0,
    errors TEXT NOT NULL DEFAULT '[]',
    rate_limit_used REAL,
    rate_limit_remaining REAL,
    rate_limit_reset REAL
);
"""


def utcnow() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def utcnow_plus(hours: int) -> str:
    return (datetime.now(UTC) + timedelta(hours=hours)).isoformat(timespec="seconds")


def connect_db(database_path: Path) -> sqlite3.Connection:
    database_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(str(database_path), check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    return connection


def init_db(database_path: Path) -> None:
    with connect_db(database_path) as connection:
        connection.executescript(SCHEMA)
