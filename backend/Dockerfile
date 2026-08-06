FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Copy the backend source
COPY . /app/backend/

# Set Python path so `backend` module can be imported
ENV PYTHONPATH=/app

# Install system dependencies required for OpenCV/Docling/Python-magic
RUN apt-get update && apt-get install -y libgl1 libglib2.0-0 libmagic1 && rm -rf /var/lib/apt/lists/*

# Install python dependencies statically for production
RUN cd backend && pip install --no-cache-dir .
RUN python -m spacy download en_core_web_sm

# Create non-root user for security
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

# Expose port
EXPOSE 8000

# Start server
CMD ["uvicorn", "backend.api_gateway:app", "--host", "0.0.0.0", "--port", "8000"]
