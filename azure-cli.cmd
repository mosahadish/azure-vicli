@echo off
where python >nul 2>nul || (
  echo azure-cli: python was not found on PATH - it runs the data provider ^(azure-cli.py^). 1>&2
  echo Install Python 3 from https://www.python.org/downloads/ ^(tick "Add python.exe to PATH"^), then run this again. 1>&2
  exit /b 127
)
python "%~dp0azure-cli.py" %*
