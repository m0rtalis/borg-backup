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

The Borg repo is created on first backup (`repokey` encryption, zlib compression). Cron output goes to the container log.

## Volumes

| Path | Purpose |
| --- | --- |
| `/data` | Data to back up (mount read-only if you like) |
| `/repo` | Borg repository. Persist it. |
| `/app` | Borg cache/config (`/app/cache/borg`, `/app/config/borg`) and optional hooks (`/app/prepare`). Persist it. |

Database dumps are written to `/other_data` and archived together with `/data`. `/other_data` is wiped on every backup.

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

### S3 / rclone

| Variable | Default | Description |
| --- | --- | --- |
| `REMOTE` | `s3` | rclone remote name |
| `RCLONE_CONFIG` | `/etc/rclone/rclone.conf` | rclone config. The baked-in one is AWS, `eu-central-1`, `ONEZONE_IA`, credentials from env. |
| `AWS_ACCESS_KEY_ID` (*file*) | | S3 credentials |
| `AWS_SECRET_ACCESS_KEY` (*file*) | | S3 credentials |

To use another region or provider, mount your own config and point `RCLONE_CONFIG` at it. It must not live under `/app`, which is a volume.

### Databases

A database is only backed up if its `*_HOST` is set.

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

PostgreSQL uses `pg_dumpall` (all databases); MySQL dumps only `MYSQL_DATABASE`. Clients are MariaDB (`MARIADB_VERSION` in the `Dockerfile`) and PostgreSQL 15.

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

Individual steps: `backup-borg`, `backup-mysql`, `backup-postgresql`, `sync-rclone`, each taking `backup` (and `restore`, plus `prune`/`check` for `backup-borg`).

## Restore

```sh
# 1. Only if the local /repo is empty or lost: pull it from S3
docker exec <container> sync-rclone restore

# 2. Restore the latest archive (or set RESTORE_ARCHIVE), then re-import dumps
docker exec -it <container> restore
```

`restore` asks for confirmation, runs the `prepare` hooks, extracts the archive to `/` (overwriting `/data`), then loads the PostgreSQL and MySQL dumps into the configured servers. The S3 download is deliberately not part of `restore` because of transfer costs, so do step 1 manually.

## Build

Requires [just](https://github.com/casey/just).

```sh
just build           # docker build
just verify          # build + backup/prune/check/restore against throwaway MariaDB containers
just release 1.2.0   # verify, push 1.2.0, 1.2, 1 and latest, tag v1.2.0
```

`just verify` is self-contained (Docker only). It covers files only, MariaDB, MariaDB with a `prepare` hook and a custom `MYSQL_PORT`, with rclone writing to a local remote instead of S3. Its sample env file and hook are in `test/config`.

Versions are SemVer for the image interface (env vars, volumes, scripts, behavior): major for breaking changes, minor for features and tool upgrades, patch for fixes. The version is in the `org.opencontainers.image.version` label. Pin consumers to a minor tag such as `1.2`, not `latest`.

Borg and rclone are downloaded with signature checks; bump `BORG_VERSION` / `RCLONE_VERSION` in the `Dockerfile` to upgrade. Image is `linux/amd64` only.
