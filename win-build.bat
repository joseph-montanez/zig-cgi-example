docker compose stop apache
@REM rmdir /S /Q ".zig-cache"
@REM rmdir /S /Q "zig-out"
zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl -Ddeployment=local
docker compose start apache
