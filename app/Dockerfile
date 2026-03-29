FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

RUN useradd --system --create-home --uid 10001 appuser \
  && chown -R appuser:appuser /app

USER appuser

EXPOSE 5000

# Production entrypoint (factory app syntax compatible with older gunicorn)
CMD ["gunicorn", "--workers", "2", "--threads", "4", "--bind", "0.0.0.0:5000", "--access-logfile", "-", "--error-logfile", "-", "app:create_app()"]
