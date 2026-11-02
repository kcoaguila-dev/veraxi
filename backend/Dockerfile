FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Copy the backend source
COPY . /app/backend/

# Set Python path so `backend` module can be imported
ENV PYTHONPATH=/app

# Install system dependencies (OpenCV/Docling only when requested via INSTALL_EXTRAS)
ARG INSTALL_EXTRAS=""
RUN apt-get update && \
    if echo "$INSTALL_EXTRAS" | grep -Eq "ocr|full"; then \
        apt-get install -y --no-install-recommends libgl1 libglib2.0-0 libmagic1; \
    else \
        apt-get install -y --no-install-recommends libmagic1; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Install python dependencies statically for production
RUN cd backend && if [ -n "$INSTALL_EXTRAS" ]; then pip install --no-cache-dir ".[${INSTALL_EXTRAS}]"; else pip install --no-cache-dir .; fi
RUN python -m spacy download xx_ent_wiki_sm && python -m spacy download en_core_web_sm
RUN if echo "$INSTALL_EXTRAS" | grep -Eq "browser|full"; then playwright install --with-deps chromium; fi

# Create non-root user for security
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

# Cloud Run ignores EXPOSE, but we keep it for local documentation
EXPOSE 8080

# Start server (Reads $PORT from Cloud Run, defaults to 8000 locally)
CMD ["sh", "-c", "uvicorn backend.api_gateway:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips='*'"]
