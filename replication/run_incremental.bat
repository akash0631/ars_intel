@echo off
REM ars_intel incremental replication — Task Scheduler entry point
REM Runs every 30 min. Pulls deltas from arsdbpro/Rep_Data to V2RETAIL.ARS_BRONZE.

setlocal
set "ARS_INTEL_DIR=C:\Users\akash.agarwal\projects\ars_intel"
set "PATH=%PATH%;%LocalAppData%\Programs\Python\Python312"
cd /d "%ARS_INTEL_DIR%"
set "SQL_PASSWORD=Vrl@12345"
python replication\ars_replicate.py --incremental >> "%ARS_INTEL_DIR%\.secrets\replicate_inc.log" 2>&1
endlocal
