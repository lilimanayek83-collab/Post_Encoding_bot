# Batch Auto-Rename & Posting Bot

A Telegram bot (built on [Pyrogram](https://docs.pyrogram.org/)) that automatically renames,
tags, and posts anime/video files to your channels — and can also pull a video straight out of
a **torrent/magnet link**, encode it into a multi-quality ladder (1080p → 720p → 480p by
default), and post the whole set, with zero manual work per episode.

---

## Table of Contents

- [What the bot can do](#what-the-bot-can-do)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Setting up `.env`](#setting-up-env)
- [Running the bot](#running-the-bot)
- [Bot commands](#bot-commands)
- [Menus & buttons](#menus--buttons)
- [Batches — the core concept](#batches--the-core-concept)
- [Torrent pipeline](#torrent-pipeline-in-detail)
- [Access control](#access-control)
- [Troubleshooting](#troubleshooting)

---

## What the bot can do

**1. Auto-rename & post files sent directly to it**
Send it a video/document/audio file. It detects **Season**, **Episode**, and **Quality** from
the filename, matches it to a **batch** (an anime/show profile you configure once), renames it,
tags metadata, embeds a cover image, and posts it to your channels — automatically.

**2. Torrent → multi-quality encode pipeline**
Send a magnet link or a `.torrent` file. The bot will:
- download only the actual video file out of the torrent (skips samples/trailers/NCOP-NCED),
- encode it to **1080p**, rename + tag + embed cover, upload to the Backup Channel,
- delete the original download, encode **720p from the 1080p**, upload, delete the 1080p,
- encode **480p from the 720p**, upload, delete everything — nothing stays on the server,
- copy the finished set into the Sub Channel (low → high quality order) and post to the
  Main Channel(s), exactly like a normal file.

**3. Sequence mode**
Collect a batch of files, choose a sort order (Season→Quality→Episode, etc.), preview the
order, then queue them all at once — useful for posting an entire season in the right order.

**4. Auto Post Mode**
Skip filename-matching entirely and route every file you send to one chosen batch until you
turn it off. Required for torrent jobs, since a magnet link has no filename to match against.

**5. Multi-channel posting**
Each batch can post to one **Sub Channel** (the "real" home for its files) and any number of
**Main Channel(s)** (hub channels that get a Top Post + a download button linking to the Sub
Channel). A bot-wide **Backup Channel** mirrors everything for redundancy.

---

## Architecture

```
Telegram ──▶ Pyrogram handlers ──▶ asyncio.Queue (file_queue) ──▶ queue_worker()
                  │                                                    │
                  │                                          process_job(job)
                  │                                             ├── normal file job
                  │                                             └── torrent job
                  │                                                    │
             MongoDB (motor) ◀───────────────────────────────── batches / channels / settings
                  │
            downloads/ temp/ torrents/  (scratch disk, swept clean on every job/startup)
```

- **Single global FIFO queue** — jobs run **one at a time, in order**. A "job" is either one
  file, a whole sorted sequence, or a torrent job (download → encode ladder → post).
- **MongoDB** (via `motor`, the async driver) stores three collections: `batches`, `channels`
  (the registry of channels the bot knows about), and a single `settings` doc (`_id: "global"`)
  holding the Backup Channel, Thumb/Cover Channel, and encode settings.
- **ffmpeg/ffprobe** do all metadata tagging, cover embedding, and torrent encoding.
- **libtorrent** (preferred) or **aria2c** (fallback) handle torrent downloads — whichever is
  installed is auto-detected at startup (`torrent_backend()`).
- **In-memory state** (lost on restart): `conversation_state` (multi-step menu inputs),
  `sequence_sessions`, `auto_post_sessions`, `active_jobs` (for cancellation).

---

## Requirements

| Component | Why |
|---|---|
| Python 3.10+ | runtime |
| MongoDB | stores batches/channels/settings |
| ffmpeg + ffprobe | metadata tagging, cover embedding, torrent encoding |
| libtorrent **or** aria2c | torrent downloads (libtorrent preferred) |
| A Telegram bot token + API ID/Hash | from [my.telegram.org](https://my.telegram.org) and [@BotFather](https://t.me/BotFather) |

If you're using Docker, the provided `Dockerfile` installs ffmpeg, aria2, and (best-effort)
libtorrent for you — see [Running the bot](#running-the-bot).

---

## Setting up `.env`

Copy `.env.example` to `.env` and fill in real values:

```env
# ---- Telegram ----
API_ID=1234567
API_HASH=your_api_hash_here
BOT_TOKEN=123456789:your_bot_token_here

# Numeric Telegram user IDs, comma or space separated.
# ADMIN can change bot-wide settings (/bot_settings, /encode_settings).
# MODERATOR can do everything else (batches, channels, sequencing).
ADMIN=123456789
MODERATOR=

# ---- Database ----
DB_URL=mongodb://mongo:27017      # or your Atlas/remote connection string
DB_NAME=BatchAutoRenameBot

# ---- Optional tuning (defaults shown) ----
MAX_TORRENT_SIZE_GB=20            # refuses torrents bigger than this
DISK_HEADROOM_FACTOR=2.5          # free-disk-space multiplier required before a torrent starts
TORRENT_METADATA_TIMEOUT=300      # seconds to wait for a magnet's metadata before giving up
TORRENT_STALL_TIMEOUT=1800        # seconds of 0 bytes progress before aborting a download
ENCODE_TIMEOUT=43200              # seconds allowed per encode rung (12h default)
```

**Where to get these:**
- `API_ID` / `API_HASH` — [my.telegram.org](https://my.telegram.org) → API Development Tools.
- `BOT_TOKEN` — message [@BotFather](https://t.me/BotFather) → `/newbot`.
- Your numeric user ID for `ADMIN` — message [@userinfobot](https://t.me/userinfobot).

⚠️ If `ADMIN`/`MODERATOR` are both empty, **the bot will start but reply to no one** — it logs
a loud warning to the console on startup telling you exactly what to fix.

---

## Running the bot

### With Docker (recommended)

```bash
cp .env.example .env      # fill in real values first
docker compose up -d --build
docker compose logs -f bot
```

This starts a local MongoDB container alongside the bot automatically. See the Dockerfile /
docker-compose.yml provided alongside this README.

### Without Docker

```bash
pip install -r requirements.txt
# also install system packages: ffmpeg, and either aria2 or libtorrent
python bot.py
```

Make sure `mongod` is running and `DB_URL` in `.env` points at it (e.g.
`mongodb://localhost:27017`).

### First-time checklist after starting the bot

1. DM the bot `/start` — confirms it's responding to you (you must be in `ADMIN`/`MODERATOR`).
2. Run `/torrent_check` — confirms ffmpeg/ffprobe/torrent backend are all detected correctly.
3. Post `/register` **inside** each channel you want to use (bot must already be admin there).
4. Run `/bot_settings` (admin only) — set the **Backup Channel** and **Thumb/Cover Channel**.
   Nothing else works until both are set.
5. Run `/new_batch` — create your first anime/show profile and configure it.

---

## Bot commands

| Command | Who | What it does |
|---|---|---|
| `/start`, `/help` | staff | Full in-bot usage guide |
| `/new_batch` | staff | Create a new batch (anime/show profile) |
| `/edit_batch` | staff | Edit or delete an existing batch |
| `/ssequence` | staff | Start collecting files for a sorted sequence |
| `/esequence` | staff | Finish collecting, choose sort order, review, queue |
| `/sequence_mode [1\|2\|3]` | staff | View/set your default sort mode |
| `/auto_post` | staff | Pick a batch to route every file to, no name-matching |
| `/stop_auto_post` | staff | Turn Auto Post Mode off |
| `/cancel` | staff | Abort whatever multi-step input the bot is currently waiting on |
| `/cancel_job [job_id]` | staff | Abort a running torrent/encode job (or all of your running jobs) |
| `/torrent_check` | staff | Shows what's installed: libtorrent/aria2c/ffmpeg/ffprobe, disk space, CPU cores, hardware encoder |
| `/encode_settings` | **admin** | Configure the torrent quality ladder, CRF, preset, codec, audio, container, size targets |
| `/bot_settings` | **admin** | Set the bot-wide Backup Channel and Thumb/Cover Channel |
| `/delete_channel` | staff | Remove a registered channel (auto-unlinks it everywhere it was used) |
| `/register` | — | Post **inside a channel** (as its admin) to register that channel with the bot |
| `/unregister` | — | Post **inside a channel** to remove its registration |

---

## Menus & buttons

Everything after `/new_batch`, `/edit_batch`, `/bot_settings`, and `/encode_settings` is driven
by inline keyboards rather than typed commands:

**Batch editor** (`/edit_batch` → pick a batch → ✏️ Edit) exposes:

| Button | Sets |
|---|---|
| 🖼️ Thumbnail | small in-chat preview image (Telegram compresses this) |
| 🎨 Cover Image | full-quality video poster + embedded cover art in the file itself |
| 🏷️ Metadata | title/author/artist/audio/subtitle/video tags written into every file |
| ✏️ Autorename Format | filename template — `{filename} {season} {episode} {quality} {filesize} {duration}` |
| 💬 Autocaption Format | caption template (same variables; `<text>` renders **bold**) |
| 🎞️ Mediatype | send files as document / video / audio |
| 🔤 Anime Names | one or more names — a file matches if ANY appears in its filename |
| 🔝 Top Post Format | posted with the batch thumbnail before the files — `{batch} {pseason} {pepisode} {pquality}` |
| 🔻 Bottom Post Format | any message (sticker/text/photo/video) copied exactly, after the files |
| 📢 Sub Channel | the batch's primary destination channel |
| 🏠 Main Channel(s) | multi-select — hub channel(s) that get a Top Post + 🍁DOWNLOAD🍁 button |
| 🔗 Set Custom Link | overrides the auto-generated Sub Channel invite link on that button |

**Bot Settings** (`/bot_settings`, admin only):
- 🗄️ Backup Channel — mirrors everything the Sub Channel gets; **mandatory** for any posting.
- 🖼️ Thumb/Cover Channel — where Thumbnail/Cover Image photos are stored for later reuse.
- 🎬 Encode Settings — opens the ladder/codec/CRF/preset/tune/size-target/audio/container menu.

**Encode Settings** (`/encode_settings`, admin only) — toggle rungs (144p…4K), cycle codec
(x264/x265/hw), CRF, preset, tune, per-rung MB size targets, audio mode, container, subtitle
handling, and skip-upscaling.

**Sequence mode** — after `/esequence`, tap a sort mode button, review the generated order,
then 🚀 Add to Queue or ❌ Cancel.

**Running jobs** — every torrent/encode job's live progress message carries a 🛑 **Cancel this
job** button.

---

## Batches — the core concept

A **batch** is a saved profile for one anime/show. Once configured, sending a matching file (or
running it through Auto Post Mode / a torrent job) needs zero further input. Each batch stores:

- Thumbnail & Cover Image (as references into your Thumb/Cover Channel, so they can be
  re-fetched at full quality any time)
- Metadata template (title/author/artist/audio/subtitle/video tags)
- Autorename & Autocaption formats
- Output media type (document/video/audio)
- One or more **Anime Names** for filename matching
- Sub Channel + any number of Main Channel(s)
- Top Post & Bottom Post templates
- An optional custom download-button link

**Season/Episode/Quality detection** always runs in that order — Season, then Episode, then
Quality — and stops at the **first missing one**, telling you exactly which field couldn't be
read from the filename, instead of guessing or silently skipping the file.

---

## Torrent pipeline (in detail)

1. Auto Post Mode must be on (a magnet has no filename to match a batch by).
2. Send a magnet link or `.torrent` file. Include `S02E07` in the same message if the release
   name doesn't already contain a detectable Season/Episode.
3. The bot fetches only the torrent's **metadata** first (no content) to validate size limits
   and Season/Episode — so a bad magnet is rejected before wasting any bandwidth.
4. It downloads **only the actual episode file** (ignores samples/trailers/creditless
   openings/endings by filename heuristics + picks the largest real video file).
5. Encodes high → low (e.g. 1080p → 720p → 480p), each rung **from the previous rung's
   output** — far faster than re-encoding the huge source three times.
6. Each rung is uploaded to the **Backup Channel** immediately, then its source file is
   deleted — so at most two files (current + previous) ever sit on disk at once.
7. Once all rungs are done, the whole set is copied into the **Sub Channel** in **ascending**
   quality order, and the **Main Channel(s)** get their usual Top Post + download button.
8. Every temporary file is swept from disk — nothing lingers on the server.

Per-rung file size is **enforced**, not just hoped for: each rung gets a computed
`-maxrate`/`-bufsize` cap from its configured MB target, and automatically re-encodes at a
higher CRF (up to 2 retries) if it still overshoots.

---

## Access control

- `Config.STAFF` = `ADMIN` ∪ `MODERATOR`. Anyone **not** in this list gets **zero reply** from
  the bot at all (by design) — their first message is logged once to the console so you can
  copy their ID into `ADMIN` if it's actually you.
- `ADMIN` additionally unlocks `/bot_settings` and `/encode_settings` (bot-wide config).
  `MODERATOR` can do everything else.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Bot connects but never replies to anyone | `ADMIN`/`MODERATOR` empty in `.env` — check console startup log |
| "No Backup Channel set" | Run `/bot_settings` (admin) and set one — required before *any* channel posting |
| Torrent jobs refuse to start | Run `/torrent_check` — you're likely missing ffmpeg or a torrent backend |
| Files never queue, "Season/Episode/Quality not found" | Rename the source file so it includes a detectable `SxxExx` and a quality tag (e.g. `1080p`) |
| "Can't identify this file" | No batch's Anime Names matched the filename — check `/edit_batch` → 🔤 Anime Names, or use `/auto_post` instead |
| Cover image doesn't show as the native video poster | Your installed Pyrogram build may not support the `cover=` parameter yet (stock Pyrogram doesn't; forks like Pyrofork do) — it's still embedded into the file itself via ffmpeg either way |
| `CHANNEL_INVALID` on a private channel after a restart | Make sure the bot keeps its session file (`batch_autorename_bot.session`) across restarts — mount it as a volume if using Docker |
