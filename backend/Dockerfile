FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Copy the backend source
COPY . /app/backend/

# Set Python path so `backend` module can be imported
ENV PYTHONPATH=/app

# Install dependencies
RUN cd backend && pip install --no-cache-dir -e .

# Expose port
EXPOSE 8000

# Start server
CMD ["uvicorn", "backend.api_gateway:app", "--host", "0.0.0.0", "--port", "8000"]
