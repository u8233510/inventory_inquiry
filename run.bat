@echo off
setlocal

if not exist .venv (
    py -3 -m venv .venv
)

call .venv\Scripts\activate

python -m pip install --upgrade pip
pip install -r requirements.txt

if not exist .env (
    copy .env.example .env
    echo.
    echo 已建立 .env，請先填入 DB_USERNAME 與 DB_PASSWORD 後再執行。
    pause
    exit /b 1
)

python -m uvicorn app:app --host 0.0.0.0 --port 8040

endlocal
