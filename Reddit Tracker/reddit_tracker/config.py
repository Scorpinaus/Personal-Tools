from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv


BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DATA_DIR = BASE_DIR / "data"


def _path_from_env(value: str | None, default: Path) -> Path:
    path = Path(value) if value else default
    if not path.is_absolute():
        path = BASE_DIR / path
    return path


def _int_from_env(name: str, default: int) -> int:
    raw = os.getenv(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def load_settings(overrides: dict[str, Any] | None = None) -> dict[str, Any]:
    load_dotenv(BASE_DIR / ".env")

    data_dir = _path_from_env(os.getenv("REDDIT_TRACKER_DATA_DIR"), DEFAULT_DATA_DIR)
    settings: dict[str, Any] = {
        "BASE_DIR": BASE_DIR,
        "DATA_DIR": data_dir,
        "DATABASE_PATH": _path_from_env(
            os.getenv("REDDIT_TRACKER_DATABASE"),
            data_dir / "reddit_tracker.sqlite",
        ),
        "RETENTION_HOURS": _int_from_env("REDDIT_TRACKER_RETENTION_HOURS", 48),
        "MAX_PAGES_PER_SEARCH": max(_int_from_env("REDDIT_TRACKER_MAX_PAGES_PER_SEARCH", 1), 1),
        "REDDIT_CLIENT_ID": os.getenv("REDDIT_CLIENT_ID", "").strip(),
        "REDDIT_CLIENT_SECRET": os.getenv("REDDIT_CLIENT_SECRET", "").strip(),
        "REDDIT_USER_AGENT": os.getenv("REDDIT_USER_AGENT", "").strip(),
    }

    if overrides:
        settings.update(overrides)

    for key in ("BASE_DIR", "DATA_DIR", "DATABASE_PATH"):
        settings[key] = Path(settings[key])

    return settings


def missing_reddit_credentials(settings: dict[str, Any]) -> list[str]:
    missing = []
    for key in ("REDDIT_CLIENT_ID", "REDDIT_CLIENT_SECRET", "REDDIT_USER_AGENT"):
        if not str(settings.get(key, "")).strip():
            missing.append(key)
    return missing
