@echo off
setlocal

set "ENGINE_DIR=%~dp0"
set "PERL_EXE=C:\Strawberry\perl\bin\perl.exe"
set "BOOST_INCLUDEDIR=C:\Users\efrai\AppData\Local\Temp\opencode\vcpkg\installed\x64-mingw-static\include"
set "BOOST_LIBRARYPATH=C:\Users\efrai\AppData\Local\Temp\opencode\vcpkg\installed\x64-mingw-static\lib"
set "PATH=C:\Strawberry\perl\bin;C:\Strawberry\c\bin;%PATH%"

if not exist "%PERL_EXE%" (
  echo ERROR: perl.exe not found at %PERL_EXE%
  echo Edit run-slicer.bat and update PERL_EXE.
  exit /b 1
)

"%PERL_EXE%" "%ENGINE_DIR%slic3r.pl" %*
exit /b %ERRORLEVEL%
