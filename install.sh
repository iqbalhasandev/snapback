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
CLEANUP_DIRS=()

# Cleanup function
cleanup_on_exit() {
    for dir in "${CLEANUP_DIRS[@]}"; do
        [[ -d "$dir" ]] && rm -rf "$dir"
    done
}
trap cleanup_on_exit EXIT

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

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

log() { local m="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "${GREEN}$m${NC}"; echo "$m" >> "$LOG_FILE" 2>/dev/null || true; }
error() { local m="$1"; echo "${RED}[ERROR] $m${NC}" >&2; echo "[ERROR] $m" >> "$LOG_FILE" 2>/dev/null || true; send_webhook "failure" "$m"; exit 1; }
warn() { echo "${YELLOW}[WARN] $1${NC}"; }

# Lock file to prevent concurrent runs
acquire_lock() {
    # Check if flock is available
    if ! command -v flock &>/dev/null; then
        warn "flock not available, skipping lock"
        return 0
    fi
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
    return 0
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
    local err_file=$(mktemp)
    local creds_file=$(mktemp)
    chmod 600 "$creds_file"
    
    # Write credentials to temp file (more compatible than process substitution)
    printf "[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n" \
        "$DB_HOST" "${DB_PORT:-3306}" "$DB_USER" "$DB_PASSWORD" > "$creds_file"
    
    # Build mysqldump options (compatible with MySQL/MariaDB)
    local opts=(
        --defaults-extra-file="$creds_file"
        --single-transaction
        --routines
        --triggers
    )
    
    # Add optional flags only if supported
    mysqldump --help 2>/dev/null | grep -q "\-\-events" && opts+=(--events)
    mysqldump --help 2>/dev/null | grep -q "\-\-set-gtid-purged" && opts+=(--set-gtid-purged=OFF)
    mysqldump --help 2>/dev/null | grep -q "\-\-no-tablespaces" && opts+=(--no-tablespaces)
    
    if ! mysqldump "${opts[@]}" "$db" > "$out" 2>"$err_file"; then
        local err_msg=$(cat "$err_file")
        rm -f "$err_file" "$creds_file"
        error "MySQL dump failed for '$db': $err_msg"
    fi
    rm -f "$err_file" "$creds_file"
}

# PostgreSQL dump
backup_postgres() {
    local db="$1" out="$2"
    log "Dumping PostgreSQL: $db"
    local err_file=$(mktemp)
    if ! PGPASSWORD="$DB_PASSWORD" pg_dump \
        --host="$DB_HOST" \
        --port="${DB_PORT:-5432}" \
        --username="$DB_USER" \
        --no-password \
        --format=plain \
        "$db" > "$out" 2>"$err_file"; then
        local err_msg=$(cat "$err_file")
        rm -f "$err_file"
        error "PostgreSQL dump failed for '$db': $err_msg"
    fi
    rm -f "$err_file"
}

# Upload via rclone with verification
upload() {
    local file="$1"
    local fname=$(basename "$file")
    local dest="$REMOTE_PATH/$fname"
    log "Uploading: $dest"
    
    if ! rclone copy "$file" "$REMOTE_PATH/" --progress=false -q; then
        error "Upload failed for $fname"
    fi
    
    # Verify upload integrity
    if [[ "${VERIFY_UPLOAD:-true}" == "true" ]]; then
        log "Verifying upload integrity..."
        local local_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
        local remote_info=$(rclone size "$REMOTE_PATH/$fname" --json 2>/dev/null)
        
        if [[ -z "$remote_info" ]]; then
            warn "Could not verify upload (rclone size failed), checking file exists..."
            if rclone ls "$REMOTE_PATH/$fname" &>/dev/null; then
                log "✓ File exists in remote: $fname"
            else
                error "Upload verification failed: file not found in remote"
            fi
        else
            local remote_size=$(echo "$remote_info" | jq -r '.bytes // 0')
            if [[ "$local_size" != "$remote_size" ]]; then
                error "Upload verification failed: size mismatch (local: $local_size, remote: $remote_size)"
            fi
            log "✓ Verified: $fname ($local_size bytes)"
        fi
    else
        log "✓ Upload complete: $fname"
    fi
}

# Get all databases (excluding system databases)
_get_all_databases() {
    case "$DB_DRIVER" in
        mysql|mariadb)
            mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SHOW DATABASES" 2>/dev/null | \
                grep -Ev "^(information_schema|performance_schema|mysql|sys)$"
            ;;
        postgresql|postgres)
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres')" 2>/dev/null | \
                sed 's/^[[:space:]]*//' | grep -v '^$'
            ;;
    esac
}

# Dump databases to a folder (internal helper)
_dump_databases() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    
    local dbs=()
    if [[ "$DB_MULTIPLE" == "*" ]]; then
        # Backup ALL databases
        log "Discovering all databases..."
        while IFS= read -r db; do
            [[ -n "$db" ]] && dbs+=("$db")
        done < <(_get_all_databases)
        log "Found ${#dbs[@]} databases: ${dbs[*]}"
    elif [[ -n "$DB_MULTIPLE" ]]; then
        IFS=',' read -ra dbs <<< "$DB_MULTIPLE"
    else
        dbs=("$DB_NAME")
    fi

    for db in "${dbs[@]}"; do
        db=$(echo "$db" | xargs)
        [[ -z "$db" ]] && continue
        local sql="$dest_dir/${db}.sql"
        
        case "$DB_DRIVER" in
            mysql|mariadb) backup_mysql "$db" "$sql" ;;
            postgresql|postgres) backup_postgres "$db" "$sql" ;;
            *) error "Unsupported: $DB_DRIVER" ;;
        esac
    done
    return 0
}

# Archive files to a folder (internal helper)
_archive_files() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    
    local excludes=()
    for ex in "${FILES_EXCLUDE[@]}"; do excludes+=("--exclude=$ex"); done

    local tar_opts="-cf"
    [[ "${FOLLOW_SYMLINKS:-false}" == "true" ]] && tar_opts="-chf"
    tar $tar_opts "$dest_dir/files.tar" "${excludes[@]}" "${FILES_INCLUDE[@]}" 2>/dev/null || true
    return 0
}

# Database backup (standalone command)
do_backup_db() {
    load_config; check_deps
    local ts=$(date '+%Y-%m-%d_%H%M%S')
    local tmp=$(mktemp -d)
    CLEANUP_DIRS+=("$tmp")
    
    local backup_dir="$tmp/backup"
    mkdir -p "$backup_dir/Databases"
    
    log "Dumping databases..."
    _dump_databases "$backup_dir/Databases"
    
    local zipf="$tmp/${BACKUP_PREFIX:-backup}_db_${ts}.zip"
    log "Compressing with password protection..."
    
    # Create zip with folder structure
    (cd "$backup_dir" && zip -q -r ${ZIP_PASSWORD:+-P "$ZIP_PASSWORD"} "$zipf" Databases/)
    
    local sz=$(du -h "$zipf" | cut -f1)
    log "Size: $sz (encrypted)"
    upload "$zipf"
    log "✓ Database backup done!"
}

# Files backup (standalone command)
do_backup_files() {
    load_config; check_deps
    local ts=$(date '+%Y-%m-%d_%H%M%S')
    local tmp=$(mktemp -d)
    CLEANUP_DIRS+=("$tmp")
    
    local backup_dir="$tmp/backup"
    mkdir -p "$backup_dir/Files"
    
    log "Archiving files..."
    _archive_files "$backup_dir/Files"
    
    local zipf="$tmp/${BACKUP_PREFIX:-backup}_files_${ts}.zip"
    log "Compressing with password protection..."
    
    # Create zip with folder structure
    (cd "$backup_dir" && zip -q -r ${ZIP_PASSWORD:+-P "$ZIP_PASSWORD"} "$zipf" Files/)
    
    local sz=$(du -h "$zipf" | cut -f1)
    log "Size: $sz (encrypted)"
    upload "$zipf"
    log "✓ Files backup done!"
}

# Full backup - creates ONE zip with Databases/ and Files/ folders
do_backup_all() {
    load_config
    acquire_lock
    check_deps
    log "═══════════════════════════════════════"
    log "Starting Snapback v$VERSION..."
    local start_time=$(date +%s)
    
    local ts=$(date '+%Y-%m-%d_%H%M%S')
    local tmp=$(mktemp -d)
    CLEANUP_DIRS+=("$tmp")
    
    local backup_dir="$tmp/backup"
    mkdir -p "$backup_dir"
    
    # Dump databases to Databases/ folder
    if [[ "$BACKUP_DATABASE" != "false" ]]; then
        log "Dumping databases..."
        mkdir -p "$backup_dir/Databases"
        _dump_databases "$backup_dir/Databases"
        log "✓ Databases dumped"
    fi
    
    # Archive files to Files/ folder
    if [[ "$BACKUP_FILES" == "true" ]]; then
        log "Archiving files..."
        mkdir -p "$backup_dir/Files"
        _archive_files "$backup_dir/Files"
        log "✓ Files archived"
    fi
    
    # Create single zip with both folders
    local zipf="$tmp/${BACKUP_PREFIX:-backup}_${ts}.zip"
    log "Creating backup archive..."
    (cd "$backup_dir" && zip -q -r ${ZIP_PASSWORD:+-P "$ZIP_PASSWORD"} "$zipf" .)
    
    local sz=$(du -h "$zipf" | cut -f1)
    log "Size: $sz (encrypted)"
    
    # Upload single backup file
    upload "$zipf"
    
    do_cleanup
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log "═══════════════════════════════════════"
    log "✓ Backup completed in ${duration}s!"
    send_webhook "success" "Backup completed in ${duration}s"
}

# Human readable size
human_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        printf "%.1fG" $(echo "scale=1; $bytes/1073741824" | bc)
    elif [[ $bytes -ge 1048576 ]]; then
        printf "%.1fM" $(echo "scale=1; $bytes/1048576" | bc)
    elif [[ $bytes -ge 1024 ]]; then
        printf "%.1fK" $(echo "scale=1; $bytes/1024" | bc)
    else
        printf "%dB" $bytes
    fi
}

# List backups
do_list() {
    load_config
    echo "${BLUE}Backups in: $REMOTE_PATH${NC}"
    echo "─────────────────────────────────────────────────────"
    rclone ls "$REMOTE_PATH/" 2>/dev/null | while read -r sz name; do
        local szh=$(human_size $sz)
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
    CLEANUP_DIRS+=("$tmp")

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
    # Use rclone about or lsd with bucket for S3-compatible storage
    if rclone lsd "$RCLONE_REMOTE:" &>/dev/null || rclone lsd "$RCLONE_REMOTE:$S3_BUCKET" &>/dev/null; then
        echo "${GREEN}OK${NC}"
    else
        echo "${RED}FAILED${NC}"
    fi

    echo -n "S3 bucket ($S3_BUCKET): "
    if rclone lsd "$RCLONE_REMOTE:$S3_BUCKET" &>/dev/null; then
        echo "${GREEN}OK${NC}"
    else
        # Try to check if bucket exists by listing (some providers don't support lsd on root)
        if rclone ls "$RCLONE_REMOTE:$S3_BUCKET" --max-depth 1 &>/dev/null; then
            echo "${GREEN}OK${NC}"
        else
            echo "${RED}FAILED (bucket may not exist or no access)${NC}"
        fi
    fi

    if [[ "$BACKUP_DATABASE" == "true" && "$DB_DRIVER" != "none" ]]; then
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
    fi
}

# Setup cron
do_cron() {
    local sched="${1:-0 2 * * *}"
    local cmd="$(command -v snapback || realpath "$0") backup"
    (crontab -l 2>/dev/null | grep -v "snapback") | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$sched $cmd >> $LOG_FILE 2>&1") | crontab -
    echo "${GREEN}✓ Cron added: $sched${NC}"
    crontab -l 2>/dev/null | grep snapback || true
}

# Config commands
do_config() { echo "${BLUE}$CONFIG_FILE${NC}"; cat "$CONFIG_FILE"; }
do_edit() { ${EDITOR:-nano} "$CONFIG_FILE"; }

# Interactive configuration wizard
do_configure() {
    local cdir
    [[ $EUID -eq 0 ]] && cdir="/etc/snapback" || cdir="$HOME/.snapback"
    mkdir -p "$cdir" "$cdir/logs" 2>/dev/null || true
    
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           Snapback Configuration Wizard                       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check for existing config
    if [[ -f "$cdir/config.conf" ]]; then
        echo -e "${YELLOW}Existing configuration found at: $cdir/config.conf${NC}"
        read -p "Do you want to reconfigure? (y/N): " reconfigure
        [[ "$reconfigure" != "y" && "$reconfigure" != "Y" ]] && { echo "Configuration cancelled."; exit 0; }
        # Load existing values as defaults
        source "$cdir/config.conf" 2>/dev/null || true
    fi
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  S3 Storage Configuration${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # rclone remote name
    local default_remote="${RCLONE_REMOTE:-s3backup}"
    read -p "rclone remote name [$default_remote]: " input_remote
    RCLONE_REMOTE="${input_remote:-$default_remote}"
    
    # Check if rclone remote exists
    local setup_rclone="n"
    if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"; then
        echo -e "${GREEN}✓ rclone remote '$RCLONE_REMOTE' already configured${NC}"
        read -p "Reconfigure rclone credentials? (y/N): " setup_rclone
    else
        echo -e "${YELLOW}rclone remote '$RCLONE_REMOTE' not found${NC}"
        setup_rclone="y"
    fi
    
    # Setup rclone if needed
    if [[ "$setup_rclone" == "y" || "$setup_rclone" == "Y" ]]; then
        echo ""
        echo -e "${CYAN}Enter your S3 credentials:${NC}"
        read -p "S3 Provider (AWS/Minio/DigitalOcean/Other) [AWS]: " s3_provider
        s3_provider="${s3_provider:-AWS}"
        read -p "Access Key ID: " s3_access_key
        read -sp "Secret Access Key: " s3_secret_key; echo ""
        read -p "Region [us-east-1]: " s3_region
        s3_region="${s3_region:-us-east-1}"
        read -p "Endpoint (leave empty for AWS): " s3_endpoint
        
        # Create rclone remote (add no_check_bucket for non-AWS providers)
        local s3_extra=""
        [[ "$s3_provider" != "AWS" ]] && s3_extra="no_check_bucket=true"
        
        rclone config create "$RCLONE_REMOTE" s3 \
            provider="$s3_provider" \
            access_key_id="$s3_access_key" \
            secret_access_key="$s3_secret_key" \
            region="$s3_region" \
            ${s3_endpoint:+endpoint="$s3_endpoint"} \
            ${s3_extra:+$s3_extra} \
            acl=private 2>/dev/null
        
        echo -e "${GREEN}✓ rclone remote '$RCLONE_REMOTE' configured${NC}"
    fi
    
    echo ""
    # S3 Bucket
    local default_bucket="${S3_BUCKET:-your-bucket-name}"
    read -p "S3 Bucket name [$default_bucket]: " input_bucket
    S3_BUCKET="${input_bucket:-$default_bucket}"
    
    # S3 Path Prefix
    local default_prefix="${S3_PATH_PREFIX:-Backups/my-server}"
    read -p "S3 Path prefix [$default_prefix]: " input_prefix
    S3_PATH_PREFIX="${input_prefix:-$default_prefix}"
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Database Configuration${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # DB Driver selection
    echo "Select database driver:"
    echo -e "  ${CYAN}1)${NC} mysql"
    echo -e "  ${CYAN}2)${NC} mariadb"
    echo -e "  ${CYAN}3)${NC} postgresql"
    echo -e "  ${CYAN}4)${NC} none (skip database backup)"
    
    local default_driver_num=1
    case "${DB_DRIVER:-mysql}" in
        mysql) default_driver_num=1 ;;
        mariadb) default_driver_num=2 ;;
        postgresql|postgres) default_driver_num=3 ;;
        none) default_driver_num=4 ;;
    esac
    
    read -p "Choose [1-4] [$default_driver_num]: " driver_choice
    driver_choice="${driver_choice:-$default_driver_num}"
    
    local BACKUP_DATABASE="true"
    case "$driver_choice" in
        1) DB_DRIVER="mysql" ;;
        2) DB_DRIVER="mariadb" ;;
        3) DB_DRIVER="postgresql" ;;
        4) DB_DRIVER="none"; BACKUP_DATABASE="false" ;;
        *) DB_DRIVER="mysql" ;;
    esac
    
    if [[ "$BACKUP_DATABASE" == "true" ]]; then
        # Set default port based on driver
        local default_port="3306"
        [[ "$DB_DRIVER" == "postgresql" ]] && default_port="5432"
        
        # DB Host
        local default_host="${DB_HOST:-localhost}"
        read -p "Database host [$default_host]: " input_host
        DB_HOST="${input_host:-$default_host}"
        
        # DB Port
        local current_port="${DB_PORT:-$default_port}"
        read -p "Database port [$current_port]: " input_port
        DB_PORT="${input_port:-$current_port}"
        
        # DB User
        local default_user="${DB_USER:-root}"
        read -p "Database username [$default_user]: " input_user
        DB_USER="${input_user:-$default_user}"
        
        # DB Password
        echo -n "Database password: "
        read -s input_db_pass
        echo ""
        DB_PASSWORD="${input_db_pass:-$DB_PASSWORD}"
        
        # Multiple databases
        echo ""
        echo -e "${YELLOW}Enter database names to backup (comma-separated, or single name):${NC}"
        echo -e "  Example: ${CYAN}mydb${NC} or ${CYAN}db1,db2,db3${NC}"
        local default_dbs="${DB_MULTIPLE:-${DB_NAME:-}}"
        read -p "Databases [$default_dbs]: " input_dbs
        input_dbs="${input_dbs:-$default_dbs}"
        
        # Parse databases
        if [[ "$input_dbs" == *","* ]]; then
            DB_MULTIPLE="$input_dbs"
            DB_NAME=$(echo "$input_dbs" | cut -d',' -f1 | xargs)
        else
            DB_NAME="$input_dbs"
            DB_MULTIPLE=""
        fi
    fi
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Security Configuration${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # ZIP Password
    echo -e "${YELLOW}Set a password for backup encryption (leave empty for no encryption):${NC}"
    echo -n "Backup encryption password: "
    read -s input_zip_pass
    echo ""
    ZIP_PASSWORD="${input_zip_pass:-$ZIP_PASSWORD}"
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Notification Configuration${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Webhook URL
    echo -e "${YELLOW}Enter webhook URL for notifications (Slack, Discord, or custom):${NC}"
    echo -e "  Leave empty to disable notifications"
    local default_webhook="${WEBHOOK_URL:-}"
    read -p "Webhook URL [$default_webhook]: " input_webhook
    WEBHOOK_URL="${input_webhook:-$default_webhook}"
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  File Backup Configuration${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Enable file backup?
    read -p "Enable file backup? (y/N): " enable_files
    local BACKUP_FILES="false"
    local FILES_INCLUDE_STR=""
    local FILES_EXCLUDE_STR=""
    local FOLLOW_SYMLINKS="false"
    
    if [[ "$enable_files" == "y" || "$enable_files" == "Y" ]]; then
        BACKUP_FILES="true"
        
        # Files to include
        echo ""
        echo -e "${YELLOW}Enter paths to include in backup (comma-separated):${NC}"
        echo -e "  Example: ${CYAN}/var/www/html,/home/user/data${NC}"
        local default_include="/var/www/html"
        read -p "Include paths [$default_include]: " input_include
        FILES_INCLUDE_STR="${input_include:-$default_include}"
        
        # Files to exclude
        echo ""
        echo -e "${YELLOW}Enter paths to exclude from backup (comma-separated):${NC}"
        echo -e "  Example: ${CYAN}vendor,node_modules,.git,storage${NC}"
        local default_exclude="vendor,node_modules,.git,storage"
        read -p "Exclude patterns [$default_exclude]: " input_exclude
        FILES_EXCLUDE_STR="${input_exclude:-$default_exclude}"
        
        # Follow symlinks
        echo ""
        read -p "Follow symbolic links? (y/N): " follow_sym
        [[ "$follow_sym" == "y" || "$follow_sym" == "Y" ]] && FOLLOW_SYMLINKS="true"
    fi
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Retention Policy Configuration${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}Configure how long to keep backups:${NC}"
    echo ""
    
    # Keep all backups for X days
    local default_keep_all="${KEEP_ALL_BACKUPS_FOR_DAYS:-7}"
    read -p "Keep ALL backups for how many days? [$default_keep_all]: " input_keep_all
    KEEP_ALL_BACKUPS_FOR_DAYS="${input_keep_all:-$default_keep_all}"
    
    # Keep daily backups for X days
    local default_keep_daily="${KEEP_DAILY_BACKUPS_FOR_DAYS:-16}"
    read -p "Keep DAILY backups for how many days? [$default_keep_daily]: " input_keep_daily
    KEEP_DAILY_BACKUPS_FOR_DAYS="${input_keep_daily:-$default_keep_daily}"
    
    # Keep weekly backups for X weeks
    local default_keep_weekly="${KEEP_WEEKLY_BACKUPS_FOR_WEEKS:-8}"
    read -p "Keep WEEKLY backups for how many weeks? [$default_keep_weekly]: " input_keep_weekly
    KEEP_WEEKLY_BACKUPS_FOR_WEEKS="${input_keep_weekly:-$default_keep_weekly}"
    
    # Keep monthly backups for X months
    local default_keep_monthly="${KEEP_MONTHLY_BACKUPS_FOR_MONTHS:-4}"
    read -p "Keep MONTHLY backups for how many months? [$default_keep_monthly]: " input_keep_monthly
    KEEP_MONTHLY_BACKUPS_FOR_MONTHS="${input_keep_monthly:-$default_keep_monthly}"
    
    # Keep yearly backups for X years
    local default_keep_yearly="${KEEP_YEARLY_BACKUPS_FOR_YEARS:-2}"
    read -p "Keep YEARLY backups for how many years? [$default_keep_yearly]: " input_keep_yearly
    KEEP_YEARLY_BACKUPS_FOR_YEARS="${input_keep_yearly:-$default_keep_yearly}"
    
    # Max storage size
    local default_max_mb="${DELETE_OLDEST_WHEN_EXCEEDS_MB:-5000}"
    read -p "Maximum storage size in MB (oldest deleted when exceeded) [$default_max_mb]: " input_max_mb
    DELETE_OLDEST_WHEN_EXCEEDS_MB="${input_max_mb:-$default_max_mb}"
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Generating Configuration...${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Generate FILES_INCLUDE array
    local files_include_array=""
    if [[ -n "$FILES_INCLUDE_STR" ]]; then
        IFS=',' read -ra paths <<< "$FILES_INCLUDE_STR"
        for path in "${paths[@]}"; do
            path=$(echo "$path" | xargs)  # trim whitespace
            files_include_array+="    \"$path\"\n"
        done
    else
        files_include_array="    \"/var/www/html\"\n"
    fi
    
    # Generate FILES_EXCLUDE array
    local files_exclude_array=""
    if [[ -n "$FILES_EXCLUDE_STR" ]]; then
        IFS=',' read -ra patterns <<< "$FILES_EXCLUDE_STR"
        for pattern in "${patterns[@]}"; do
            pattern=$(echo "$pattern" | xargs)  # trim whitespace
            # Add full path if it looks like a relative pattern
            if [[ "$pattern" != /* ]]; then
                files_exclude_array+="    \"*/$pattern\"\n"
            else
                files_exclude_array+="    \"$pattern\"\n"
            fi
        done
    else
        files_exclude_array="    \"*/vendor\"\n    \"*/node_modules\"\n    \"*/storage\"\n    \"*/.git\"\n"
    fi
    
    # Write config file
    cat > "$cdir/config.conf" << GENCONFIG
# =============================================================================
# Snapback Configuration
# Generated by: snapback configure
# Generated at: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# rclone Remote Name (run: snapback setup-rclone)
RCLONE_REMOTE="$RCLONE_REMOTE"

# S3 Bucket & Path
S3_BUCKET="$S3_BUCKET"
S3_PATH_PREFIX="$S3_PATH_PREFIX"

# Database Settings
DB_DRIVER="$DB_DRIVER"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"
DB_MULTIPLE="$DB_MULTIPLE"

# Backup Settings
BACKUP_PREFIX="backup"
BACKUP_DATABASE=$BACKUP_DATABASE
BACKUP_FILES=$BACKUP_FILES

# ZIP Password Protection (leave empty for no password)
ZIP_PASSWORD="$ZIP_PASSWORD"

# Upload Verification
VERIFY_UPLOAD=true

# Follow Symbolic Links (for file backup)
FOLLOW_SYMLINKS=$FOLLOW_SYMLINKS

# Webhook Notifications
WEBHOOK_URL="$WEBHOOK_URL"

# File Backup Paths (if BACKUP_FILES=true)
FILES_INCLUDE=(
$(echo -e "$files_include_array"))
FILES_EXCLUDE=(
$(echo -e "$files_exclude_array"))

# Retention Policy
KEEP_ALL_BACKUPS_FOR_DAYS=$KEEP_ALL_BACKUPS_FOR_DAYS
KEEP_DAILY_BACKUPS_FOR_DAYS=$KEEP_DAILY_BACKUPS_FOR_DAYS
KEEP_WEEKLY_BACKUPS_FOR_WEEKS=$KEEP_WEEKLY_BACKUPS_FOR_WEEKS
KEEP_MONTHLY_BACKUPS_FOR_MONTHS=$KEEP_MONTHLY_BACKUPS_FOR_MONTHS
KEEP_YEARLY_BACKUPS_FOR_YEARS=$KEEP_YEARLY_BACKUPS_FOR_YEARS
DELETE_OLDEST_WHEN_EXCEEDS_MB=$DELETE_OLDEST_WHEN_EXCEEDS_MB
GENCONFIG
    
    echo -e "${GREEN}✓ Configuration saved to: $cdir/config.conf${NC}"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Configuration Summary${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  rclone Remote:  ${BLUE}$RCLONE_REMOTE${NC}"
    echo -e "  S3 Bucket:      ${BLUE}$S3_BUCKET${NC}"
    echo -e "  S3 Path:        ${BLUE}$S3_PATH_PREFIX${NC}"
    if [[ "$BACKUP_DATABASE" == "true" ]]; then
        echo -e "  Database:       ${BLUE}$DB_DRIVER${NC} @ ${BLUE}$DB_HOST:$DB_PORT${NC}"
        [[ -n "$DB_MULTIPLE" ]] && echo -e "  Databases:      ${BLUE}$DB_MULTIPLE${NC}" || echo -e "  Database:       ${BLUE}$DB_NAME${NC}"
    fi
    echo -e "  Backup DB:      ${BLUE}$BACKUP_DATABASE${NC}"
    echo -e "  Backup Files:   ${BLUE}$BACKUP_FILES${NC}"
    [[ -n "$ZIP_PASSWORD" ]] && echo -e "  Encryption:     ${GREEN}Enabled${NC}" || echo -e "  Encryption:     ${YELLOW}Disabled${NC}"
    [[ -n "$WEBHOOK_URL" ]] && echo -e "  Notifications:  ${GREEN}Enabled${NC}" || echo -e "  Notifications:  ${YELLOW}Disabled${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Test config:   ${GREEN}snapback test${NC}"
    echo -e "  2. Run backup:    ${GREEN}snapback backup${NC}"
    echo -e "  3. Setup cron:    ${GREEN}snapback cron${NC}"
    echo ""
}

# Setup rclone
do_setup_rclone() {
    echo "${BLUE}Setting up rclone for S3...${NC}"
    echo ""
    
    # Load current config to get default remote name
    local current_remote="s3backup"
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null && current_remote="${RCLONE_REMOTE:-s3backup}"
    
    echo "Enter your S3 credentials:"
    read -p "Remote name [$current_remote]: " rname; rname="${rname:-$current_remote}"
    read -p "S3 Provider (AWS/Minio/DigitalOcean/Other) [AWS]: " provider; provider="${provider:-AWS}"
    read -p "Access Key ID: " access_key
    read -sp "Secret Access Key: " secret_key; echo ""
    read -p "Region [us-east-1]: " region; region="${region:-us-east-1}"
    read -p "Endpoint (leave empty for AWS): " endpoint

    # Add no_check_bucket for S3-compatible storage (DigitalOcean, Minio, etc.)
    local extra_opts=""
    [[ "$provider" != "AWS" ]] && extra_opts="no_check_bucket=true"
    
    rclone config create "$rname" s3 \
        provider="$provider" \
        access_key_id="$access_key" \
        secret_access_key="$secret_key" \
        region="$region" \
        ${endpoint:+endpoint="$endpoint"} \
        ${extra_opts:+$extra_opts} \
        acl=private

    echo "${GREEN}✓ rclone remote '$rname' created${NC}"
    
    # Update config file with new remote name if it changed
    if [[ -f "$CONFIG_FILE" ]]; then
        if grep -q "^RCLONE_REMOTE=" "$CONFIG_FILE"; then
            sed -i.bak "s/^RCLONE_REMOTE=.*/RCLONE_REMOTE=\"$rname\"/" "$CONFIG_FILE"
            rm -f "${CONFIG_FILE}.bak"
            echo "${GREEN}✓ Config updated: RCLONE_REMOTE=\"$rname\"${NC}"
        fi
    fi
    
    echo ""
    echo "Test your connection: snapback test"
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
        latest_version=$(curl -sL "$GITHUB_RAW/main/install.sh" | grep -m1 '^VERSION=' | cut -d'"' -f2)
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
    
    local tmp_installer tmp_script
    tmp_installer=$(mktemp)
    tmp_script=$(mktemp)
    
    # Cleanup function for update
    cleanup_update() { rm -f "$tmp_installer" "$tmp_script"; }
    
    # Download installer from GitHub
    curl -sL "$GITHUB_RAW/main/install.sh" -o "$tmp_installer" || {
        echo "${RED}Failed to download update.${NC}"
        cleanup_update
        exit 1
    }
    
    # Verify download
    if [[ ! -s "$tmp_installer" ]]; then
        echo "${RED}Downloaded file is empty. Update failed.${NC}"
        cleanup_update
        exit 1
    fi
    
    # Check if it's a valid bash script
    if ! head -1 "$tmp_installer" | grep -q '^#!/bin/bash'; then
        echo "${RED}Invalid script downloaded. Update failed.${NC}"
        cleanup_update
        exit 1
    fi
    
    # Extract the MAINSCRIPT content from the installer
    # Extract content between 'cat > "$INSTALL_DIR/$BACKUP_CMD" << '\''MAINSCRIPT'\''' and 'MAINSCRIPT'
    sed -n "/^cat > \"\\\$INSTALL_DIR\/\\\$BACKUP_CMD\" << 'MAINSCRIPT'$/,/^MAINSCRIPT$/p" "$tmp_installer" | \
        sed '1d;$d' > "$tmp_script"
    
    # Verify extraction
    if [[ ! -s "$tmp_script" ]]; then
        echo "${RED}Failed to extract script. Update failed.${NC}"
        cleanup_update
        exit 1
    fi
    
    # Check extracted script is valid
    if ! head -1 "$tmp_script" | grep -q '^#!/bin/bash'; then
        echo "${RED}Invalid script extracted. Update failed.${NC}"
        cleanup_update
        exit 1
    fi
    
    # Determine install location
    local script_path
    script_path=$(realpath "$0")
    
    # Check write permission and update
    if [[ ! -w "$script_path" ]]; then
        echo "${YELLOW}Root permission required to update $script_path${NC}"
        sudo cp "$tmp_script" "$script_path"
        sudo chmod +x "$script_path"
    else
        cp "$tmp_script" "$script_path"
        chmod +x "$script_path"
    fi
    
    cleanup_update
    
    echo "${GREEN}✓ Updated to v$latest_version successfully!${NC}"
    echo "Run ${BLUE}snapback version${NC} to verify."
}

# Check for updates (non-interactive)
do_check_update() {
    local latest_version
    latest_version=$(curl -sL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true)
    
    if [[ -z "$latest_version" ]]; then
        latest_version=$(curl -sL "$GITHUB_RAW/main/install.sh" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2 || true)
    fi
    
    if [[ -n "$latest_version" && "$VERSION" != "$latest_version" ]]; then
        echo "${YELLOW}Update available: v$VERSION → v$latest_version${NC}"
        echo "Run ${BLUE}snapback update${NC} to update."
    fi
    return 0
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
    echo "  configure        Interactive configuration wizard"
    echo "  edit             Edit config"
    echo "  cron [schedule]  Setup cron (default: 0 2 * * *)"
    echo "  setup-rclone     Interactive rclone setup"
    echo "  init             Create default config"
    echo "  update           Update to latest version"
    echo "  version          Show version"
    echo ""
    echo "${GREEN}EXAMPLES:${NC}"
    echo "  snapback configure                 # Interactive setup wizard"
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
    configure) do_configure ;;
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

echo -e "${GREEN}[2/4]${NC} Checking config..."

# Only create default config if it doesn't exist
if [[ -f "$CONFIG_DIR/config.conf" ]]; then
    echo -e "${YELLOW}Existing config found, preserving: $CONFIG_DIR/config.conf${NC}"
else
    echo -e "${GREEN}Creating default config...${NC}"
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
fi

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
echo -e "  1. Configure:     ${GREEN}$BACKUP_CMD configure${NC}  (interactive wizard)"
echo -e "  2. Setup rclone:  ${GREEN}$BACKUP_CMD setup-rclone${NC}"
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

if [[ "$INSTALL_DIR" == "$HOME/bin" && ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo -e "${YELLOW}Add to PATH: export PATH=\"\$HOME/bin:\$PATH\"${NC}"
fi

exit 0