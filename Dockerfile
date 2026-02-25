FROM python:3.12-slim

WORKDIR /app

COPY dummy_server.py .

RUN pip install --no-cache-dir "fastapi" "uvicorn[standard]"

EXPOSE 8000

CMD ["uvicorn", "dummy_server:app", "--host", "0.0.0.0", "--port", "8000"]
