from __future__ import annotations

from typing import Any

from flask import Flask, current_app, g, jsonify, request, send_from_directory

from . import storage
from .config import BASE_DIR, load_settings, missing_reddit_credentials
from .db import connect_db, init_db
from .reddit_client import RedditAPIClient
from .sync import SyncAlreadyRunning, SyncManager


def create_app(test_config: dict[str, Any] | None = None) -> Flask:
    settings = load_settings(test_config)
    app = Flask(
        __name__,
        static_folder=str(BASE_DIR / "static"),
        static_url_path="/static",
    )
    app.config.update(settings)
    init_db(app.config["DATABASE_PATH"])

    def reddit_client_factory() -> RedditAPIClient:
        return RedditAPIClient(
            client_id=app.config["REDDIT_CLIENT_ID"],
            client_secret=app.config["REDDIT_CLIENT_SECRET"],
            user_agent=app.config["REDDIT_USER_AGENT"],
        )

    app.extensions["sync_manager"] = SyncManager(
        database_path=app.config["DATABASE_PATH"],
        retention_hours=app.config["RETENTION_HOURS"],
        max_pages_per_search=app.config["MAX_PAGES_PER_SEARCH"],
        reddit_client_factory=reddit_client_factory,
    )

    @app.teardown_appcontext
    def close_db(_error: Exception | None = None) -> None:
        connection = g.pop("db", None)
        if connection is not None:
            connection.close()

    @app.get("/")
    def index():
        return send_from_directory(app.static_folder, "index.html")

    @app.get("/api/config")
    def config():
        db = get_db()
        missing_credentials = missing_reddit_credentials(app.config)
        return jsonify(
            {
                "credentials_ready": not missing_credentials,
                "missing_credentials": missing_credentials,
                "retention_hours": app.config["RETENTION_HOURS"],
                "max_pages_per_search": app.config["MAX_PAGES_PER_SEARCH"],
                "communities": storage.list_communities(db),
                "terms": storage.list_terms(db),
                "latest_sync": storage.latest_sync_run(db),
                "sync_running": app.extensions["sync_manager"].is_running,
            }
        )

    @app.get("/api/communities")
    def communities():
        return jsonify({"communities": storage.list_communities(get_db())})

    @app.post("/api/communities")
    def add_community():
        payload = request.get_json(silent=True) or {}
        try:
            community = storage.upsert_community(
                get_db(),
                payload.get("name", ""),
                active=bool(payload.get("active", True)),
            )
            get_db().commit()
        except ValueError as exc:
            return api_error(str(exc), 400)
        return jsonify({"community": community}), 201

    @app.patch("/api/communities/<int:community_id>")
    def patch_community(community_id: int):
        payload = request.get_json(silent=True) or {}
        try:
            community = storage.update_community(
                get_db(),
                community_id,
                name=payload.get("name") if "name" in payload else None,
                active=bool(payload["active"]) if "active" in payload else None,
            )
            get_db().commit()
        except ValueError as exc:
            return api_error(str(exc), 400)
        if community is None:
            return api_error("Community not found.", 404)
        return jsonify({"community": community})

    @app.delete("/api/communities/<int:community_id>")
    def remove_community(community_id: int):
        deleted = storage.delete_community(get_db(), community_id)
        get_db().commit()
        if not deleted:
            return api_error("Community not found.", 404)
        return "", 204

    @app.get("/api/terms")
    def terms():
        return jsonify({"terms": storage.list_terms(get_db())})

    @app.post("/api/terms")
    def add_term():
        payload = request.get_json(silent=True) or {}
        try:
            term = storage.upsert_term(
                get_db(),
                payload.get("phrase", ""),
                active=bool(payload.get("active", True)),
                case_sensitive=bool(payload.get("case_sensitive", False)),
            )
            get_db().commit()
        except ValueError as exc:
            return api_error(str(exc), 400)
        return jsonify({"term": term}), 201

    @app.patch("/api/terms/<int:term_id>")
    def patch_term(term_id: int):
        payload = request.get_json(silent=True) or {}
        try:
            term = storage.update_term(
                get_db(),
                term_id,
                phrase=payload.get("phrase") if "phrase" in payload else None,
                active=bool(payload["active"]) if "active" in payload else None,
                case_sensitive=(
                    bool(payload["case_sensitive"]) if "case_sensitive" in payload else None
                ),
            )
            get_db().commit()
        except ValueError as exc:
            return api_error(str(exc), 400)
        if term is None:
            return api_error("Term not found.", 404)
        return jsonify({"term": term})

    @app.delete("/api/terms/<int:term_id>")
    def remove_term(term_id: int):
        deleted = storage.delete_term(get_db(), term_id)
        get_db().commit()
        if not deleted:
            return api_error("Term not found.", 404)
        return "", 204

    @app.post("/api/sync")
    def start_sync():
        missing_credentials = missing_reddit_credentials(app.config)
        if missing_credentials:
            return api_error(
                "Missing Reddit OAuth settings: " + ", ".join(missing_credentials),
                400,
            )
        try:
            run_id = app.extensions["sync_manager"].start()
        except SyncAlreadyRunning as exc:
            return api_error(str(exc), 409)
        return jsonify({"run_id": run_id, "status": "running"}), 202

    @app.get("/api/sync/latest")
    def latest_sync():
        return jsonify(
            {
                "latest_sync": storage.latest_sync_run(get_db()),
                "sync_running": app.extensions["sync_manager"].is_running,
            }
        )

    @app.get("/api/posts")
    def posts():
        try:
            term_id = request.args.get("term_id", type=int)
            limit = min(max(request.args.get("limit", default=100, type=int), 1), 200)
            posts = storage.list_posts(
                get_db(),
                subreddit=request.args.get("subreddit") or None,
                term_id=term_id,
                text=request.args.get("q") or None,
                include_archived=request.args.get("include_archived") == "1",
                read_state=request.args.get("read", "all"),
                limit=limit,
            )
        except ValueError as exc:
            return api_error(str(exc), 400)
        return jsonify({"posts": posts})

    @app.patch("/api/posts/<reddit_id>")
    def patch_post(reddit_id: str):
        payload = request.get_json(silent=True) or {}
        post = storage.update_post_flags(
            get_db(),
            reddit_id,
            read=bool(payload["read"]) if "read" in payload else None,
            archived=bool(payload["archived"]) if "archived" in payload else None,
        )
        get_db().commit()
        if post is None:
            return api_error("Post not found.", 404)
        return jsonify({"post": post})

    return app


def get_db():
    if "db" not in g:
        g.db = connect_db(current_app.config["DATABASE_PATH"])
    return g.db


def api_error(message: str, status_code: int):
    return jsonify({"error": message}), status_code
