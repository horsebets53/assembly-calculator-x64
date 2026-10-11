@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Native Windows build: UASM x64 + MSYS2 UCRT64 GCC. No WSL required.
rem Override executable paths with UASM and GCC (values without outer quotes).
pushd "%~dp0"
if errorlevel 1 exit /b 1
if /I "%~1"=="clean" goto clean
if not "%~1"=="" goto usage

if not defined UASM set "UASM=uasm.exe"
if not defined GCC set "GCC=C:\msys64\ucrt64\bin\gcc.exe"

where "%UASM%" >nul 2>&1
if errorlevel 1 (
    echo Error: UASM not found. Add it to PATH or set UASM to its full path.
    goto fail
)
"%GCC%" --version >nul 2>&1
if errorlevel 1 (
    echo Error: GCC not found. Install MSYS2 UCRT64 GCC or set GCC to its full path.
    goto fail
)

rem Separate .obj files allow Linux .o files to coexist with Windows builds.
for %%m in (lexer evaluator calculator windows) do (
    "%UASM%" -win64 -D__WINDOWS__ -Fo%%m.obj %%m.asm
    if errorlevel 1 goto fail
)
"%GCC%" calculator.obj lexer.obj evaluator.obj windows.obj -Wl,--nxcompat,--dynamicbase -o calculator.exe
if errorlevel 1 goto fail

echo Build successful! Run calculator.exe
popd
exit /b 0

:clean
for %%f in (calculator.exe lexer.obj evaluator.obj calculator.obj windows.obj) do (
    if exist "%%f" (
        del /q "%%f"
        if errorlevel 1 goto fail
    )
)
popd
exit /b 0

:usage
echo Usage: build.bat [clean]
:fail
popd
exit /b 1
