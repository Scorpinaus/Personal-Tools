from __future__ import annotations

import time
from typing import Any

import requests


class RedditAPIError(RuntimeError):
    pass


class RedditAPIClient:
    token_url = "https://www.reddit.com/api/v1/access_token"
    api_base = "https://oauth.reddit.com"

    def __init__(
        self,
        *,
        client_id: str,
        client_secret: str,
        user_agent: str,
        timeout: int = 20,
    ) -> None:
        self.client_id = client_id
        self.client_secret = client_secret
        self.user_agent = user_agent
        self.timeout = timeout
        self.session = requests.Session()
        self.access_token = ""
        self.expires_at = 0.0
        self.last_rate_limit: dict[str, float | None] = {
            "used": None,
            "remaining": None,
            "reset": None,
        }

    def _headers(self) -> dict[str, str]:
        return {"User-Agent": self.user_agent}

    def _bearer_headers(self) -> dict[str, str]:
        headers = self._headers()
        headers["Authorization"] = f"Bearer {self.access_token}"
        return headers

    def ensure_token(self) -> None:
        if self.access_token and time.time() < self.expires_at - 60:
            return

        response = self.session.post(
            self.token_url,
            auth=(self.client_id, self.client_secret),
            data={"grant_type": "client_credentials"},
            headers=self._headers(),
            timeout=self.timeout,
        )
        if response.status_code >= 400:
            raise RedditAPIError(f"OAuth token request failed with HTTP {response.status_code}.")

        payload = response.json()
        token = payload.get("access_token")
        if not token:
            raise RedditAPIError("OAuth token response did not include an access token.")
        self.access_token = token
        self.expires_at = time.time() + int(payload.get("expires_in", 3600))

    def search_subreddit(
        self,
        *,
        subreddit: str,
        query: str,
        after: str | None = None,
        limit: int = 100,
    ) -> dict[str, Any]:
        self.ensure_token()
        params: dict[str, Any] = {
            "q": query,
            "restrict_sr": "1",
            "sort": "new",
            "limit": min(limit, 100),
            "type": "link",
            "raw_json": "1",
        }
        if after:
            params["after"] = after

        response = self.session.get(
            f"{self.api_base}/r/{subreddit}/search",
            params=params,
            headers=self._bearer_headers(),
            timeout=self.timeout,
        )
        self.last_rate_limit = {
            "used": _float_header(response.headers.get("X-Ratelimit-Used")),
            "remaining": _float_header(response.headers.get("X-Ratelimit-Remaining")),
            "reset": _float_header(response.headers.get("X-Ratelimit-Reset")),
        }

        if response.status_code == 401:
            self.access_token = ""
            self.ensure_token()
            response = self.session.get(
                f"{self.api_base}/r/{subreddit}/search",
                params=params,
                headers=self._bearer_headers(),
                timeout=self.timeout,
            )

        if response.status_code >= 400:
            raise RedditAPIError(
                f"Search for r/{subreddit} failed with HTTP {response.status_code}."
            )
        return response.json()


def _float_header(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None
