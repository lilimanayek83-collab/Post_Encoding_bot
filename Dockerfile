FROM python:3.11-slim

# ---- System dependencies ----
# ffmpeg/ffprobe: required for metadata tagging, cover embedding, and ALL torrent encoding.
# aria2: fallback torrent backend (used automatically if libtorrent isn't available).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        aria2 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---- Python dependencies ----
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# libtorrent is the PREFERRED torrent backend (it can read a torrent's metadata and grab only
# the one video file we want, before downloading any content). It's optional at runtime —
# bot.py's torrent_backend() falls back to aria2c automatically if this import fails — so a
# failed/missing wheel here must never break the image build.
RUN pip install --no-cache-dir libtorrent || \
    echo "⚠️  libtorrent wheel unavailable for this platform — the bot will fall back to aria2c at runtime."

# ---- App code ----
COPY . .

# Runtime working directories the bot writes into (also created at startup by bot.py itself,
# but pre-creating them here keeps `docker run` clean on a fresh volume mount too).
RUN mkdir -p downloads temp torrents

# Unbuffered stdout so `docker logs` shows prints (progress bars, startup banner) immediately.
ENV PYTHONUNBUFFERED=1

# Persist the Pyrogram session file (batch_autorename_bot.session) and downloaded/torrent state
# across container restarts if you mount /app as a volume — see docker-compose.yml.
VOLUME ["/app/downloads", "/app/temp", "/app/torrents"]

CMD ["python", "bot.py"]
