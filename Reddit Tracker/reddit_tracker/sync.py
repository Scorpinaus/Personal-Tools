from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Any, Callable

from . import storage
from .db import connect_db
from .reddit_client import RedditAPIClient, RedditAPIError


class SyncAlreadyRunning(RuntimeError):
    pass


@dataclass
class SyncStats:
    requests_made: int = 0
    posts_seen: int = 0
    posts_saved: int = 0
    matches_saved: int = 0
    errors: list[str] = field(default_factory=list)
    rate_limit: dict[str, float | None] = field(
        default_factory=lambda: {"used": None, "remaining": None, "reset": None}
    )


def matching_fields(post_data: dict[str, Any], phrase: str, case_sensitive: bool = False) -> list[str]:
    fields = {
        "title": post_data.get("title") or "",
        "selftext": post_data.get("selftext") or "",
        "url": post_data.get("url") or "",
    }
    needle = phrase if case_sensitive else phrase.lower()
    matches = []
    for field_name, value in fields.items():
        haystack = value if case_sensitive else value.lower()
        if needle in haystack:
            matches.append(field_name)
    return matches


def post_from_reddit(post_data: dict[str, Any]) -> dict[str, Any]:
    short_id = str(post_data.get("id") or "")
    reddit_id = str(post_data.get("name") or f"t3_{short_id}")
    title = str(post_data.get("title") or "")
    selftext = str(post_data.get("selftext") or "")
    url = str(post_data.get("url") or "")
    author = str(post_data.get("author") or "")
    deleted = title == "[deleted]" or selftext == "[deleted]" or author == "[deleted]"
    removed = title == "[removed]" or selftext == "[removed]"
    if deleted or removed:
        title = ""
        selftext = ""
        url = ""
        author = ""

    permalink = str(post_data.get("permalink") or "")
    if permalink.startswith("/"):
        permalink = f"https://www.reddit.com{permalink}"

    return {
        "reddit_id": reddit_id,
        "reddit_short_id": short_id,
        "subreddit": storage.normalize_subreddit(str(post_data.get("subreddit") or "")),
        "author": author,
        "title": title,
        "selftext": selftext,
        "url": url,
        "permalink": permalink,
        "score": int(post_data.get("score") or 0),
        "num_comments": int(post_data.get("num_comments") or 0),
        "created_utc": int(float(post_data.get("created_utc") or 0)),
        "over_18": bool(post_data.get("over_18")),
        "spoiler": bool(post_data.get("spoiler")),
        "removed": removed,
        "deleted": deleted,
    }


class SyncService:
    def __init__(
        self,
        *,
        database_path,
        retention_hours: int,
        max_pages_per_search: int,
        reddit_client_factory: Callable[[], RedditAPIClient],
    ) -> None:
        self.database_path = database_path
        self.retention_hours = retention_hours
        self.max_pages_per_search = max_pages_per_search
        self.reddit_client_factory = reddit_client_factory

    def run(self, run_id: int) -> SyncStats:
        stats = SyncStats()
        client = self.reddit_client_factory()

        with connect_db(self.database_path) as connection:
            storage.purge_expired_content(connection)
            communities = storage.list_communities(connection, active_only=True)
            terms = storage.list_terms(connection, active_only=True)
            connection.commit()

        for community in communities:
            for term in terms:
                after = None
                for _page in range(self.max_pages_per_search):
                    try:
                        payload = client.search_subreddit(
                            subreddit=community["name"],
                            query=term["phrase"],
                            after=after,
                            limit=100,
                        )
                        stats.requests_made += 1
                        stats.rate_limit = client.last_rate_limit
                    except RedditAPIError as exc:
                        stats.errors.append(
                            f"r/{community['name']} search for {term['phrase']!r}: {exc}"
                        )
                        break

                    data = payload.get("data") or {}
                    children = data.get("children") or []
                    with connect_db(self.database_path) as connection:
                        for child in children:
                            if child.get("kind") != "t3":
                                continue
                            post_data = child.get("data") or {}
                            stats.posts_seen += 1
                            fields = matching_fields(
                                post_data,
                                term["phrase"],
                                bool(term["case_sensitive"]),
                            )
                            if not fields:
                                continue
                            post_id, created_post = storage.upsert_post(
                                connection,
                                post_from_reddit(post_data),
                                retention_hours=self.retention_hours,
                            )
                            created_match = storage.upsert_post_match(
                                connection,
                                post_id,
                                int(term["id"]),
                                fields,
                            )
                            if created_post:
                                stats.posts_saved += 1
                            if created_match:
                                stats.matches_saved += 1
                        storage.purge_expired_content(connection)
                        connection.commit()

                    remaining = stats.rate_limit.get("remaining")
                    if remaining is not None and remaining <= 1:
                        stats.errors.append("Reddit rate limit is nearly exhausted; sync stopped early.")
                        self._finish(run_id, stats, "rate_limited")
                        return stats

                    after = data.get("after")
                    if not after:
                        break

        status = "completed_with_errors" if stats.errors else "completed"
        self._finish(run_id, stats, status)
        return stats

    def _finish(self, run_id: int, stats: SyncStats, status: str) -> None:
        with connect_db(self.database_path) as connection:
            storage.finish_sync_run(
                connection,
                run_id,
                status=status,
                requests_made=stats.requests_made,
                posts_seen=stats.posts_seen,
                posts_saved=stats.posts_saved,
                matches_saved=stats.matches_saved,
                errors=stats.errors,
                rate_limit=stats.rate_limit,
            )
            connection.commit()


class SyncManager:
    def __init__(
        self,
        *,
        database_path,
        retention_hours: int,
        max_pages_per_search: int,
        reddit_client_factory: Callable[[], RedditAPIClient],
    ) -> None:
        self.database_path = database_path
        self.retention_hours = retention_hours
        self.max_pages_per_search = max_pages_per_search
        self.reddit_client_factory = reddit_client_factory
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None

    @property
    def is_running(self) -> bool:
        return self._lock.locked()

    def start(self) -> int:
        if not self._lock.acquire(blocking=False):
            raise SyncAlreadyRunning("A sync is already running.")

        try:
            with connect_db(self.database_path) as connection:
                communities = storage.list_communities(connection, active_only=True)
                terms = storage.list_terms(connection, active_only=True)
                run_id = storage.create_sync_run(connection, len(communities), len(terms))
                connection.commit()
        except Exception:
            self._lock.release()
            raise

        self._thread = threading.Thread(target=self._run_thread, args=(run_id,), daemon=True)
        self._thread.start()
        return run_id

    def _run_thread(self, run_id: int) -> None:
        try:
            service = SyncService(
                database_path=self.database_path,
                retention_hours=self.retention_hours,
                max_pages_per_search=self.max_pages_per_search,
                reddit_client_factory=self.reddit_client_factory,
            )
            service.run(run_id)
        except Exception as exc:  # The dashboard should receive the failure instead of losing it.
            stats = SyncStats(errors=[f"Unexpected sync failure: {exc}"])
            with connect_db(self.database_path) as connection:
                storage.finish_sync_run(
                    connection,
                    run_id,
                    status="failed",
                    requests_made=stats.requests_made,
                    posts_seen=stats.posts_seen,
                    posts_saved=stats.posts_saved,
                    matches_saved=stats.matches_saved,
                    errors=stats.errors,
                    rate_limit=stats.rate_limit,
                )
                connection.commit()
        finally:
            self._lock.release()
