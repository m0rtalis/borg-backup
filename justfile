image := "teharez/borg-backup:latest"

build:
    docker build -t {{image}} .

push: build
    docker push {{image}}
