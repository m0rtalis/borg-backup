#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo "Both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

var_env() {
	local var="$1"
	local def="${2:-}"
	local val="${def}"
	if [ "${!var:-}" ]; then
		val="${!var}"
	fi
	export "${var}"="${val}"
}

docker_setup_borg_env() {
	var_env 'ARCHIVE_PREFIX'
	var_env 'ARCHIVE_BASENAME' "{now:%Y-%m-%dT%H:%M:%S}"
	export 'ARCHIVE'="${ARCHIVE_PREFIX}${ARCHIVE_BASENAME}"
	var_env 'RESTORE_ARCHIVE'

	export 'BORG_REPO'="/repo"
	export 'DATA'="/data"

	# Data created by scripts before backup, eg. sql dumps
	export 'OTHER_DATA'="/other_data"

	# Below this point set environment variables recognized by borg
	export 'BORG_CACHE_DIR'="/app/cache/borg"
	export 'BORG_CONFIG_DIR'="/app/config/borg"

	var_env 'BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK' "yes"
	var_env 'BORG_RELOCATED_REPO_ACCESS_IS_OK' "yes"
}

docker_setup_rclone_env() {
	var_env 'BUCKET_NAME' "backup-${HOSTNAME}"
	var_env 'REMOTE' "s3"

	export 'RCLONE_CONFIG'="/app/config/rclone/rclone.conf"
	if [[ ! -f ${RCLONE_CONFIG} ]]; then
		echo "Warning: No Rclone config found."
	fi
	file_env 'AWS_ACCESS_KEY_ID'
	file_env 'AWS_SECRET_ACCESS_KEY'
}

docker_setup_mysql_env() {
	# Do not set default value for MYSQL_HOST.
	# We use it to determine if a backup should be made.
	var_env 'MYSQL_HOST'
	var_env 'MYSQL_PORT' 3306
	file_env 'MYSQL_ROOT_PASSWORD'
	var_env 'MYSQL_DATABASE'
}

docker_setup_postgres_env() {
	# Do not set default value for POSTGRES_HOST.
	# We use it to determine if a backup should be made.
	var_env 'POSTGRES_HOST'
	var_env 'POSTGRES_PORT' 5432
	file_env 'POSTGRES_USER' 'postgres'
	file_env 'POSTGRES_PASSWORD'

}

create_cronjob() {
	var_env 'CRON_BACKUP' "0 2 * * *"
	var_env 'CRON_PRUNE' "0 4 * * *" 
	var_env 'CRON_CHECK' "0 6 * * 5"
	declare -p | grep -Ev 'BASHOPTS|BASH_VERSINFO|EUID|PPID|SHELLOPTS|UID|affinity' > /container.env
	cat > /etc/cron.d/start <<- EOF
SHELL=/bin/bash
BASH_ENV=/container.env

${CRON_BACKUP} root backup >> /proc/1/fd/1 2>&1
${CRON_PRUNE} root prune >> /proc/1/fd/1 2>&1
${CRON_CHECK} root check >> /proc/1/fd/1 2>&1
# Empty line
EOF
  chmod 0644 /etc/cron.d/start
  chown root:root /etc/cron.d/start
}

main() {
	docker_setup_borg_env
	docker_setup_rclone_env
	docker_setup_mysql_env
	docker_setup_postgres_env
	create_cronjob

	exec "$@"
}

main "$@"
