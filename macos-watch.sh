while true; do
    find src build.zig \( -name '*.zig' -o -name '*.zon' \) | \
    entr -d -c zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl
    echo "entr exited. Restarting watcher..." # Optional: message indicating restart
    sleep 0.25
done