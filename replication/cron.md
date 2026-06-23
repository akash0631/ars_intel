# ars_replicate — Windows Task Scheduler recipe

Run incremental replication every 15 minutes on the data-loader VM.

## One-time setup

1. Install Python 3.11+ and the ODBC Driver 17 for SQL Server.
2. Create venv and install deps:
   ```powershell
   cd C:\Users\akash.agarwal\projects\ars_intel\replication
   python -m venv .venv
   .\.venv\Scripts\pip install -r requirements.txt
   ```
3. Copy `.env.example` to `.env` and fill in `SQL_PASSWORD` and `SNOWFLAKE_PASSWORD`.
4. First load (full):
   ```powershell
   .\.venv\Scripts\python ars_replicate.py --full
   ```

## Task Scheduler entry

- **Name:** `ars_intel_replicate_incremental`
- **Trigger:** Daily, repeat every 15 minutes, indefinitely
- **Action:** Start a program
  - **Program/script:** `C:\Users\akash.agarwal\projects\ars_intel\replication\.venv\Scripts\python.exe`
  - **Arguments:** `ars_replicate.py --incremental`
  - **Start in:** `C:\Users\akash.agarwal\projects\ars_intel\replication`
- **Settings:**
  - Run whether user is logged on or not
  - Run with highest privileges
  - If task is already running: Do not start a new instance
  - Stop the task if it runs longer than: 1 hour

## Manual full reseed

Use after schema changes or to repair drift:
```powershell
.\.venv\Scripts\python ars_replicate.py --full
```

## Subset replication

For example, after a bad ARS session you want to refresh just two big tables:
```powershell
.\.venv\Scripts\python ars_replicate.py --incremental --tables ARS_LISTING_HISTORY,ARS_ALLOC_HISTORY
```

## Logs

Stdout/stderr in Task Scheduler History tab. For persistent logs, wrap the call:
```powershell
.\.venv\Scripts\python ars_replicate.py --incremental *>> C:\Users\akash.agarwal\projects\ars_intel\replication\logs\replicate.log
```
