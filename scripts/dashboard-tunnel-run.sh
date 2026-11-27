#!/bin/bash
# dashboard-tunnel-run.sh — foreground owner of the Brain Dashboard
# reverse tunnel, run under aibrain-dashboard-tunnel.service
# (Restart=always). One start does, in order:
#   1. REAL_PC identity probe over route 1 (fail = exit; systemd retries)
#   2. codypc 127.0.0.1:18123 already serving 200 -> monitor it; exit
#      when it stops, so systemd relaunches us as the tunnel's owner
#   3. 18123 bound but not serving -> kill the stale listener PID(s) on
#      codypc (only those PIDs — a dead tunnel's leftover sshd children)
#   4. exec ssh -N -R — this process BECOMES the tunnel; systemd owns it
# History: 2026-11-25→27 the tunnel was an unsupervised setsid+nohup ssh;
# every route-1 flap killed it and nothing relaunched it until the
# 30-minute heartbeat card noticed, and the doctor's re-open could be
# vetoed by a stale codypc listener or its own broken server rung.
set -u
SSH_PC="$HOME/workspace/bin/ssh-codypc"
GUARD='grep -q "Ryzen 7 3700X" /proc/cpuinfo && test -d /home/cody/Documents/nvr-emulator && [ "$(hostname)" = "a1" ]'
CODE_CMD='curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:18123/ || true'

OUT=$("$SSH_PC" "$GUARD && echo REAL_PC" 2>/dev/null)
if [ "$OUT" != "REAL_PC" ]; then
  echo "$(date -Is) identity probe failed ('$OUT') — route 1 down or wrong machine; exiting for systemd retry"
  exit 1
fi

CODE=$("$SSH_PC" "$CODE_CMD" 2>/dev/null)
if [ "$CODE" = "200" ]; then
  echo "$(date -Is) codypc 18123 already serving — monitoring the existing forward"
  while [ "$CODE" = "200" ]; do
    sleep 30
    CODE=$("$SSH_PC" "$CODE_CMD" 2>/dev/null)
  done
  echo "$(date -Is) existing forward stopped serving ('$CODE') — exiting so systemd relaunches us as owner"
  exit 1
fi

# The stale listener is held by a root-owned sshd process, so an
# unprivileged ss cannot even see its PID (first live attempt proved
# this: empty PID list, then "remote port forwarding failed"). Cody
# has passwordless sudo on codypc — use it for the probe and the kill.
PIDS=$("$SSH_PC" "sudo -n ss -ltnp 'sport = :18123' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | tr '\n' ' '" 2>/dev/null)
if [ -n "${PIDS// /}" ]; then
  echo "$(date -Is) clearing stale listener(s) on codypc 18123: $PIDS"
  "$SSH_PC" "sudo -n kill $PIDS 2>/dev/null; sleep 1; true" 2>/dev/null
fi

echo "$(date -Is) launching tunnel (exec ssh -N -R 127.0.0.1:18123:127.0.0.1:8123)"
exec ssh \
  -o ProxyCommand="python3 $HOME/workspace/bin/tailscale-ssh-proxy.py %h %p" \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts_codypc" \
  -o StrictHostKeyChecking=accept-new \
  -i "$HOME/.ssh/id_ed25519" \
  -o BatchMode=yes \
  -o ConnectTimeout=30 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -N -R 127.0.0.1:18123:127.0.0.1:8123 \
  cody@100.72.92.81
