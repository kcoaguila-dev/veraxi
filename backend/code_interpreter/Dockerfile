FROM python:3.12-alpine

WORKDIR /app

# Ensure we run as a non-root user for added safety
RUN adduser -D sandboxuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER sandboxuser

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
