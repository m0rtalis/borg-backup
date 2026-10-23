# borg-backup

Docker image that backs up a data directory (and optionally a MariaDB/MySQL and a PostgreSQL database) into a [Borg](https://www.borgbackup.org/) repository and mirrors that repository to S3 with [rclone](https://rclone.org/). Backup, prune and check run on cron schedules inside the container.

Image: `teharez/borg-backup:latest`

## What it does

| Job | Default schedule | Steps |
| --- | --- | --- |
| `backup` | `0 2 * * *` | run `/app/prepare/*` hooks, dump databases, `borg create`, `rclone sync` to S3 |
| `prune` | `0 4 * * *` | `borg prune` + `borg compact`, `rclone sync` to S3 |
| `check` | `0 6 * * 5` | `borg check` |

Retention: everything within 5 hours, last 3, 5 daily, 4 weekly, 3 monthly, 2 yearly.

`rclone sync` makes the bucket equal to the local repo, so the sync refuses to run when the repo in `/repo` has a different ID than the one in the bucket (e.g. an empty `/repo` mount that was initialised from scratch). Empty the bucket first if the repo was replaced on purpose. Borg warnings (exit code 1, e.g. a file changed while it was read) are logged and do not skip the sync; errors do.

Borg stores and restores numeric uid/gid (`--numeric-ids`), so files come back with the owner they had when they were backed up, independent of the users in this container. Set `RESTORE_UID` and/or `RESTORE_GID` to restore everything under a different owner.

The Borg repo is created on first backup (`repokey` encryption, zlib compression). Cron output goes to the container log.

## Volumes

| Path | Purpose |
| --- | --- |
| `/data` | Data to back up (mount read-only if you like, unless it holds a database listed in `SQLITE_FILES`) |
| `/repo` | Borg repository. Persist it. |
| `/app` | Borg cache/config (`/app/cache/borg`, `/app/config/borg`) and optional hooks (`/app/prepare`). Persist it. |

Database dumps and SQLite copies are written to `/other_data` and archived together with `/data`. `/other_data` is wiped on every backup.

## Quick start

```yaml
services:
  backup:
    image: teharez/borg-backup:latest
    hostname: backup
    environment:
      BUCKET_NAME: my-backup-bucket
      BORG_PASSPHRASE_FILE: /run/secrets/borg_passphrase
      AWS_ACCESS_KEY_ID_FILE: /run/secrets/aws_key_id
      AWS_SECRET_ACCESS_KEY_FILE: /run/secrets/aws_secret
      POSTGRES_HOST: postgres
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
      MYSQL_HOST: mariadb
      MYSQL_DATABASE: app
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/mysql_root_password
    volumes:
      - ./data:/data:ro
      - borg-repo:/repo
      - borg-app:/app
    secrets: [borg_passphrase, aws_key_id, aws_secret, pg_password, mysql_root_password]
```

> **SQLite:** `SQLITE_FILES` databases need `/data` mounted read-write (drop the `:ro`).

> **Borg passphrase:** one of `BORG_PASSPHRASE`, `BORG_PASSPHRASE_FILE` (exclusive) or `BORG_PASSCOMMAND` is required; the container refuses to start without one.

## Environment variables

Variables marked *file* also accept a `<NAME>_FILE` variant (Docker secrets). Setting both is an error.

### General

| Variable | Default | Description |
| --- | --- | --- |
| `BUCKET_NAME` | **required** | S3 bucket for the repo mirror. No default on purpose: the hostname changes on container recreate. |
| `CRON_BACKUP` | `0 2 * * *` | Backup schedule |
| `CRON_PRUNE` | `0 4 * * *` | Prune schedule |
| `CRON_CHECK` | `0 6 * * 5` | Check schedule |
| `ARCHIVE_PREFIX` | empty | Prefix for archive names. Prune and restore only touch archives with this prefix. |
| `ARCHIVE_BASENAME` | `{now:%Y-%m-%dT%H:%M:%S}` | Borg archive name template |
| `RESTORE_ARCHIVE` | latest | Archive to restore (full name incl. prefix) |
| `RESTORE_UID` | empty | Owner of the restored files. Default: the uid stored in the archive. |
| `RESTORE_GID` | empty | Group of the restored files. Default: the gid stored in the archive. |
| `EXCLUDE` | empty | Space separated Borg patterns, each passed as `--exclude`, e.g. `pf:/data/mail sh:/data/**/*.tmp`. Patterns cannot contain spaces. |
| `EXCLUDE_IF_PRESENT` | empty | Space separated file names, each passed as `--exclude-if-present`. Directories containing one are skipped. |

### S3 / rclone

| Variable | Default | Description |
| --- | --- | --- |
| `REMOTE` | `s3` | rclone remote name |
| `RCLONE_CONFIG` | `/etc/rclone/rclone.conf` | rclone config. The baked-in one is AWS, `eu-central-1`, `ONEZONE_IA`, credentials from env. |
| `AWS_ACCESS_KEY_ID` (*file*) | | S3 credentials |
| `AWS_SECRET_ACCESS_KEY` (*file*) | | S3 credentials |

To use another region or provider, mount your own config and point `RCLONE_CONFIG` at it. It must not live under `/app`, which is a volume.

### Databases

A database is only backed up if its `*_HOST` (or, for SQLite, `SQLITE_FILES`) is set.

| Variable | Default | Description |
| --- | --- | --- |
| `MYSQL_HOST` | | MariaDB/MySQL host |
| `MYSQL_PORT` | `3306` | Non-numeric values (e.g. Kubernetes `tcp://...`) fall back to the default with a warning |
| `MYSQL_DATABASE` | | Database to dump. Required when `MYSQL_HOST` is set. |
| `MYSQL_ROOT_PASSWORD` (*file*) | | Password for user `root` |
| `POSTGRES_HOST` | | PostgreSQL host |
| `POSTGRES_PORT` | `5432` | Same fallback as `MYSQL_PORT` |
| `POSTGRES_USER` (*file*) | `postgres` | |
| `POSTGRES_PASSWORD` (*file*) | | |
| `SQLITE_FILES` | | Space separated absolute paths of SQLite databases, e.g. `/data/app.db /data/mail/main.db`. No spaces or single quotes in paths. |

PostgreSQL uses `pg_dumpall` (all databases); MySQL dumps only `MYSQL_DATABASE`. Clients are MariaDB (`MARIADB_VERSION` in the `Dockerfile`) and PostgreSQL 15.

SQLite databases are copied with `sqlite3 .backup`, which is consistent while the application keeps writing, to the same path below `/other_data/sqlite`. The directory of a database must be mounted read-write, because SQLite creates files next to it; a read-only mount fails the backup, as does a listed path that is not a file. A large database that is written to constantly can make the copy slow, because it restarts when another connection writes between its steps.

The live database file (and its `-wal`/`-shm` files) is archived under `/data` as well. To keep it out of the archive, exclude it: `EXCLUDE=pf:/data/app.db pf:/data/app.db-wal pf:/data/app.db-shm`.

`restore` copies the SQLite copy over the original path and removes stale `-wal`, `-shm` and `-journal` files. Stop the application that uses the database first, e.g. in a `prepare` hook, and make sure the directory of the database exists.

### Borg

Any [Borg environment variable](https://borgbackup.readthedocs.io/en/stable/usage/general.html#environment-variables) works. Defaults set here:

| Variable | Default |
| --- | --- |
| `BORG_PASSPHRASE` (*file*) | one of this or `BORG_PASSCOMMAND` required |
| `BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK` | `yes` |
| `BORG_RELOCATED_REPO_ACCESS_IS_OK` | `yes` |

## Hooks

Executable files in `/app/prepare/` are **sourced** (not executed) with `backup` or `restore` as `$1` before database handling. Use them for e.g. stopping a service or dumping something custom into `$OTHER_DATA`.

## Manual runs

```sh
docker exec <container> backup   # full backup + upload
docker exec <container> prune
docker exec <container> check
```

Individual steps: `backup-borg`, `backup-mysql`, `backup-postgresql`, `backup-sqlite`, `sync-rclone`, each taking `backup` (and `restore`, plus `prune`/`check` for `backup-borg`).

## Restore

```sh
# 1. Only if the local /repo is empty or lost: pull it from S3
docker exec <container> sync-rclone restore

# 2. Restore the latest archive (or set RESTORE_ARCHIVE), then re-import dumps
docker exec -it <container> restore
```

`restore` asks for confirmation, runs the `prepare` hooks, extracts the archive to `/` (overwriting `/data`), copies the SQLite databases back, then loads the PostgreSQL and MySQL dumps into the configured servers. The S3 download is deliberately not part of `restore` because of transfer costs, so do step 1 manually.

## Build

Requires [just](https://github.com/casey/just).

```sh
just build           # docker build
just verify          # build + backup/prune/check/restore against throwaway MariaDB containers
just release 1.2.0   # verify, push 1.2.0, 1.2, 1 and latest, tag v1.2.0
```

`just verify` is self-contained (Docker only). It covers files only, MariaDB, MariaDB with a `prepare` hook and a custom `MYSQL_PORT`, and SQLite, with rclone writing to a local remote instead of S3. Its sample env file and hook are in `test/config`.

Versions are SemVer for the image interface (env vars, volumes, scripts, behavior): major for breaking changes, minor for features and tool upgrades, patch for fixes. The version is in the `org.opencontainers.image.version` label. Pin consumers to a minor tag such as `1.2`, not `latest`.

Borg and rclone are downloaded with signature checks; bump `BORG_VERSION` / `RCLONE_VERSION` in the `Dockerfile` to upgrade. Image is `linux/amd64` only.
