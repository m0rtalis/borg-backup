FROM debian:bookworm AS builder

# https://github.com/borgbackup/borg/releases/
ARG BORG_VERSION="1.4.3"
ARG BORG_GPG="9F88FB52FAF7B393"

# https://rclone.org/release_signing/
ARG RCLONE_VERSION="v1.72.1"
ARG RCLONE_GPG="FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA"

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

# Prepare postgres repo
RUN wget -q -O /pgdg.asc "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
    && echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /pgdg.list

FROM debian:bookworm
LABEL "maintainer"="Fabian Eisinger"

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

COPY --from=builder /pgdg.asc /etc/apt/trusted.gpg.d/
COPY --from=builder /pgdg.list /etc/apt/sources.list.d/

COPY --chmod=+x mariadb_repo_setup /tmp/mariadb_repo_setup

RUN apt-get update \
    && apt-get install -y --no-install-recommends -qq \
	   ca-certificates \
	   cron \
	   tzdata \
	   curl \
    && update-ca-certificates \
    && ./tmp/mariadb_repo_setup --mariadb_server_version="10.11" --include-tools --skip-maxscale \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends -qq \
	   mariadb-client=1:10.11* \
       mariadb-client-core=1:10.11* \
       mariadb-common=1:10.11* \
       libmariadb3=1:10.11* \
	   postgresql-client-15 \
	&& rm -rf /var/lib/apt/lists/*


COPY --from=builder /borg /rclone /usr/bin/
COPY ./entrypoint.sh / 
COPY ./scripts/ /usr/local/bin/ 
COPY ./rclone.conf /app/config/rclone/rclone.conf
RUN chmod +x /entrypoint.sh \
	&& chmod --recursive +x "/usr/local/bin"

VOLUME [ "/data", "/repo", "/app" ]

CMD ["cron", "-f"]
ENTRYPOINT ["/entrypoint.sh"]
