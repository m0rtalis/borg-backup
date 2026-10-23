repo := "teharez/borg-backup"
image := repo + ":latest"

build tag=image version="dev":
    docker build --build-arg "VERSION={{version}}" -t {{tag}} .

# Backup, prune, check and restore for files only, MariaDB, a prepare hook, a custom port and SQLite
verify: build
    ./test/verify {{image}}

# Verify and push X.Y.Z as X.Y.Z, X.Y, X and latest, then tag vX.Y.Z
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{version}}"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be X.Y.Z"; exit 1; }
    [[ "$(git branch --show-current)" == main ]] || { echo "Release from main"; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean"; exit 1; }
    latest="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
    [[ "$(printf '%s\n%s\n' "${latest#v}" "${version}" | sort -V | tail -n 1)" == "${version}" && "${latest#v}" != "${version}" ]] \
        || { echo "${version} is not newer than ${latest#v}"; exit 1; }
    minor="${version%.*}"
    tags=("${version}" "${minor}" "${minor%.*}" latest)
    just build "{{repo}}:${version}" "${version}"
    ./test/verify "{{repo}}:${version}"
    for tag in "${tags[@]:1}"; do
        docker tag "{{repo}}:${version}" "{{repo}}:${tag}"
    done
    for tag in "${tags[@]}"; do
        docker push "{{repo}}:${tag}"
    done
    git tag -a "v${version}" -m "v${version}"
    if git remote get-url origin >/dev/null 2>&1; then
        git push origin "v${version}"
    else
        echo "No origin remote, v${version} is local only"
    fi
