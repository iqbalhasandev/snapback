#!/bin/bash
# =============================================================================
# Snapback - Database & Files Backup Tool (rclone + password-protected zip)
# https://github.com/iqbalhasandev/snapback
# Usage: curl -sL https://raw.githubusercontent.com/iqbalhasandev/snapback/main/install.sh | bash
# =============================================================================

set -e

VERSION="1.0.0"
GITHUB_REPO="iqbalhasandev/snapback"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/snapback"
LOG_DIR="/var/log"
BACKUP_CMD="snapback"

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║           Snapback v${VERSION} - Backup Tool Installer              ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Note: Running without root. Will install to ~/bin${NC}"
    INSTALL_DIR="$HOME/bin"
    CONFIG_DIR="$HOME/.snapback"
    LOG_DIR="$HOME/.snapback/logs"
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"

echo -e "${GREEN}[1/4]${NC} Installing backup script..."

# Create main backup script
cat > "$INSTALL_DIR/$BACKUP_CMD" << 'MAINSCRIPT'
#!/bin/bash
# Snapback v1.0.0 - Database & Files Backup Tool
set -eo pipefail

VERSION="1.0.0"
GITHUB_REPO="iqbalhasandev/snapback"
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_REPO"
LOCKFILE="/tmp/snapback.lock"

# Config detection
if [[ -f "/etc/snapback/config.conf" ]]; then
    CONFIG_FILE="/etc/snapback/config.conf"
    LOG_FILE="/var/log/snapback.log"
elif [[ -f "$HOME/.snapback/config.conf" ]]; then
    CONFIG_FILE="$HOME/.snapback/config.conf"
    LOG_FILE="$HOME/.snapback/logs/backup.log"
else
    echo "Error: Config not found. Run: $0 init"; exit 1
fi

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

log() { local m="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "${GREEN}$m${NC}"; echo "$m" >> "$LOG_FILE" 2>/dev/null || true; }
error() { local m="$1"; echo "${RED}[ERROR] $m${NC}" >&2; echo "[ERROR] $m" >> "$LOG_FILE" 2>/dev/null || true; send_webhook "failure" "$m"; exit 1; }
warn() { echo "${YELLOW}[WARN] $1${NC}"; }

# Lock file to prevent concurrent runs
acquire_lock() {
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        echo "${RED}Another backup is already running${NC}" >&2
        exit 1
    fi
}

# Webhook notification
send_webhook() {
    local status="$1" message="$2"
    [[ -z "$WEBHOOK_URL" ]] && return 0
    
    local payload hostname timestamp
    hostname=$(hostname)
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Detect webhook type and format payload
    if [[ "$WEBHOOK_URL" == *"slack.com"* ]]; then
        payload=$(jq -n --arg text "[$status] Snapback on $hostname: $message ($timestamp)" '{text: $text}')
    elif [[ "$WEBHOOK_URL" == *"discord.com"* ]]; then
        payload=$(jq -n --arg content "[$status] Snapback on $hostname: $message ($timestamp)" '{content: $content}')
    else
        # Generic webhook (works with most services)
        payload=$(jq -n \
            --arg status "$status" \
            --arg message "$message" \
            --arg hostname "$hostname" \
            --arg timestamp "$timestamp" \
            --arg tool "snapback" \
            '{status: $status, message: $message, hostname: $hostname, timestamp: $timestamp, tool: $tool}')
    fi
    
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

load_config() {
    source "$CONFIG_FILE"
    REMOTE_PATH="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PATH_PREFIX}"
}

check_deps() {
    local m=()
    command -v rclone &>/dev/null || m+=("rclone")
    command -v zip &>/dev/null || m+=("zip")
    command -v jq &>/dev/null || m+=("jq")
    case "$DB_DRIVER" in
        mysql|mariadb) command -v mysqldump &>/dev/null || m+=("mysql-client (apt) or mysql (brew)") ;;
        postgresql|postgres) command -v pg_dump &>/dev/null || m+=("postgresql-client (apt) or postgresql (brew)") ;;
    esac
    [[ ${#m[@]} -gt 0 ]] && error "Missing: ${m[*]}"
}

# Create password-protected zip
create_zip() {
    local src="$1" dest="$2"
    if [[ -n "$ZIP_PASSWORD" ]]; then
        zip -q -j -P "$ZIP_PASSWORD" "$dest" "$src"
    else
        zip -q -j "$dest" "$src"
    fi
}

# MySQL dump (secure - password not visible in process list)
backup_mysql() {
    local db="$1" out="$2"
    log "Dumping MySQL: $db"
    mysqldump \
        --defaults-extra-file=<(printf "[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n" "$DB_HOST" "${DB_PORT:-3306}" "$DB_USER" "$DB_PASSWORD") \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --set-gtid-purged=OFF \
        --no-tablespaces \
        "$db" > "$out" 2>/dev/null
}

# PostgreSQL dump
backup_postgres() {
    local db="$1" out="$2"
    log "Dumping PostgreSQL: $db"
    PGPASSWORD="$DB_PASSWORD" pg_dump \
        --host="$DB_HOST" \
        --port="${DB_PORT:-5432}" \
        --username="$DB_USER" \
        --no-password \
        --format=plain \
        "$db" > "$out" 2>/dev/null
}

# Upload via rclone with verification
upload() {
    local file="$1"
    local fname=$(basename "$file")
    local dest="$REMOTE_PATH/$fname"
    log "Uploading: $dest"
    rclone copy "$file" "$REMOTE_PATH/" --progress=false -q
    
    # Verify upload integrity
    if [[ "${VERIFY_UPLOAD:-true}" == "true" ]]; then
        log "Verifying upload integrity..."
        local local_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
        local remote_size=$(rclone size "$REMOTE_PATH/$fname" --json 2>/dev/null | jq -r '.bytes // 0')
        if [[ "$local_size" != "$remote_size" ]]; then
            error "Upload verification failed: size mismatch (local: $local_size, remote: $remote_size)"
        fi
        log "✓ Verified: $fname ($local_size bytes)"
    else
        log "✓ Upload complete: $fname"
    fi
}

# Database backup
do_backup_db() {
    load_config; check_deps
    local ts=$(date '+%Y-%m-%d_%H%M%S')
    local tmp=$(mktemp -d)
    trap "rm -rf $tmp" EXIT

    local dbs=()
    [[ -n "$DB_MULTIPLE" ]] && IFS=',' read -ra dbs <<< "$DB_MULTIPLE" || dbs=("$DB_NAME")

    for db in "${dbs[@]}"; do
        db=$(echo "$db" | xargs)
        local sql="$tmp/${db}.sql"
        local zipf="$tmp/${BACKUP_PREFIX:-backup}_${db}_${ts}.zip"

        case "$DB_DRIVER" in
            mysql|mariadb) backup_mysql "$db" "$sql" ;;
            postgresql|postgres) backup_postgres "$db" "$sql" ;;
            *) error "Unsupported: $DB_DRIVER" ;;
        esac

        log "Compressing with password protection..."
        create_zip "$sql" "$zipf"
        rm -f "$sql"

        local sz=$(du -h "$zipf" | cut -f1)
        log "Size: $sz (encrypted)"
        upload "$zipf"
    done
    log "✓ Database backup done!"
}

# Files backup
do_backup_files() {
    load_config; check_deps
    local ts=$(date '+%Y-%m-%d_%H%M%S')
    local tmp=$(mktemp -d)
    trap "rm -rf $tmp" EXIT

    local tarf="$tmp/files_${ts}.tar"
    local zipf="$tmp/${BACKUP_PREFIX:-backup}_files_${ts}.zip"

    local excludes=()
    for ex in "${FILES_EXCLUDE[@]}"; do excludes+=("--exclude=$ex"); done

    log "Archiving files..."
    tar -cf "$tarf" "${excludes[@]}" "${FILES_INCLUDE[@]}" 2>/dev/null || true

    log "Compressing with password protection..."
    create_zip "$tarf" "$zipf"
    rm -f "$tarf"

    local sz=$(du -h "$zipf" | cut -f1)
    log "Size: $sz (encrypted)"
    upload "$zipf"
    log "✓ Files backup done!"
}

# Full backup + cleanup
do_backup_all() {
    acquire_lock
    log "═══════════════════════════════════════"
    log "Starting Snapback v$VERSION..."
    local start_time=$(date +%s)
    
    [[ "$BACKUP_DATABASE" != "false" ]] && do_backup_db
    [[ "$BACKUP_FILES" == "true" ]] && do_backup_files
    do_cleanup
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log "═══════════════════════════════════════"
    log "✓ All backups completed in ${duration}s!"
    send_webhook "success" "Backup completed in ${duration}s"
}

# List backups
do_list() {
    load_config
    echo "${BLUE}Backups in: $REMOTE_PATH${NC}"
    echo "─────────────────────────────────────────────────────"
    rclone ls "$REMOTE_PATH/" 2>/dev/null | while read -r sz name; do
        local szh=$(numfmt --to=iec $sz 2>/dev/null || echo "${sz}B")
        printf "  %8s  %s\n" "$szh" "$name"
    done
    echo "─────────────────────────────────────────────────────"
}

# Retention cleanup
do_cleanup() {
    load_config
    log "Applying retention policy..."

    local now_ts=$(date +%s)
    local deleted=0
    local kept_daily=() kept_weekly=() kept_monthly=() kept_yearly=()

    # Get all backups sorted by date (newest first)
    local backups=$(rclone lsjson "$REMOTE_PATH/" 2>/dev/null | \
        jq -r '.[] | select(.IsDir==false) | "\(.ModTime)\t\(.Name)\t\(.Size)"' | sort -r)

    while IFS=$'\t' read -r modtime name size; do
        [[ -z "$name" ]] && continue

        # Parse date from filename: backup_dbname_2024-01-15_120000.zip
        local file_date=$(echo "$name" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
        [[ -z "$file_date" ]] && continue

        # Calculate age
        local file_ts=$(date -j -f "%Y-%m-%d" "$file_date" "+%s" 2>/dev/null || \
                        date -d "$file_date" "+%s" 2>/dev/null || echo 0)
        [[ "$file_ts" == "0" ]] && continue
        local age=$(( (now_ts - file_ts) / 86400 ))

        local keep=false
        local reason=""

        # Rule 1: Keep ALL backups within retention period
        if [[ $age -le ${KEEP_ALL_BACKUPS_FOR_DAYS:-7} ]]; then
            keep=true; reason="recent"
        fi

        # Rule 2: Keep DAILY (one per day) within retention
        if [[ $age -le ${KEEP_DAILY_BACKUPS_FOR_DAYS:-16} ]]; then
            if [[ ! " ${kept_daily[*]} " =~ " $file_date " ]]; then
                kept_daily+=("$file_date")
                keep=true; reason="daily"
            fi
        fi

        # Rule 3: Keep WEEKLY (Monday) within retention
        local dow=$(date -j -f "%Y-%m-%d" "$file_date" "+%u" 2>/dev/null || \
                    date -d "$file_date" "+%u" 2>/dev/null || echo 0)
        local week_key=$(date -j -f "%Y-%m-%d" "$file_date" "+%Y-%W" 2>/dev/null || \
                         date -d "$file_date" "+%Y-%W" 2>/dev/null || echo "")
        if [[ "$dow" == "1" && $age -le $((${KEEP_WEEKLY_BACKUPS_FOR_WEEKS:-8} * 7)) ]]; then
            if [[ ! " ${kept_weekly[*]} " =~ " $week_key " ]]; then
                kept_weekly+=("$week_key")
                keep=true; reason="weekly"
            fi
        fi

        # Rule 4: Keep MONTHLY (1st of month) within retention
        local day=$(echo "$file_date" | cut -d'-' -f3)
        local month_key=$(echo "$file_date" | cut -d'-' -f1,2)
        if [[ "$day" == "01" && $age -le $((${KEEP_MONTHLY_BACKUPS_FOR_MONTHS:-4} * 30)) ]]; then
            if [[ ! " ${kept_monthly[*]} " =~ " $month_key " ]]; then
                kept_monthly+=("$month_key")
                keep=true; reason="monthly"
            fi
        fi

        # Rule 5: Keep YEARLY (Jan 1) within retention
        local md=$(echo "$file_date" | cut -d'-' -f2,3)
        local year_key=$(echo "$file_date" | cut -d'-' -f1)
        if [[ "$md" == "01-01" && $age -le $((${KEEP_YEARLY_BACKUPS_FOR_YEARS:-2} * 365)) ]]; then
            if [[ ! " ${kept_yearly[*]} " =~ " $year_key " ]]; then
                kept_yearly+=("$year_key")
                keep=true; reason="yearly"
            fi
        fi

        if [[ "$keep" == "false" ]]; then
            log "Deleting: $name (${age}d old)"
            rclone delete "$REMOTE_PATH/$name" -q
            ((deleted++)) || true
        fi
    done <<< "$backups"

    # Check size limit
    local total_bytes=$(rclone size "$REMOTE_PATH/" --json 2>/dev/null | jq -r '.bytes // 0')
    local total_mb=$((total_bytes / 1024 / 1024))
    local limit_mb=${DELETE_OLDEST_WHEN_EXCEEDS_MB:-5000}

    if [[ $total_mb -gt $limit_mb ]]; then
        log "Storage ${total_mb}MB > ${limit_mb}MB limit, deleting oldest..."
        while [[ $total_mb -gt $limit_mb ]]; do
            local oldest=$(rclone lsjson "$REMOTE_PATH/" 2>/dev/null | \
                jq -r 'sort_by(.ModTime) | .[0].Name // empty')
            [[ -z "$oldest" ]] && break
            log "Deleting oldest: $oldest"
            rclone delete "$REMOTE_PATH/$oldest" -q
            total_bytes=$(rclone size "$REMOTE_PATH/" --json 2>/dev/null | jq -r '.bytes // 0')
            total_mb=$((total_bytes / 1024 / 1024))
        done
    fi

    log "Retention applied: $deleted deleted, ${total_mb}MB used"
}

# Download
do_download() {
    load_config
    local name="$1" dest="${2:-.}"
    [[ -z "$name" ]] && error "Usage: $0 download <filename> [dest]"
    log "Downloading: $name"
    rclone copy "$REMOTE_PATH/$name" "$dest/" --progress
    log "Downloaded: $dest/$name"
}

# Restore
do_restore() {
    load_config
    local file="$1" target="${2:-$DB_NAME}"
    [[ -z "$file" ]] && error "Usage: $0 restore <file.zip> [database]"
    [[ ! -f "$file" ]] && error "File not found: $file"

    warn "This will OVERWRITE: $target"
    read -p "Type 'yes' to confirm: " c
    [[ "$c" != "yes" ]] && { echo "Cancelled"; exit 0; }

    local tmp=$(mktemp -d)
    trap "rm -rf $tmp" EXIT

    log "Extracting..."
    if [[ -n "$ZIP_PASSWORD" ]]; then
        unzip -q -P "$ZIP_PASSWORD" "$file" -d "$tmp"
    else
        unzip -q "$file" -d "$tmp"
    fi

    local sql=$(find "$tmp" -name "*.sql" | head -1)
    [[ -z "$sql" ]] && error "No SQL file in archive"

    log "Restoring to: $target"
    case "$DB_DRIVER" in
        mysql|mariadb)
            mysql -h"$DB_HOST" -P"${DB_PORT:-3306}" -u"$DB_USER" -p"$DB_PASSWORD" "$target" < "$sql"
            ;;
        postgresql|postgres)
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" "$target" < "$sql"
            ;;
    esac
    log "✓ Restore complete!"
}

# Test connections
do_test() {
    load_config
    echo "${BLUE}Testing connections...${NC}"

    echo -n "rclone remote ($RCLONE_REMOTE): "
    if rclone lsd "$RCLONE_REMOTE:" &>/dev/null; then
        echo "${GREEN}OK${NC}"
    else
        echo "${RED}FAILED${NC}"
    fi

    echo -n "S3 bucket: "
    if rclone lsd "$RCLONE_REMOTE:$S3_BUCKET" &>/dev/null; then
        echo "${GREEN}OK${NC}"
    else
        echo "${RED}FAILED (bucket may not exist)${NC}"
    fi

    echo -n "Database ($DB_DRIVER): "
    case "$DB_DRIVER" in
        mysql|mariadb)
            if mysqladmin ping -h"$DB_HOST" -P"${DB_PORT:-3306}" -u"$DB_USER" -p"$DB_PASSWORD" --silent &>/dev/null; then
                echo "${GREEN}OK${NC}"
            else
                echo "${RED}FAILED${NC}"
            fi ;;
        postgresql|postgres)
            if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" -c '\q' &>/dev/null; then
                echo "${GREEN}OK${NC}"
            else
                echo "${RED}FAILED${NC}"
            fi ;;
    esac
}

# Setup cron
do_cron() {
    local sched="${1:-0 2 * * *}"
    local cmd="$(realpath "$0") backup"
    (crontab -l 2>/dev/null | grep -v "s3backup") | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$sched $cmd >> $LOG_FILE 2>&1") | crontab -
    echo "${GREEN}✓ Cron added: $sched${NC}"
    crontab -l 2>/dev/null | grep s3backup || true
}

# Config commands
do_config() { echo "${BLUE}$CONFIG_FILE${NC}"; cat "$CONFIG_FILE"; }
do_edit() { ${EDITOR:-nano} "$CONFIG_FILE"; }

# Setup rclone
do_setup_rclone() {
    echo "${BLUE}Setting up rclone for S3...${NC}"
    echo ""
    echo "Enter your S3 credentials:"
    read -p "Remote name [s3backup]: " rname; rname="${rname:-s3backup}"
    read -p "S3 Provider (AWS/Minio/DigitalOcean/Other) [AWS]: " provider; provider="${provider:-AWS}"
    read -p "Access Key ID: " access_key
    read -sp "Secret Access Key: " secret_key; echo ""
    read -p "Region [us-east-1]: " region; region="${region:-us-east-1}"
    read -p "Endpoint (leave empty for AWS): " endpoint

    rclone config create "$rname" s3 \
        provider="$provider" \
        access_key_id="$access_key" \
        secret_access_key="$secret_key" \
        region="$region" \
        ${endpoint:+endpoint="$endpoint"} \
        acl=private

    echo "${GREEN}✓ rclone remote '$rname' created${NC}"
    echo "Update RCLONE_REMOTE in config: $(basename "$0") edit"
}

# Init config
do_init() {
    local cdir; [[ $EUID -eq 0 ]] && cdir="/etc/snapback" || cdir="$HOME/.snapback"
    mkdir -p "$cdir" "$cdir/logs" 2>/dev/null || true

    [[ -f "$cdir/config.conf" ]] && { warn "Config exists: $cdir/config.conf"; read -p "Overwrite? (y/N): " c; [[ "$c" != "y" ]] && exit 0; }

    cat > "$cdir/config.conf" << 'DEFCONF'
# =============================================================================
# Snapback Configuration
# =============================================================================

# rclone Remote (run: snapback setup-rclone)
RCLONE_REMOTE="s3backup"

# S3 Bucket & Path
S3_BUCKET="your-bucket-name"
S3_PATH_PREFIX="Backups/my-server"          # e.g., Backups/production-server

# Database (mysql, mariadb, postgresql)
DB_DRIVER="mysql"
DB_HOST="localhost"
DB_PORT="3306"
DB_NAME="your_database"
DB_USER="your_user"
DB_PASSWORD="your_password"
DB_MULTIPLE=""                               # "db1,db2,db3"

# Backup Settings
BACKUP_PREFIX="backup"
BACKUP_DATABASE=true
BACKUP_FILES=false

# ZIP Password (leave empty for no password)
ZIP_PASSWORD="your-secure-password"

# Upload Verification (compare file sizes after upload)
VERIFY_UPLOAD=true

# Webhook Notifications (leave empty to disable)
# Supports: Slack, Discord, or any generic webhook
WEBHOOK_URL=""
# Examples:
# WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"
# WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy"
# WEBHOOK_URL="https://your-server.com/webhook"

# File Backup (if BACKUP_FILES=true)
FILES_INCLUDE=(
    "/var/www/html"
)
FILES_EXCLUDE=(
    "/var/www/html/vendor"
    "/var/www/html/node_modules"
    "/var/www/html/storage"
    "/var/www/html/.git"
)

# Retention Policy
KEEP_ALL_BACKUPS_FOR_DAYS=7                  # Keep every backup
KEEP_DAILY_BACKUPS_FOR_DAYS=16               # Keep one per day
KEEP_WEEKLY_BACKUPS_FOR_WEEKS=8              # Keep Monday backup
KEEP_MONTHLY_BACKUPS_FOR_MONTHS=4            # Keep 1st of month
KEEP_YEARLY_BACKUPS_FOR_YEARS=2              # Keep Jan 1st
DELETE_OLDEST_WHEN_EXCEEDS_MB=5000           # Max storage in MB
DEFCONF

    echo "${GREEN}✓ Config: $cdir/config.conf${NC}"
    echo "Next: $(basename "$0") setup-rclone && $(basename "$0") edit"
}

# Self-update from GitHub
do_update() {
    echo "${BLUE}Checking for updates...${NC}"
    
    # Get latest version from GitHub
    local latest_version
    latest_version=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    
    if [[ -z "$latest_version" ]]; then
        # Fallback: try to get version from raw file
        latest_version=$(curl -sL "$GITHUB_RAW/main/install.sh" | grep -m1 'VERSION=' | cut -d'"' -f2)
    fi
    
    if [[ -z "$latest_version" ]]; then
        echo "${RED}Failed to check for updates. Please check your internet connection.${NC}"
        exit 1
    fi
    
    echo "Current version: ${YELLOW}v$VERSION${NC}"
    echo "Latest version:  ${GREEN}v$latest_version${NC}"
    
    # Compare versions
    if [[ "$VERSION" == "$latest_version" ]]; then
        echo "${GREEN}✓ You are already running the latest version!${NC}"
        exit 0
    fi
    
    echo ""
    read -p "Update to v$latest_version? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Update cancelled."; exit 0; }
    
    echo "${BLUE}Downloading latest version...${NC}"
    
    local tmp_script
    tmp_script=$(mktemp)
    trap "rm -f $tmp_script" EXIT
    
    # Download from GitHub releases or raw
    if ! curl -sL "https://github.com/$GITHUB_REPO/releases/latest/download/snapback" -o "$tmp_script" 2>/dev/null; then
        # Fallback to raw main branch
        curl -sL "$GITHUB_RAW/main/install.sh" -o "$tmp_script" || {
            echo "${RED}Failed to download update.${NC}"
            exit 1
        }
    fi
    
    # Verify download
    if [[ ! -s "$tmp_script" ]]; then
        echo "${RED}Downloaded file is empty. Update failed.${NC}"
        exit 1
    fi
    
    # Check if it's a valid bash script
    if ! head -1 "$tmp_script" | grep -q '^#!/bin/bash'; then
        echo "${RED}Invalid script downloaded. Update failed.${NC}"
        exit 1
    fi
    
    # Determine install location
    local script_path
    script_path=$(realpath "$0")
    
    # Check write permission
    if [[ ! -w "$script_path" ]]; then
        echo "${YELLOW}Root permission required to update $script_path${NC}"
        sudo cp "$tmp_script" "$script_path"
        sudo chmod +x "$script_path"
    else
        cp "$tmp_script" "$script_path"
        chmod +x "$script_path"
    fi
    
    echo "${GREEN}✓ Updated to v$latest_version successfully!${NC}"
    echo "Run ${BLUE}snapback version${NC} to verify."
}

# Check for updates (non-interactive)
do_check_update() {
    local latest_version
    latest_version=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
    
    if [[ -z "$latest_version" ]]; then
        latest_version=$(curl -sL "$GITHUB_RAW/main/install.sh" 2>/dev/null | grep -m1 'VERSION=' | cut -d'"' -f2)
    fi
    
    if [[ -n "$latest_version" && "$VERSION" != "$latest_version" ]]; then
        echo "${YELLOW}Update available: v$VERSION → v$latest_version${NC}"
        echo "Run ${BLUE}snapback update${NC} to update."
    fi
}

show_help() {
    echo "${BLUE}Snapback v$VERSION - Database & Files Backup Tool${NC}"
    echo "${BLUE}https://github.com/$GITHUB_REPO${NC}"
    echo ""
    echo "${GREEN}COMMANDS:${NC}"
    echo "  backup           Full backup (db + files)"
    echo "  backup-db        Database backup only"
    echo "  backup-files     Files backup only"
    echo "  list             List backups in S3"
    echo "  download <file>  Download backup"
    echo "  restore <file>   Restore database"
    echo "  cleanup          Apply retention policy"
    echo "  test             Test connections"
    echo "  config           Show config"
    echo "  edit             Edit config"
    echo "  cron [schedule]  Setup cron (default: 0 2 * * *)"
    echo "  setup-rclone     Interactive rclone setup"
    echo "  init             Create default config"
    echo "  update           Update to latest version"
    echo "  version          Show version"
    echo ""
    echo "${GREEN}EXAMPLES:${NC}"
    echo "  snapback backup                    # Run backup"
    echo "  snapback list                      # List backups"
    echo "  snapback download backup_db.zip    # Download"
    echo "  snapback restore backup_db.zip     # Restore"
    echo "  snapback cron \"0 */6 * * *\"        # Every 6 hours"
    echo "  snapback update                    # Update to latest"
    echo ""
    echo "${GREEN}DEPENDENCIES:${NC}"
    echo "  ${YELLOW}Required:${NC} rclone, zip, jq, curl"
    echo "  ${YELLOW}MySQL:${NC}    mysql-client (apt) or mysql (brew)"
    echo "  ${YELLOW}Postgres:${NC} postgresql-client (apt) or postgresql (brew)"
    echo ""
    echo "${GREEN}CONFIG:${NC} $CONFIG_FILE"
    echo "${GREEN}GITHUB:${NC} https://github.com/$GITHUB_REPO"
}

do_version() {
    echo "Snapback v$VERSION"
    echo "https://github.com/$GITHUB_REPO"
    do_check_update
}

case "${1:-help}" in
    backup) do_backup_all ;;
    backup-db) do_backup_db ;;
    backup-files) do_backup_files ;;
    list|ls) do_list ;;
    download|dl) do_download "$2" "$3" ;;
    restore) do_restore "$2" "$3" ;;
    cleanup|clean) load_config; do_cleanup ;;
    test) do_test ;;
    config|show) do_config ;;
    edit) do_edit ;;
    cron) do_cron "$2" ;;
    setup-rclone) do_setup_rclone ;;
    init) do_init ;;
    update|upgrade) do_update ;;
    version|-v|--version) do_version ;;
    *) show_help ;;
esac
MAINSCRIPT

chmod +x "$INSTALL_DIR/$BACKUP_CMD"

echo -e "${GREEN}[2/4]${NC} Creating default config..."

cat > "$CONFIG_DIR/config.conf" << 'DEFCONFIG'
# =============================================================================
# Snapback Configuration
# =============================================================================

# rclone Remote Name (run: snapback setup-rclone)
RCLONE_REMOTE="s3backup"

# S3 Bucket & Path
S3_BUCKET="your-bucket-name"
S3_PATH_PREFIX="Backups/my-server"           # Path in bucket

# Database Settings
DB_DRIVER="mysql"                            # mysql, mariadb, postgresql
DB_HOST="localhost"
DB_PORT="3306"                               # MySQL:3306, PostgreSQL:5432
DB_NAME="your_database"
DB_USER="your_user"
DB_PASSWORD="your_password"
DB_MULTIPLE=""                               # Multiple: "db1,db2,db3"

# Backup Settings
BACKUP_PREFIX="backup"
BACKUP_DATABASE=true
BACKUP_FILES=false

# ZIP Password Protection (leave empty for no password)
ZIP_PASSWORD="change-this-password"

# Upload Verification (compare file sizes after upload)
VERIFY_UPLOAD=true

# Webhook Notifications (leave empty to disable)
# Supports: Slack, Discord, or any generic webhook
WEBHOOK_URL=""
# Examples:
# WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"
# WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy"

# File Backup Paths (if BACKUP_FILES=true)
FILES_INCLUDE=(
    "/var/www/html"
)
FILES_EXCLUDE=(
    "/var/www/html/vendor"
    "/var/www/html/node_modules"
    "/var/www/html/storage"
    "/var/www/html/.git"
)

# Retention Policy
KEEP_ALL_BACKUPS_FOR_DAYS=7
KEEP_DAILY_BACKUPS_FOR_DAYS=16
KEEP_WEEKLY_BACKUPS_FOR_WEEKS=8
KEEP_MONTHLY_BACKUPS_FOR_MONTHS=4
KEEP_YEARLY_BACKUPS_FOR_YEARS=2
DELETE_OLDEST_WHEN_EXCEEDS_MB=5000
DEFCONFIG

echo -e "${GREEN}[3/4]${NC} Checking dependencies..."

deps=""
command -v rclone &>/dev/null || deps="$deps rclone"
command -v zip &>/dev/null || deps="$deps zip"
command -v jq &>/dev/null || deps="$deps jq"

[[ -n "$deps" ]] && echo -e "${YELLOW}Install required:$deps${NC}"

echo -e "${GREEN}[4/4]${NC} Done!"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Snapback Installation Complete!${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Config:  ${BLUE}$CONFIG_DIR/config.conf${NC}"
echo -e "Command: ${BLUE}$BACKUP_CMD${NC}"
echo ""
echo -e "${YELLOW}Quick Start:${NC}"
echo -e "  1. Setup rclone:  ${GREEN}$BACKUP_CMD setup-rclone${NC}"
echo -e "  2. Edit config:   ${GREEN}$BACKUP_CMD edit${NC}"
echo -e "  3. Test:          ${GREEN}$BACKUP_CMD test${NC}"
echo -e "  4. Run backup:    ${GREEN}$BACKUP_CMD backup${NC}"
echo -e "  5. Setup cron:    ${GREEN}$BACKUP_CMD cron${NC}"
echo ""
echo -e "${YELLOW}Install Dependencies:${NC}"
echo "  # Ubuntu/Debian"
echo "  apt install rclone zip jq mysql-client"
echo ""
echo "  # macOS"
echo "  brew install rclone zip jq mysql-client"
echo ""

[[ "$INSTALL_DIR" == "$HOME/bin" && ":$PATH:" != *":$HOME/bin:"* ]] && \
    echo -e "${YELLOW}Add to PATH: export PATH=\"\$HOME/bin:\$PATH\"${NC}"
