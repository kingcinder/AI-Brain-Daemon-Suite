# legacy/ — superseded bash daemon

`brain-daemon.sh` was the first working scheduling engine for this suite —
it's fully debugged (job-table paths verified, PSI backpressure ported from
the original prototype, `set -e`/quoting bugs fixed) and still runs
correctly. It has been **superseded**, not deleted, by `deep-brain-kernel.py`
at the suite root, which does everything this version does plus:

- Real epoll-based PSI monitoring (interrupt-driven, zero polling) instead of
  a 30-second `avg10` read loop
- GPU VRAM checking (`nvidia-smi`/`rocm-smi`) so spawn-type jobs defer when
  your local inference is actually using the GPU — the bash version had no
  visibility into GPU load at all, only system memory/CPU
- cgroups v2 CPU throttling under detected pressure, via systemd delegation
- Race-free process tracking and shutdown (`pidfd_send_signal` instead of
  bash job control)
- Single-instance locking, so two copies can't accidentally run at once

Use this folder only if you need to roll back — e.g. `deep-brain-kernel.py`
turns out to need a kernel/systemd feature your machine doesn't have (PSI or
cgroup v2 delegation missing). If you do roll back:

```bash
systemctl --user stop aibrain.service
systemctl --user disable aibrain.service
cp legacy/brain-daemon.sh ~/.openclaw/workspace/brain-daemon.sh
cp legacy/aibrain.service.bash-legacy ~/.config/systemd/user/aibrain.service
chmod +x ~/.openclaw/workspace/brain-daemon.sh legacy/install.sh.bash-legacy
systemctl --user daemon-reload
systemctl --user enable --now aibrain.service
```

Note: even without PSI/cgroups, `deep-brain-kernel.py` still runs correctly —
it just logs a warning and disables that one piece of pressure-based
deferral, rather than failing. Rollback should rarely be necessary in practice.
