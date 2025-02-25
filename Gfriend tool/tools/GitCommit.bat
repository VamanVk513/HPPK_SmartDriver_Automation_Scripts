REM @echo off
cd %1

set RESTVAR=
shift
:loop1
if "%1"=="" goto after_loop
set RESTVAR=%RESTVAR% %1
shift
goto loop1

:after_loop

CALL :TRIM COMMENT %RESTVAR% 

git add .

git commit -m "%COMMENT%"

git push

pause


:Trim
SetLocal EnableDelayedExpansion
set Params=%*
for /f "tokens=1*" %%a in ("!Params!") do EndLocal & set %1=%%b
exit /b