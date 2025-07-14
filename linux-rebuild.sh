docker compose stop && zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl -Ddeployment=local && docker compose build && docker compose up -d
