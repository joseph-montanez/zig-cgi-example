docker compose stop apache
zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl -Ddeployment=local
docker compose start apache