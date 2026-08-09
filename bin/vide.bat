@echo off
setlocal
set "VIDE_DIR=%~dp0.."
if defined VIDE_VIM (
  set "VIDE_VIM_BIN=%VIDE_VIM%"
) else (
  set "VIDE_VIM_BIN=vim"
)
"%VIDE_VIM_BIN%" -Nu "%VIDE_DIR%\src\vide.vim" -U NONE -N -i NONE %*
