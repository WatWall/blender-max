@echo off
REM Wrapper script that sets CUDA and OptiX paths and enables GPU kernel
REM compilation before building Blender.
REM
REM Usage: make_gpu.bat [make.bat arguments]
REM   All arguments are forwarded to make.bat (e.g. release, 2022, ninja, etc.)
REM
REM Edit the CUDA / OptiX paths below if your installations differ.

setlocal EnableDelayedExpansion

set BLENDER_DIR=%~dp0

REM =====================================================================
REM CUDA Toolkit Path
REM =====================================================================
set "CUDA_TOOLKIT_ROOT_DIR=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2"

REM =====================================================================
REM OptiX SDK Path
REM   Build-time: CMake uses this to find OptiX headers (optix.h)
REM   Runtime:    CYCLES_RUNTIME_OPTIX_ROOT_DIR is baked into the binary
REM               so Blender can JIT-compile OptiX kernels at runtime.
REM =====================================================================
set "OPTIX_ROOT_DIR=C:\ProgramData\NVIDIA Corporation\OptiX SDK 9.1.0"

REM =====================================================================
REM Verify paths exist
REM =====================================================================
if not exist "%CUDA_TOOLKIT_ROOT_DIR%\bin\nvcc.exe" (
    echo ERROR: CUDA Toolkit not found at "%CUDA_TOOLKIT_ROOT_DIR%"
    echo Please edit this script and set the correct CUDA_TOOLKIT_ROOT_DIR.
    exit /b 1
)

if not exist "%OPTIX_ROOT_DIR%\include\optix.h" (
    echo ERROR: OptiX SDK not found at "%OPTIX_ROOT_DIR%"
    echo Please edit this script and set the correct OPTIX_ROOT_DIR.
    exit /b 1
)

echo.
echo === GPU Build Configuration ===
echo CUDA Toolkit : %CUDA_TOOLKIT_ROOT_DIR%
echo OptiX SDK    : %OPTIX_ROOT_DIR%
echo ================================
echo.

REM =====================================================================
REM Create a CMake initial-cache file with GPU paths and options.
REM
REM Key options:
REM   WITH_CYCLES_CUDA_BINARIES      - Pre-compile CUDA .cubin kernels
REM   WITH_CYCLES_DEVICE_CUDA        - Enable CUDA render device
REM   WITH_CYCLES_DEVICE_OPTIX       - Enable OptiX render device
REM   CYCLES_RUNTIME_OPTIX_ROOT_DIR  - Bake OptiX SDK path for runtime
REM   CUDA_TOOLKIT_ROOT_DIR          - Where to find nvcc / CUDA toolkit
REM   OPTIX_ROOT_DIR                 - Where to find optix.h / OptiX SDK
REM =====================================================================
set _GPU_CACHE_FILE=%TEMP%\blender_gpu_cache.cmake

> "%_GPU_CACHE_FILE%" echo # Auto-generated GPU configuration for Blender build
>>"%_GPU_CACHE_FILE%" echo.
>>"%_GPU_CACHE_FILE%" echo # Paths
>>"%_GPU_CACHE_FILE%" echo set(CUDA_TOOLKIT_ROOT_DIR "%CUDA_TOOLKIT_ROOT_DIR%" CACHE PATH "CUDA Toolkit root" FORCE^)
>>"%_GPU_CACHE_FILE%" echo set(OPTIX_ROOT_DIR "%OPTIX_ROOT_DIR%" CACHE PATH "OptiX SDK root" FORCE^)
>>"%_GPU_CACHE_FILE%" echo set(CYCLES_RUNTIME_OPTIX_ROOT_DIR "%OPTIX_ROOT_DIR%" CACHE PATH "OptiX SDK for runtime JIT" FORCE^)
>>"%_GPU_CACHE_FILE%" echo.
>>"%_GPU_CACHE_FILE%" echo # Device support
>>"%_GPU_CACHE_FILE%" echo set(WITH_CYCLES_DEVICE_CUDA ON CACHE BOOL "Enable Cycles CUDA device" FORCE^)
>>"%_GPU_CACHE_FILE%" echo set(WITH_CYCLES_DEVICE_OPTIX ON CACHE BOOL "Enable Cycles OptiX device" FORCE^)
>>"%_GPU_CACHE_FILE%" echo.
>>"%_GPU_CACHE_FILE%" echo # Pre-compile CUDA kernels - also needed for OptiX PTX generation
>>"%_GPU_CACHE_FILE%" echo set(WITH_CYCLES_CUDA_BINARIES ON CACHE BOOL "Build CUDA kernels" FORCE^)
>>"%_GPU_CACHE_FILE%" echo.
>>"%_GPU_CACHE_FILE%" echo # Dynamically load CUDA at runtime - recommended for developers
>>"%_GPU_CACHE_FILE%" echo set(WITH_CUDA_DYNLOAD ON CACHE BOOL "Dynamic CUDA loading" FORCE^)

if not exist "%_GPU_CACHE_FILE%" (
    echo ERROR: Failed to create GPU cache file at "%_GPU_CACHE_FILE%"
    exit /b 1
)

echo Cache file: %_GPU_CACHE_FILE%
echo.

REM =====================================================================
REM Phase 1: Run make.bat to configure + build.
REM
REM Environment variables CUDA_TOOLKIT_ROOT_DIR and OPTIX_ROOT_DIR are
REM inherited by make.bat.  CMake's find_package / FindOptiX modules use
REM these to locate the SDKs.  WITH_CYCLES_DEVICE_CUDA and
REM WITH_CYCLES_DEVICE_OPTIX default to ON in CMakeLists.txt, so the
REM device backends are enabled automatically.
REM
REM HOWEVER, WITH_CYCLES_CUDA_BINARIES defaults to OFF.  It controls
REM pre-compiled CUDA kernels AND OptiX PTX generation.  Since make.bat
REM clears BUILD_CMAKE_ARGS (via reset_variables.cmd), we cannot inject
REM our -C cache file through the normal flow.  Instead we reconfigure
REM after the initial configure completes (Phase 2).
REM =====================================================================
call "%BLENDER_DIR%make.bat" %*
set _MAKE_RESULT=%ERRORLEVEL%

REM =====================================================================
REM Phase 2: Post-configure reconfigure with GPU kernel options.
REM
REM If this is a fresh build (or the GPU options aren't in the cache yet),
REM reconfigure with the GPU cache file and then rebuild so the CUDA
REM .cubin and OptiX .ptx kernels get compiled.
REM =====================================================================
if not "%_MAKE_RESULT%"=="0" (
    del "%_GPU_CACHE_FILE%" 2>NUL
    exit /b %_MAKE_RESULT%
)

REM Determine the build directory by searching for CMakeCache.txt.
set _FOUND_BUILD_DIR=

if exist "%BLENDER_DIR%..\build_windows\CMakeCache.txt" (
    set "_FOUND_BUILD_DIR=%BLENDER_DIR%..\build_windows"
)

if not defined _FOUND_BUILD_DIR (
    for /f "delims=" %%D in (
        'dir /b /ad /o-d "%BLENDER_DIR%..\build_windows*" 2^>NUL'
    ) do (
        if exist "%BLENDER_DIR%..\%%D\CMakeCache.txt" (
            set "_FOUND_BUILD_DIR=%BLENDER_DIR%..\%%D"
        )
    )
)

if not defined _FOUND_BUILD_DIR (
    echo.
    echo WARNING: Could not locate build directory with CMakeCache.txt.
    echo GPU options were not applied. Check the build output above.
    del "%_GPU_CACHE_FILE%" 2>NUL
    exit /b 0
)

REM Check if GPU kernel options are already present in the cache.
set _NEEDS_GPU_RECONFIG=0

findstr /C:"WITH_CYCLES_CUDA_BINARIES:BOOL=ON" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if errorlevel 1 (
    set _NEEDS_GPU_RECONFIG=1
)

findstr /C:"CYCLES_RUNTIME_OPTIX_ROOT_DIR" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if errorlevel 1 (
    set _NEEDS_GPU_RECONFIG=1
)

REM Also reconfigure if the OptiX path changed.
findstr /C:"OPTIX_ROOT_DIR:PATH=%OPTIX_ROOT_DIR%" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if errorlevel 1 (
    set _NEEDS_GPU_RECONFIG=1
)

if "%_NEEDS_GPU_RECONFIG%"=="0" (
    echo.
    echo === GPU kernel options already in cache. Nothing to reconfigure. ===
    echo.
    del "%_GPU_CACHE_FILE%" 2>NUL
    exit /b 0
)

echo.
echo === Reconfiguring with GPU kernel options ===
echo Build directory: %_FOUND_BUILD_DIR%
echo.

cmake -C "%_GPU_CACHE_FILE%" -H"%BLENDER_DIR%." -B"%_FOUND_BUILD_DIR%"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: CMake reconfigure with GPU cache failed.
    del "%_GPU_CACHE_FILE%" 2>NUL
    exit /b 1
)

echo.
echo === GPU options applied. Rebuilding to compile CUDA/OptiX kernels... ===
echo.

REM Detect build type from CMake cache (default Release).
set _BUILD_TYPE=Release
findstr /C:"CMAKE_BUILD_TYPE:STRING=Debug" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if not errorlevel 1 (
    set _BUILD_TYPE=Debug
)
findstr /C:"CMAKE_BUILD_TYPE:STRING=RelWithDebInfo" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if not errorlevel 1 (
    set _BUILD_TYPE=RelWithDebInfo
)
findstr /C:"CMAKE_BUILD_TYPE:STRING=MinSizeRel" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if not errorlevel 1 (
    set _BUILD_TYPE=MinSizeRel
)

REM Detect if using Ninja generator (single-config, --config not needed).
set _IS_NINJA=0
findstr /C:"CMAKE_GENERATOR:INTERNAL=Ninja" "%_FOUND_BUILD_DIR%\CMakeCache.txt" >NUL 2>&1
if not errorlevel 1 (
    set _IS_NINJA=1
)

if "%_IS_NINJA%"=="1" (
    cmake --build "%_FOUND_BUILD_DIR%" --target install
) else (
    cmake --build "%_FOUND_BUILD_DIR%" --config %_BUILD_TYPE% --target INSTALL
)
set _REBUILD_RESULT=%ERRORLEVEL%

if %_REBUILD_RESULT% EQU 0 (
    echo.
    echo === GPU build completed successfully ===
    echo CUDA Toolkit  : %CUDA_TOOLKIT_ROOT_DIR%
    echo OptiX SDK     : %OPTIX_ROOT_DIR%
    echo Build type    : %_BUILD_TYPE%
    echo Build dir     : %_FOUND_BUILD_DIR%
    echo.
) else (
    echo.
    echo ERROR: Rebuild failed with error %_REBUILD_RESULT%.
    echo.
)

del "%_GPU_CACHE_FILE%" 2>NUL
exit /b %_REBUILD_RESULT%
