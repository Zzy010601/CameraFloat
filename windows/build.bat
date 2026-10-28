@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    python -m venv .venv || goto :error
    ".venv\Scripts\python.exe" -m pip install --upgrade pip -q
)

echo ==^> 安装依赖
".venv\Scripts\python.exe" -m pip install -r requirements.txt -q || goto :error
".venv\Scripts\python.exe" -m pip install pyinstaller -q || goto :error

echo ==^> 打包为单个 exe
".venv\Scripts\pyinstaller.exe" ^
    --noconfirm --clean ^
    --windowed ^
    --name CameraFloat ^
    --collect-all PySide6 ^
    camera_float.py || goto :error

echo.
echo ==^> 完成：%~dp0dist\CameraFloat\CameraFloat.exe
echo     整个 dist\CameraFloat 文件夹即为免安装绿色版，可整体拷贝分发。
pause
exit /b 0

:error
echo.
echo [错误] 打包失败，检查上方日志。
pause
exit /b 1
