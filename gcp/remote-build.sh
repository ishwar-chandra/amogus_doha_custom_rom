#!/usr/bin/env bash
# Run ON the VM. Starts (or reattaches to) the build in tmux and waits.
set -euo pipefail

cd "$HOME/amogus_doha_custom_rom"
rm -f build.status

if tmux has-session -t doha 2>/dev/null; then
    echo "Build session already running; waiting for it..."
else
    echo "Starting build in tmux session 'doha'..."
    tmux new-session -d -s doha "set -o pipefail; INSTALL_DEPS=1 JOBS=\$(nproc) ./scripts/build.sh all 2>&1 | tee build.log; echo \$? > build.status"
fi

# Poll instead of tmux wait-for: a missed signal must not hang the SSH session.
while tmux has-session -t doha 2>/dev/null; do
    sleep 20
done

status="$(cat build.status 2>/dev/null || echo 1)"
echo "Build exit status: $status"
exit "$status"
