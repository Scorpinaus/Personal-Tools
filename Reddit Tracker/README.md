# Reddit Tracker

A local dashboard for searching selected Reddit communities for specific terms, saving matching posts in SQLite, and reviewing them without opening Reddit.

## Setup

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
```

Edit `.env` with a Reddit OAuth app's client ID, client secret, and a descriptive user agent.

## Run

```powershell
.venv\Scripts\python.exe -m flask --app app run --host 127.0.0.1 --port 5050
```

Open `http://127.0.0.1:5050`.

## Test

```powershell
.venv\Scripts\python.exe -m pytest -q
```

## Notes

- Syncs run only when the dashboard's `Run Sync` button is clicked.
- Full post content is cleared after 48 hours by default; minimal metadata remains.
- The SQLite database is created at `data/reddit_tracker.sqlite` unless `REDDIT_TRACKER_DATABASE` is set.
- Increase `REDDIT_TRACKER_MAX_PAGES_PER_SEARCH` only if you want each community/term pair to fetch beyond the first 100 results.
