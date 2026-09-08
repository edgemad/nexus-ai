@echo off
rem ============================================================
rem  Nexus AI backend verify - Windows
rem  Pings /version on each service port. A response of any kind
rem  (including {"ok":false,"error":{"code":"unauthorized",...}})
rem  proves the service is up; 'failed to connect' means it is not.
rem  Optionally set NEXIE_AUTH_TOKEN to see the full version reply.
rem ============================================================
setlocal EnableDelayedExpansion
set "TOK=%NEXIE_AUTH_TOKEN%"
if not "%TOK%"=="" set "HDR=-H "Authorization: Bearer %TOK%""
set "ALLUP=1"
for %%p in (8765 8766 8767) do (
    echo -- probing :%%p
    curl -s -m 3 %HDR% http://127.0.0.1:%%p/version
    echo.
    if errorlevel 1 set "ALLUP=0"
)
if "%ALLUP%"=="1" (echo ==^> All three services respond.) else (echo ==^> At least one service did not respond - is it running?)
endlocal