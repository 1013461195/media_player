@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Build a debug APK and install it on every authorised ADB device.
rem Required environment variables:
rem   FLUTTER_HOME (or FLUTTER_ROOT), ANDROID_HOME (or ANDROID_SDK_ROOT),
rem   ANDROID_NDK_HOME (or ANDROID_NDK_ROOT), and JAVA_HOME (or ANDROID_JDK_HOME).
set "PROJECT_DIR=%~dp0"
set "ANDROID_DIR=%PROJECT_DIR%android"
set "APK_PATH=%ANDROID_DIR%\app\build\outputs\apk\debug\app-debug.apk"
set "LOCAL_PROPERTIES=%ANDROID_DIR%\local.properties"

set "FLUTTER_SDK=%FLUTTER_HOME%"
if not defined FLUTTER_SDK set "FLUTTER_SDK=%FLUTTER_ROOT%"
if not defined FLUTTER_SDK (
    echo 错误：请设置 FLUTTER_HOME（或 FLUTTER_ROOT）为 Flutter SDK 根目录。
    exit /b 1
)
if not exist "%FLUTTER_SDK%\bin\flutter.bat" (
    echo 错误：FLUTTER_HOME 必须指向 Flutter SDK 根目录（未找到 bin\flutter.bat）。
    exit /b 1
)

set "ANDROID_SDK_DIR=%ANDROID_HOME%"
if not defined ANDROID_SDK_DIR set "ANDROID_SDK_DIR=%ANDROID_SDK_ROOT%"
if not defined ANDROID_SDK_DIR (
    echo 错误：请设置 ANDROID_HOME（或 ANDROID_SDK_ROOT）为 Android SDK 根目录。
    exit /b 1
)
if not exist "%ANDROID_SDK_DIR%\platform-tools\adb.exe" (
    echo 错误：未找到 adb：%ANDROID_SDK_DIR%\platform-tools\adb.exe
    exit /b 1
)

set "ANDROID_NDK_DIR=%ANDROID_NDK_HOME%"
if not defined ANDROID_NDK_DIR set "ANDROID_NDK_DIR=%ANDROID_NDK_ROOT%"
if not defined ANDROID_NDK_DIR (
    echo 错误：请设置 ANDROID_NDK_HOME（或 ANDROID_NDK_ROOT）为 NDK 版本目录。
    exit /b 1
)
if not exist "%ANDROID_NDK_DIR%\source.properties" (
    echo 错误：ANDROID_NDK_HOME 必须指向 NDK 版本目录（未找到 source.properties）。
    exit /b 1
)
set "NDK_VERSION="
for /f "tokens=2 delims==" %%V in ('findstr /b /c:"Pkg.Revision" "%ANDROID_NDK_DIR%\source.properties"') do for /f "tokens=*" %%W in ("%%V") do set "NDK_VERSION=%%W"
if not defined NDK_VERSION (
    echo 错误：无法读取 Android NDK 版本：%ANDROID_NDK_DIR%\source.properties
    exit /b 1
)
if not exist "%ANDROID_SDK_DIR%\ndk\%NDK_VERSION%\source.properties" (
    echo 错误：Android SDK 中未安装 NDK %NDK_VERSION%。请将 ANDROID_NDK_HOME 指向 %ANDROID_SDK_DIR%\ndk\^<版本^>。
    exit /b 1
)

set "BUILD_JDK_HOME=%ANDROID_JDK_HOME%"
if not defined BUILD_JDK_HOME set "BUILD_JDK_HOME=%JAVA_HOME%"
if not defined BUILD_JDK_HOME (
    echo 错误：请设置 ANDROID_JDK_HOME（或 JAVA_HOME）为 JDK 17 根目录。
    exit /b 1
)
if not exist "%BUILD_JDK_HOME%\bin\java.exe" (
    echo 错误：JAVA_HOME 必须指向 JDK 17 根目录（未找到 bin\java.exe）。
    exit /b 1
)

set "JDK_VERSION="
for /f "tokens=3" %%V in ('"%BUILD_JDK_HOME%\bin\java.exe" -version 2^>^&1 ^| findstr /i /c:"version"') do set "JDK_VERSION=%%~V"
set "JDK_VERSION=%JDK_VERSION:"=%"
for /f "tokens=1 delims=." %%V in ("%JDK_VERSION%") do set "JDK_MAJOR_VERSION=%%V"
if not "%JDK_MAJOR_VERSION%"=="17" (
    echo 错误：当前 JDK 为 %JDK_MAJOR_VERSION%；此项目需要 JDK 17。
    exit /b 1
)

if not exist "%ANDROID_DIR%\gradlew.bat" (
    echo 错误：未找到 Gradle Wrapper：%ANDROID_DIR%\gradlew.bat
    exit /b 1
)

set "JAVA_HOME=%BUILD_JDK_HOME%"
set "ANDROID_HOME=%ANDROID_SDK_DIR%"
set "ANDROID_SDK_ROOT=%ANDROID_SDK_DIR%"
set "ANDROID_NDK_HOME=%ANDROID_NDK_DIR%"
set "ANDROID_NDK_ROOT=%ANDROID_NDK_DIR%"
set "PATH=%FLUTTER_SDK%\bin;%JAVA_HOME%\bin;%ANDROID_SDK_DIR%\platform-tools;%PATH%"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$path=$env:LOCAL_PROPERTIES; $existing=if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path | Where-Object { $_ -notmatch '^(sdk\.dir|flutter\.sdk|ndk\.dir)=' }}else{@()}; @($existing; 'sdk.dir=' + $env:ANDROID_SDK_DIR; 'flutter.sdk=' + $env:FLUTTER_SDK) | Set-Content -LiteralPath $path -Encoding ascii"
if errorlevel 1 exit /b %errorlevel%

echo 正在获取 Flutter 依赖...
call flutter pub get
if errorlevel 1 exit /b %errorlevel%

echo 正在打包 Debug APK...
set "BUILD_RETRIES=%GRADLE_BUILD_RETRIES%"
if not defined BUILD_RETRIES set "BUILD_RETRIES=3"
for /l %%A in (1,1,%BUILD_RETRIES%) do (
    if %%A EQU 1 (
        call "%ANDROID_DIR%\gradlew.bat" assembleDebug
    ) else (
        echo Gradle 构建失败，正在重试（%%A/%BUILD_RETRIES%）...
        call "%ANDROID_DIR%\gradlew.bat" --refresh-dependencies assembleDebug
    )
    if not errorlevel 1 goto :gradle_build_succeeded
    set "GRADLE_EXIT_CODE=!errorlevel!"
    if %%A LSS %BUILD_RETRIES% timeout /t %%A /nobreak >nul
)
exit /b %GRADLE_EXIT_CODE%

:gradle_build_succeeded

if not exist "%APK_PATH%" (
    echo 错误：未找到生成的 APK：%APK_PATH%
    exit /b 1
)

set "HAS_DEVICE="
for /f "tokens=1,2" %%A in ('"%ANDROID_SDK_DIR%\platform-tools\adb.exe" devices ^| findstr /r /c:"^[^ ][^ ]*	device$"') do (
    set "HAS_DEVICE=1"
    echo 正在安装到设备：%%A
    "%ANDROID_SDK_DIR%\platform-tools\adb.exe" -s "%%A" install -r "%APK_PATH%"
    if errorlevel 1 exit /b !errorlevel!
)

if not defined HAS_DEVICE (
    echo APK 已生成：%APK_PATH%
    echo 未检测到已授权的 ADB 设备，跳过安装。
    exit /b 0
)

echo APK 已生成并安装完成：%APK_PATH%
exit /b 0
