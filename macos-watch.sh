#!/bin/bash

while true; do
    # Find files: Added css and js from previous discussion
    find src build.zig build.zig.zon \( -name '*.zig' -o -name '*.zon' -o -name '*.html' -o -name '*.css' -o -name '*.js' \) | \
    entr -d -c sh -c ' \
        echo "[Running Docker Restart & Zig Build ($DOCKER_SERVICE_NAME)]" && \
        docker compose restart apache && \
        zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl -Ddeployment=local && \
        echo "[Commands Finished Successfully]" || \
        echo "[Command Sequence Failed]"'

    # Add exit code $? to the message for debugging
    echo "entr exited ($?). Restarting watcher..."
    sleep 0.25
done