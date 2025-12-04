# Snapback

Database & Files backup to S3 with encryption and smart retention.

## Install

```bash
curl -sL https://raw.githubusercontent.com/iqbalhasandev/snapback/main/install.sh | sudo bash
```

## Quick Start

```bash
snapback configure      # Interactive setup wizard
snapback setup-rclone   # Setup S3 credentials
snapback test           # Test connections
snapback backup         # Run backup
snapback cron           # Setup daily cron (2 AM)
```

## Commands

| Command | Description |
|---------|-------------|
| `snapback configure` | Interactive configuration wizard |
| `snapback backup` | Full backup (db + files) |
| `snapback backup-db` | Database backup only |
| `snapback backup-files` | Files backup only |
| `snapback list` | List backups in S3 |
| `snapback download <file>` | Download backup |
| `snapback restore <file>` | Restore database |
| `snapback cleanup` | Apply retention policy |
| `snapback test` | Test connections |
| `snapback config` | Show config |
| `snapback edit` | Edit config |
| `snapback cron` | Setup daily cron (2 AM) |
| `snapback cron "0 */6 * * *"` | Custom cron schedule |
| `snapback setup-rclone` | Setup rclone S3 remote |
| `snapback init` | Create default config |
| `snapback update` | Update to latest version |
| `snapback version` | Show version |

## Dependencies

```bash
# Ubuntu/Debian
apt install rclone zip jq mysql-client

# macOS
brew install rclone zip jq mysql-client
```

## Config Location

- **Root**: `/etc/snapback/config.conf`
- **User**: `~/.snapback/config.conf`

## License

MIT
