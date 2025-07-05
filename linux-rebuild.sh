docker compose down -v && sudo rm -rf .zig-cache zig-out && zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl -Ddeployment=local && docker compose build && docker compose up -d
