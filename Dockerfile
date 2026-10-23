FROM debian:bookworm AS builder

# https://github.com/borgbackup/borg/releases/
ARG BORG_VERSION="1.4.3"
ARG BORG_GPG="9F88FB52FAF7B393"

# https://rclone.org/release_signing/
ARG RCLONE_VERSION="v1.72.1"
ARG RCLONE_GPG="FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA"

# https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/installing-mariadb/binary-packages/gpg#mariadb-community-server-debian-ubuntu-key
ARG MARIADB_GPG="177F4010FE56CA3336300305F1656F24C74CD1D8"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
    && apt-get install -y -qq wget unzip gpg \
    && rm -rf /var/lib/apt/lists/*

# Install borg
RUN wget -q -O /borg "https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/borg-linux-glibc231-x86_64" \
    && wget -q -O /borg.asc "https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/borg-linux-glibc231-x86_64.asc" \
    && gpg --recv-keys "${BORG_GPG}" \
    && gpg --verify /borg.asc /borg \
    && chmod 755 /borg

# Install rclone
RUN wget -q -O "rclone-${RCLONE_VERSION}-linux-amd64.zip" "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip" \
    && wget -q -O rclone-sha265 "https://downloads.rclone.org/${RCLONE_VERSION}/SHA256SUMS" \
    && gpg --keyserver keyserver.ubuntu.com --recv-keys "${RCLONE_GPG}" \
    && gpg --verify --trust-model always rclone-sha265 \
    && sha256sum --check --ignore-missing rclone-sha265 2>&1 | grep "rclone-${RCLONE_VERSION}-linux-amd64.zip: OK"\
    && unzip -q "rclone-${RCLONE_VERSION}-linux-amd64.zip" \
    && cd rclone-${RCLONE_VERSION}-linux-amd64 \
    && cp rclone /rclone \
    && chmod 755 /rclone

# Prepare mariadb repo
RUN wget -q -O /mariadb.asc "https://supplychain.mariadb.com/MariaDB-Server-GPG-KEY" \
    && test "$(gpg --show-keys --with-colons /mariadb.asc | awk -F: '/^pub/ {n++} /^fpr/ && !f {f=$10} END {print n ":" f}')" = "1:${MARIADB_GPG}"

# Prepare postgres repo
RUN wget -q -O /pgdg.asc "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /pgdg.list

FROM debian:bookworm
LABEL "maintainer"="Fabian Eisinger"

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# MariaDB client series, https://mariadb.org/mariadb/all-releases/
ARG MARIADB_VERSION="12.3"

# signed-by instead of trusted.gpg.d: a key there is trusted for every repository
COPY --from=builder /pgdg.asc /mariadb.asc /usr/share/keyrings/
COPY --from=builder /pgdg.list /etc/apt/sources.list.d/

RUN apt-get update \
    && apt-get install -y --no-install-recommends -qq \
	   ca-certificates \
	   cron \
	   tzdata \
	   curl \
	   sqlite3 \
    && update-ca-certificates \
    && echo "deb [signed-by=/usr/share/keyrings/mariadb.asc] https://dlm.mariadb.com/repo/mariadb-server/${MARIADB_VERSION}/repo/debian bookworm main" > /etc/apt/sources.list.d/mariadb.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends -qq \
	   mariadb-client=1:${MARIADB_VERSION}.* \
       mariadb-client-core=1:${MARIADB_VERSION}.* \
       mariadb-common=1:${MARIADB_VERSION}.* \
       libmariadb3=1:${MARIADB_VERSION}.* \
	   postgresql-client-15 \
	&& rm -rf /var/lib/apt/lists/*


COPY --from=builder /borg /rclone /usr/bin/
COPY ./entrypoint.sh / 
COPY ./scripts/ /usr/local/bin/ 
COPY ./rclone.conf /etc/rclone/rclone.conf
RUN chmod +x /entrypoint.sh \
	&& chmod --recursive +x "/usr/local/bin"

VOLUME [ "/data", "/repo", "/app" ]

CMD ["cron", "-f"]
ENTRYPOINT ["/entrypoint.sh"]

# Last, so a new version does not invalidate the cache of the layers above
ARG VERSION="dev"
LABEL "org.opencontainers.image.version"="${VERSION}"
