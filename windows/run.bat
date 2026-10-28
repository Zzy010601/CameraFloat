@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo ==^> 首次运行，创建虚拟环境...
    python -m venv .venv || goto :error
    ".venv\Scripts\python.exe" -m pip install --upgrade pip -q
    ".venv\Scripts\python.exe" -m pip install -r requirements.txt || goto :error
)

echo ==^> 启动摄像头悬浮窗
start "" ".venv\Scripts\pythonw.exe" camera_float.py
exit /b 0

:error
echo.
echo [错误] 初始化失败，请确认已安装 Python 3.9+ 并加入 PATH。
pause
exit /b 1
