image := "teharez/borg-backup:latest"

# Run the compose test stack
test:
    docker compose --profile test up --build --abort-on-container-exit backup

build:
    docker build -t {{image}} .

push: build
    docker push {{image}}
