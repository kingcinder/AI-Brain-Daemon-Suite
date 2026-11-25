#!/usr/bin/env bash
# organ-digest.sh — render a compact live digest of the helm's state.
# Stage 6, Item 6: this block is Juno's waking self-knowledge surface.
# It is copied into the Cathedral organs chapel, the day's memory note,
# and read by the self-improvement cycle. Read-only: never mutates state.
set -u
W="$HOME/.juno-brain/workspace"
PST=$(TZ=America/Los_Angeles date '+%Y-%m-%d %H:%M PST')
echo "## Organs — $PST"
python3 - "$W" <<'PY'
import json, os, sys, glob
W = sys.argv[1]
try:
    h = json.load(open(W + '/memory/helm-health.json'))
    print(f"- Queue: depth {h.get('queue_depth')}, deadletters {h.get('deadletter_count')}, oldest unacked {h.get('oldest_unacked_age_s')}")
except Exception as e:
    print(f"- Queue: health file unreadable ({e})")
pulse = open(W + '/memory/heartbeat-pulse.log').read().strip().splitlines()
print(f"- Last pulse: {pulse[-1] if pulse else 'none'}")
try:
    p = json.load(open(W + '/memory/pending-memories.json'))
    print(f"- Hippocampus: {len(p.get('pending', []))} signals pending encoding")
except Exception as e:
    print(f"- Hippocampus: pending unreadable ({e})")
try:
    idx = json.load(open(W + '/memory/index.json'))
    print(f"- Hippocampus index: {len(idx.get('memories', []))} memories encoded")
except Exception as e:
    print(f"- Hippocampus index: unreadable ({e})")
try:
    n = sum(1 for _ in open(os.path.expanduser('~/.openclaw/agents/main/sessions/juno-conversation.jsonl')))
    print(f"- Corpus: {n} messages (her conversations, converted)")
except Exception as e:
    print(f"- Corpus: unreadable ({e})")
states = sorted(glob.glob(W + '/*_STATE.md'))
print(f"- Organ state files present: {len(states)}")
try:
    es = json.load(open(W + '/memory/emotional-state.json'))
    d = es.get('dimensions', {})
    print("- Amygdala: " + ", ".join(f"{k} {v}" for k, v in d.items() if isinstance(v, (int, float))))
except Exception:
    pass
PY
