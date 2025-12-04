# Snapback - Database & Files Backup Tool

[![GitHub release](https://img.shields.io/github/v/release/iqbalhasandev/snapback?style=flat-square)](https://github.com/iqbalhasandev/snapback/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)

One-line installer for MySQL/PostgreSQL backup to S3 using **rclone** with **password-protected zip** and automatic retention.

## Features

- **rclone** - Supports 40+ cloud storage providers
- **Password-protected ZIP** - Encrypted backups
- **MySQL/MariaDB/PostgreSQL** - Multi-database support
- **Smart Retention** - Daily/weekly/monthly/yearly policies
- **File Backup** - Include/exclude paths
- **Webhook Notifications** - Slack, Discord, or custom webhooks
- **Upload Verification** - Integrity checks after upload
- **Secure Credentials** - Passwords hidden from process list
- **Lock File** - Prevents concurrent backup runs
- **Self-Update** - Update to latest version with one command

## Quick Install

```bash
# As root (system-wide)
curl -sL https://raw.githubusercontent.com/iqbalhasandev/snapback/main/install.sh | sudo bash

# As user (~/bin)
curl -sL https://raw.githubusercontent.com/iqbalhasandev/snapback/main/install.sh | bash
```

## Quick Start

```bash
# 1. Setup rclone (interactive S3 setup)
snapback setup-rclone

# 2. Edit config
snapback edit

# 3. Test connections
snapback test

# 4. Run backup
snapback backup

# 5. Setup cron
snapback cron
```

## Commands

| Command | Description |
|---------|-------------|
| `snapback backup` | Full backup (db + files) |
| `snapback backup-db` | Database only |
| `snapback backup-files` | Files only |
| `snapback list` | List backups in S3 |
| `snapback download <file>` | Download backup |
| `snapback restore <file>` | Restore database |
| `snapback cleanup` | Apply retention |
| `snapback test` | Test connections |
| `snapback config` | Show config |
| `snapback edit` | Edit config |
| `snapback cron` | Daily cron (2 AM) |
| `snapback cron "0 */6 * * *"` | Custom schedule |
| `snapback setup-rclone` | Setup rclone remote |
| `snapback init` | Create config |
| `snapback update` | Update to latest version |
| `snapback version` | Show version |

## Dependencies

```bash
# Ubuntu/Debian
apt install rclone zip jq curl mysql-client        # For MySQL
apt install rclone zip jq curl postgresql-client   # For PostgreSQL

# macOS
brew install rclone zip jq curl mysql-client       # For MySQL
brew install rclone zip jq curl postgresql         # For PostgreSQL

# CentOS/RHEL
yum install rclone zip jq curl mysql               # For MySQL
yum install rclone zip jq curl postgresql          # For PostgreSQL
```

## Configuration

**Location:**
- Root: `/etc/snapback/config.conf`
- User: `~/.snapback/config.conf`

### Full Config

```bash
# =============================================================================
# Snapback Configuration
# =============================================================================

# rclone Remote (run: snapback setup-rclone)
RCLONE_REMOTE="s3backup"

# S3 Bucket & Path
S3_BUCKET="my-bucket"
S3_PATH_PREFIX="Backups/nano-server"         # Store in Backups/nano-server/

# Database
DB_DRIVER="mysql"                            # mysql, mariadb, postgresql
DB_HOST="localhost"
DB_PORT="3306"                               # MySQL: 3306, PostgreSQL: 5432
DB_NAME="my_database"
DB_USER="backup_user"
DB_PASSWORD="secret123"
DB_MULTIPLE=""                               # "db1,db2,db3"

# Backup Settings
BACKUP_PREFIX="backup"
BACKUP_DATABASE=true
BACKUP_FILES=false

# ZIP Password (leave empty for no password)
ZIP_PASSWORD="your-super-secret-password"

# Upload Verification
VERIFY_UPLOAD=true                           # Verify file integrity after upload

# Webhook Notifications (leave empty to disable)
WEBHOOK_URL=""                               # Slack, Discord, or custom webhook

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
KEEP_ALL_BACKUPS_FOR_DAYS=7                  # Keep ALL backups
KEEP_DAILY_BACKUPS_FOR_DAYS=16               # Keep 1 per day
KEEP_WEEKLY_BACKUPS_FOR_WEEKS=8              # Keep Monday backup
KEEP_MONTHLY_BACKUPS_FOR_MONTHS=4            # Keep 1st of month
KEEP_YEARLY_BACKUPS_FOR_YEARS=2              # Keep Jan 1st
DELETE_OLDEST_WHEN_EXCEEDS_MB=5000           # Max storage
```

## Databases

| Driver | Port | Install Command |
|--------|------|-----------------|
| `mysql` | 3306 | `apt install mysql-client` or `brew install mysql-client` |
| `mariadb` | 3306 | `apt install mariadb-client` or `brew install mariadb` |
| `postgresql` | 5432 | `apt install postgresql-client` or `brew install postgresql` |

## S3 Providers (rclone)

### AWS S3
```bash
snapback setup-rclone
# Provider: AWS
# Access Key: AKIA...
# Secret Key: xxx
# Region: us-east-1
```

### DigitalOcean Spaces
```bash
snapback setup-rclone
# Provider: DigitalOcean
# Access Key: xxx
# Secret Key: xxx
# Endpoint: nyc3.digitaloceanspaces.com
```

### MinIO
```bash
snapback setup-rclone
# Provider: Minio
# Access Key: xxx
# Secret Key: xxx
# Endpoint: minio.local:9000
```

### Backblaze B2
```bash
snapback setup-rclone
# Provider: Other
# Access Key: xxx
# Secret Key: xxx
# Endpoint: s3.us-west-004.backblazeb2.com
```

## Retention Policy Explained

| Period | Keeps | Example |
|--------|-------|---------|
| **All** (7 days) | Every backup | Dec 1-7: all 7 backups |
| **Daily** (16 days) | 1 per day | Dec 8-23: 16 backups |
| **Weekly** (8 weeks) | Monday only | Nov: 4 Monday backups |
| **Monthly** (4 months) | 1st of month | Sep-Dec: 4 backups |
| **Yearly** (2 years) | Jan 1st only | 2023, 2024: 2 backups |
| **Size Limit** | 5000 MB | Delete oldest if exceeded |

**How it works:**
1. Script scans all backups in S3
2. Checks each backup against ALL retention rules
3. Keeps if ANY rule matches
4. Deletes only if NO rules match
5. Finally checks total size limit

## Cron Examples

```bash
snapback cron                     # Daily at 2 AM
snapback cron "0 */6 * * *"       # Every 6 hours
snapback cron "0 2,14 * * *"      # 2 AM and 2 PM
snapback cron "0 * * * *"         # Every hour
snapback cron "0 3 * * 0"         # Sunday 3 AM
```

## Webhook Notifications

Snapback supports webhook notifications for backup success/failure.

### Slack
```bash
WEBHOOK_URL="https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXX"
```

### Discord
```bash
WEBHOOK_URL="https://discord.com/api/webhooks/0000000000/XXXXXXXX"
```

### Generic Webhook
```bash
WEBHOOK_URL="https://your-server.com/webhook"
```

**Payload format (generic):**
```json
{
  "status": "success",
  "message": "Backup completed in 45s",
  "hostname": "server-01",
  "timestamp": "2025-12-04 02:00:00",
  "tool": "snapback"
}
```

## Restore

```bash
# List backups
snapback list

# Download
snapback download backup_mydb_2024-01-01_020000.zip

# Restore (prompts for confirmation)
snapback restore backup_mydb_2024-01-01_020000.zip my_database
```

**Manual restore:**
```bash
# Extract (with password)
unzip -P "your-password" backup_mydb_2024-01-01_020000.zip

# MySQL
mysql -u root -p my_database < mydb.sql

# PostgreSQL
psql -U postgres my_database < mydb.sql
```

## IAM Policy

```json
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
        "Resource": ["arn:aws:s3:::your-bucket", "arn:aws:s3:::your-bucket/*"]
    }]
}
```

## Logs

- **Root**: `/var/log/snapback.log`
- **User**: `~/.snapback/logs/backup.log`

## Updating

Snapback can update itself to the latest version:

```bash
# Check current version
snapback version

# Update to latest version
snapback update
```

The update command will:
1. Check the latest release from GitHub
2. Compare with your current version
3. Download and install the new version (with confirmation)

## Security

- **MySQL passwords** are passed via `--defaults-extra-file` (not visible in process list)
- **Lock file** prevents concurrent backup runs
- **Upload verification** ensures file integrity after upload
- **ZIP encryption** protects backup contents

## License

MIT
