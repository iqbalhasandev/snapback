# Snapback

Database & Files backup to S3-compatible storage with encryption and smart retention.

## Features

- **Single ZIP backup** with organized folder structure (`Databases/` + `Files/`)
- **Multi-database support** - backup specific databases or ALL databases with `*`
- **S3-compatible** - AWS, DigitalOcean Spaces, Minio, etc.
- **Password encryption** - ZIP files with password protection
- **Smart retention** - daily, weekly, monthly, yearly policies
- **Webhook notifications** - Slack, Discord, or custom webhooks
- **MySQL/MariaDB & PostgreSQL** support

## Install

```bash
# As root (system-wide)
curl -sL https://raw.githubusercontent.com/iqbalhasandev/snapback/main/install.sh | sudo bash

# As user (~/bin)
curl -sL https://raw.githubusercontent.com/iqbalhasandev/snapback/main/install.sh | bash
```

## Quick Start

```bash
snapback configure      # Interactive setup wizard
snapback test           # Test connections
snapback backup         # Run backup
snapback cron           # Setup daily cron (2 AM)
```

## Commands

| Command | Description |
|---------|-------------|
| `snapback configure` | Interactive configuration wizard |
| `snapback backup` | Full backup (db + files) → single ZIP |
| `snapback backup-db` | Database backup only |
| `snapback backup-files` | Files backup only |
| `snapback list` | List backups in S3 |
| `snapback download <file>` | Download backup |
| `snapback restore <file>` | Restore database |
| `snapback cleanup` | Apply retention policy |
| `snapback test` | Test connections |
| `snapback config` | Show current config |
| `snapback edit` | Edit config file |
| `snapback cron [schedule]` | Setup cron (default: 2 AM daily) |
| `snapback setup-rclone` | Setup rclone S3 remote |
| `snapback update` | Update to latest version |
| `snapback version` | Show version |

## Backup Structure

```
backup_2025-12-04_070152.zip
├── Databases/
│   ├── app_db.sql
│   ├── users_db.sql
│   └── logs_db.sql
└── Files/
    └── files.tar
```

## Database Options

```bash
# Single database
DB_NAME="myapp"
DB_MULTIPLE=""

# Multiple specific databases
DB_MULTIPLE="db1,db2,db3"

# ALL databases (auto-discovery)
DB_MULTIPLE="*"
```

## Dependencies

```bash
# Ubuntu/Debian
apt install rclone zip jq mysql-client

# macOS
brew install rclone zip jq mysql-client

# PostgreSQL (optional)
apt install postgresql-client  # or: brew install postgresql
```

## Config Location

| Install | Config Path |
|---------|-------------|
| Root | `/etc/snapback/config.conf` |
| User | `~/.snapback/config.conf` |

## S3 Providers

Works with any S3-compatible storage:
- AWS S3
- DigitalOcean Spaces
- Minio
- Backblaze B2
- Wasabi
- Cloudflare R2

## License

[MIT License](LICENSE.md)
