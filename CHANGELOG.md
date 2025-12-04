# Changelog

All notable changes to Snapback will be documented in this file.

## [1.0.0] - 2025-12-04

### Added
- **Single ZIP backup structure** - Creates one ZIP with `Databases/` and `Files/` folders
- **Multi-database support** - Backup multiple databases in one archive
- **Auto-discover all databases** - Use `DB_MULTIPLE="*"` to backup all databases
- **Interactive configure wizard** - `snapback configure` for easy setup
- **S3-compatible storage support** - AWS, DigitalOcean Spaces, Minio, etc.
- **Password-protected ZIP** - Encrypt backups with ZIP password
- **Upload verification** - Verify file integrity after upload
- **Smart retention policy** - Daily, weekly, monthly, yearly retention
- **Webhook notifications** - Slack, Discord, or custom webhook support
- **MySQL/MariaDB support** - With auto-detection of supported options
- **PostgreSQL support** - Full pg_dump integration
- **Cron scheduling** - Easy cron setup with custom schedules
- **Self-update** - `snapback update` to get latest version

### Fixed
- MySQL credentials now use temp file (macOS compatible)
- mysqldump options auto-detect (`--events`, `--set-gtid-purged`, `--no-tablespaces`)
- `no_check_bucket=true` for S3-compatible providers (DigitalOcean, Minio)
- `check_deps` exit code bug causing silent script termination
- Human-readable file sizes cross-platform support

### Security
- Database passwords not visible in process list
- Credentials stored in temp files with 600 permissions
- Temp files cleaned up on exit
