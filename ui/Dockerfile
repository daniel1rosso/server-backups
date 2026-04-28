FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    util-linux \
    openssh-client \
    sqlite3 \
    rsync \
    curl \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY ui/requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY ui /app/ui

EXPOSE 8080

CMD ["gunicorn", "-w", "1", "--threads", "8", "-b", "0.0.0.0:8080", "ui.app:app"]
