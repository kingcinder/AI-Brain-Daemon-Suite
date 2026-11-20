#!/usr/bin/env bash
# generate-dashboard.sh — Generate unified Brain Dashboard (all 7 modules)
# All generate-dashboard.sh scripts in the suite are identical except for
# ACTIVE_TAB (which tab is highlighted on open) and the required state check.
# Whichever module's cron runs last, the output is always the same.

set -e

# JUNO-BC-PATH (2026-11-15, Dither-ordered): cron env lacks interactive PATH; bc lives in home.
export PATH="$HOME/.juno-brain/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
command -v bc >/dev/null 2>&1 || ln -sf "$HOME/.juno-brain/bin/bc" /usr/local/bin/bc 2>/dev/null || true

WORKSPACE="${WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
OUTPUT_FILE="$WORKSPACE/brain-dashboard.html"

# ── State file paths ──────────────────────────────────────────────────────────
HIPPOCAMPUS_FILE="$WORKSPACE/memory/index.json"
AMYGDALA_FILE="$WORKSPACE/memory/emotional-state.json"
VTA_FILE="$WORKSPACE/memory/reward-state.json"
BASAL_FILE="$WORKSPACE/memory/habit-state.json"
INSULA_FILE="$WORKSPACE/memory/interoceptive-state.json"
ACC_CONFLICT_FILE="$WORKSPACE/memory/conflict-state.json"
ACC_ERROR_FILE="$WORKSPACE/memory/acc-state.json"

# ── Detect installed modules ──────────────────────────────────────────────────
HAS_HIPPOCAMPUS=false; HAS_AMYGDALA=false; HAS_VTA=false; HAS_BASAL=false
HAS_INSULA=false; HAS_ACC_CONFLICT=false; HAS_ACC_ERROR=false

[ -f "$HIPPOCAMPUS_FILE" ]  && HAS_HIPPOCAMPUS=true
[ -f "$AMYGDALA_FILE" ]     && HAS_AMYGDALA=true
[ -f "$VTA_FILE" ]          && HAS_VTA=true
[ -f "$BASAL_FILE" ]        && HAS_BASAL=true
[ -f "$INSULA_FILE" ]       && HAS_INSULA=true
[ -f "$ACC_CONFLICT_FILE" ] && HAS_ACC_CONFLICT=true
[ -f "$ACC_ERROR_FILE" ]    && HAS_ACC_ERROR=true

REQUIRED_CHECK="$HAS_BASAL"
if [ "$REQUIRED_CHECK" != "true" ]; then
  echo "❌ Required module not installed. Run ./install.sh first." >&2
  exit 1
fi

# ── Identity ──────────────────────────────────────────────────────────────────
AGENT_NAME="Agent"; AVATAR_PATH=""
if [ -f "$WORKSPACE/IDENTITY.md" ]; then
  AGENT_NAME=$(grep -E "^\*\*Name:\*\*|^- \*\*Name:\*\*" "$WORKSPACE/IDENTITY.md" | head -1 | sed 's/.*Name:\*\* *//' | sed 's/`//g' | tr -d '\r')
  AVATAR_RAW=$(grep -E "^\*\*Avatar:\*\*|^- \*\*Avatar:\*\*" "$WORKSPACE/IDENTITY.md" | head -1 | sed 's/.*Avatar:\*\* *//' | sed 's/`//g' | tr -d '\r')
  if [ -n "$AVATAR_RAW" ]; then
    [[ "$AVATAR_RAW" == /* ]] || [[ "$AVATAR_RAW" == ~/* ]] && AVATAR_PATH="${AVATAR_RAW/#\~/$HOME}" || AVATAR_PATH="$WORKSPACE/$AVATAR_RAW"
  fi
fi
[ -z "$AGENT_NAME" ] && AGENT_NAME="Agent"
if [ -z "$AVATAR_PATH" ] || [ ! -f "$AVATAR_PATH" ]; then
  for c in "$WORKSPACE/avatar.png" "$WORKSPACE/avatar.jpg"; do [ -f "$c" ] && AVATAR_PATH="$c" && break; done
fi
AVATAR_BASE64=""
if [ -n "$AVATAR_PATH" ] && [ -f "$AVATAR_PATH" ]; then
  MIME="image/png"; [[ "$AVATAR_PATH" == *.jpg || "$AVATAR_PATH" == *.jpeg ]] && MIME="image/jpeg"
  AVATAR_BASE64="data:$MIME;base64,$(base64 < "$AVATAR_PATH" | tr -d '\n')"
fi

# ── Hippocampus data ──────────────────────────────────────────────────────────
MEMORY_COUNT=0; CORE_COUNT=0; TOP_MEMORIES="[]"
if [ "$HAS_HIPPOCAMPUS" = "true" ]; then
  MEMORY_COUNT=$(jq '.memories | length' "$HIPPOCAMPUS_FILE")
  CORE_COUNT=$(jq '[.memories[] | select(.importance >= 0.7)] | length' "$HIPPOCAMPUS_FILE")
  TOP_MEMORIES=$(jq -c '[.memories | sort_by(-.importance) | .[:5] | .[] | {id, domain, importance, summary: (.content[:80] + "...")}]' "$HIPPOCAMPUS_FILE")
fi

# ── Amygdala data ─────────────────────────────────────────────────────────────
VALENCE=0; AROUSAL=0.3; CONNECTION=0.4; CURIOSITY=0.5; ENERGY=0.5; ANTICIPATION=0; TRUST=0.5
RECENT_EMOTIONS="[]"; MOOD_EMOJI="😐"; MOOD_LABEL="Neutral"; MOOD_COLOR="#94a3b8"
if [ "$HAS_AMYGDALA" = "true" ]; then
  VALENCE=$(jq -r '.dimensions.valence // 0' "$AMYGDALA_FILE")
  AROUSAL=$(jq -r '.dimensions.arousal // 0.3' "$AMYGDALA_FILE")
  CONNECTION=$(jq -r '.dimensions.connection // 0.4' "$AMYGDALA_FILE")
  CURIOSITY=$(jq -r '.dimensions.curiosity // 0.5' "$AMYGDALA_FILE")
  ENERGY=$(jq -r '.dimensions.energy // 0.5' "$AMYGDALA_FILE")
  ANTICIPATION=$(jq -r '.dimensions.anticipation // 0' "$AMYGDALA_FILE")
  TRUST=$(jq -r '.dimensions.trust // 0.5' "$AMYGDALA_FILE")
  RECENT_EMOTIONS=$(jq -c '[.recentEmotions[-5:] // [] | .[] | {label, intensity, trigger}]' "$AMYGDALA_FILE")
  vi=$(echo "$VALENCE * 100" | bc | cut -d. -f1)
  ai=$(echo "$AROUSAL * 100" | bc | cut -d. -f1)
  if [ "$vi" -gt 70 ] && [ "$ai" -gt 60 ]; then   MOOD_EMOJI="😄"; MOOD_LABEL="Energized"; MOOD_COLOR="#10b981"
  elif [ "$vi" -gt 50 ] && [ "$ai" -le 40 ]; then  MOOD_EMOJI="😌"; MOOD_LABEL="Content";   MOOD_COLOR="#6366f1"
  elif [ "$vi" -gt 50 ]; then                       MOOD_EMOJI="🙂"; MOOD_LABEL="Positive";  MOOD_COLOR="#8b5cf6"
  elif [ "$vi" -lt -10 ] && [ "$ai" -gt 60 ]; then MOOD_EMOJI="😤"; MOOD_LABEL="Stressed";  MOOD_COLOR="#ef4444"
  elif [ "$vi" -lt -10 ]; then                      MOOD_EMOJI="😔"; MOOD_LABEL="Low";       MOOD_COLOR="#64748b"; fi
fi

# ── VTA data ──────────────────────────────────────────────────────────────────
DRIVE=0.5; SEEKING="[]"; ANTICIPATING="[]"; RECENT_REWARDS="[]"
if [ "$HAS_VTA" = "true" ]; then
  DRIVE=$(jq -r '.drive // 0.5' "$VTA_FILE")
  SEEKING=$(jq -c '.seeking // []' "$VTA_FILE")
  ANTICIPATING=$(jq -c '.anticipating // []' "$VTA_FILE")
  RECENT_REWARDS=$(jq -c '[.recentRewards[-5:] // [] | .[] | {type, source, intensity}]' "$VTA_FILE")
fi
DRIVE_PCT=$(echo "$DRIVE * 100" | bc | cut -d. -f1)

# ── Basal Ganglia data ────────────────────────────────────────────────────────
HABIT_COUNT=0; CHUNKED_COUNT=0; SUPPRESSION_COUNT=0; PROCEDURE_COUNT=0
TOP_HABITS="[]"; TOP_PROCS="[]"; TOP_SUPPS="[]"
if [ "$HAS_BASAL" = "true" ]; then
  HABIT_COUNT=$(jq '.habits | length' "$BASAL_FILE")
  CHUNKED_COUNT=$(jq '[.habits[] | select(.strength >= 0.7)] | length' "$BASAL_FILE")
  SUPPRESSION_COUNT=$(jq '.suppressions | length' "$BASAL_FILE")
  PROCEDURE_COUNT=$(jq '.procedures | length' "$BASAL_FILE")
  TOP_HABITS=$(jq -c '[.habits | sort_by(-.strength) | .[:6] | .[] | {id, cue, routine, strength, executions, status}]' "$BASAL_FILE")
  TOP_PROCS=$(jq -c '[.procedures | sort_by(-.strength) | .[:4] | .[] | {id, name, steps, strength}]' "$BASAL_FILE")
  TOP_SUPPS=$(jq -c '[.suppressions | sort_by(-.strength) | .[:5] | .[] | {id, pattern, reason, strength}]' "$BASAL_FILE")
fi

# ── Insula data ───────────────────────────────────────────────────────────────
GUT_SIGNAL=0; COGNITIVE_LOAD=0.3; FRICTION=0.1; SELF_COHERENCE=0.7; EMPATHIC_RESONANCE=0.4
SOMATIC_COMFORT=0.3; CONTEXT_SATURATION=0.2; RECENT_SIGNALS="[]"
if [ "$HAS_INSULA" = "true" ]; then
  GUT_SIGNAL=$(jq -r '.channels.gutSignal // 0' "$INSULA_FILE")
  COGNITIVE_LOAD=$(jq -r '.channels.cognitiveLoad // 0.3' "$INSULA_FILE")
  FRICTION=$(jq -r '.channels.friction // 0.1' "$INSULA_FILE")
  SELF_COHERENCE=$(jq -r '.channels.selfCoherence // 0.7' "$INSULA_FILE")
  EMPATHIC_RESONANCE=$(jq -r '.channels.empathicResonance // 0.4' "$INSULA_FILE")
  SOMATIC_COMFORT=$(jq -r '.channels.somaticComfort // 0.3' "$INSULA_FILE")
  CONTEXT_SATURATION=$(jq -r '.channels.contextSaturation // 0.2' "$INSULA_FILE")
  RECENT_SIGNALS=$(jq -c '[.recentSignals[-5:] // [] | .[] | {label, intensity, source}]' "$INSULA_FILE")
fi

# ── ACC Conflict data ─────────────────────────────────────────────────────────
CONFLICT_LOAD=0.2; ACTIVE_CONFLICTS=0; ATTENTION_FLAGS="[]"; ACC_CONFLICT_DATA="[]"
if [ "$HAS_ACC_CONFLICT" = "true" ]; then
  CONFLICT_LOAD=$(jq -r '.conflictLoad // 0.2' "$ACC_CONFLICT_FILE")
  ACTIVE_CONFLICTS=$(jq '.activeConflicts | length' "$ACC_CONFLICT_FILE")
  ATTENTION_FLAGS=$(jq -c '[.attentionFlags // [] | .[] | .topic]' "$ACC_CONFLICT_FILE")
  ACC_CONFLICT_DATA=$(jq -c '[.activeConflicts | to_entries[:4] | .[] | {type: .value.type, severity: .value.severity, description: .value.description}]' "$ACC_CONFLICT_FILE")
fi
CONFLICT_PCT=$(echo "$CONFLICT_LOAD * 100" | bc | cut -d. -f1)
if   [ "$CONFLICT_PCT" -ge 80 ]; then CONFLICT_STATUS="🚨 Critical"; CONFLICT_COLOR="#ef4444"
elif [ "$CONFLICT_PCT" -ge 60 ]; then CONFLICT_STATUS="🔴 Elevated"; CONFLICT_COLOR="#f97316"
elif [ "$CONFLICT_PCT" -ge 40 ]; then CONFLICT_STATUS="🟠 Moderate"; CONFLICT_COLOR="#f59e0b"
elif [ "$CONFLICT_PCT" -ge 20 ]; then CONFLICT_STATUS="🟡 Low";      CONFLICT_COLOR="#eab308"
else                                   CONFLICT_STATUS="🟢 Clear";    CONFLICT_COLOR="#10b981"; fi

# ── ACC Error data ────────────────────────────────────────────────────────────
ACTIVE_PATTERNS=0; CRITICAL_PATTERNS=0; WARNING_PATTERNS=0; ERROR_PATTERN_DATA="[]"
if [ "$HAS_ACC_ERROR" = "true" ]; then
  ACTIVE_PATTERNS=$(jq '.activePatterns | length' "$ACC_ERROR_FILE")
  CRITICAL_PATTERNS=$(jq '[.activePatterns | to_entries[] | select(.value.severity=="critical")] | length' "$ACC_ERROR_FILE")
  WARNING_PATTERNS=$(jq '[.activePatterns | to_entries[] | select(.value.severity=="warning")] | length' "$ACC_ERROR_FILE")
  ERROR_PATTERN_DATA=$(jq -c '[.activePatterns | to_entries[:4] | .[] | {pattern: .key, severity: .value.severity, count: .value.count, mitigation: .value.mitigation}]' "$ACC_ERROR_FILE")
fi

# ─────────────────────────────────────────────────────────────────────────────
# HTML
# ─────────────────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Brain Dashboard</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
    :root {
      --bg-dark:#09090b; --bg-card:rgba(24,24,27,.8); --bg-el:rgba(39,39,42,.6);
      --border:rgba(63,63,70,.5); --text:#fafafa; --ts:#a1a1aa; --tm:#71717a;
      --accent:#a855f7; --ag:rgba(168,85,247,.3); --cyan:#06b6d4; --pink:#ec4899;
      --amber:#f59e0b; --em:#10b981; --habit:#f59e0b; --hg:rgba(245,158,11,.3);
    }
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:'Inter',-apple-system,sans-serif;background:var(--bg-dark);
      background-image:radial-gradient(ellipse at top,rgba(168,85,247,.1) 0%,transparent 50%),
        radial-gradient(ellipse at bottom right,rgba(6,182,212,.08) 0%,transparent 50%);
      color:var(--text);min-height:100vh;padding:24px 16px;line-height:1.5}
    .container{max-width:480px;margin:0 auto}
    .header{display:flex;align-items:center;gap:16px;margin-bottom:24px;padding:16px;
      background:var(--bg-card);border-radius:16px;border:1px solid var(--border);backdrop-filter:blur(12px)}
    .avatar-wrap{position:relative}
    .avatar{width:64px;height:64px;border-radius:50%;object-fit:cover;border:2px solid var(--accent);box-shadow:0 0 24px var(--ag)}
    .avatar-ph{width:64px;height:64px;border-radius:50%;background:linear-gradient(135deg,var(--accent),var(--pink));
      display:flex;align-items:center;justify-content:center;font-size:28px;box-shadow:0 0 24px var(--ag)}
    .dot{position:absolute;bottom:2px;right:2px;width:14px;height:14px;border-radius:50%;
      border:3px solid var(--bg-dark);animation:pulse 2s infinite}
    @keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.7;transform:scale(.95)}}
    .header-info h1{font-size:1.25rem;font-weight:600}
    .subtitle{color:var(--tm);font-size:.8rem;margin-top:2px}
    .mood{display:inline-flex;align-items:center;gap:6px;margin-top:6px;padding:4px 10px;
      background:var(--bg-el);border-radius:20px;font-size:.75rem;font-weight:500}
    .tabs{display:flex;gap:4px;margin-bottom:20px;flex-wrap:wrap}
    .tab{flex:1;min-width:60px;padding:8px 4px;border:none;background:var(--bg-card);
      border:1px solid var(--border);color:var(--tm);font-size:.68rem;font-weight:500;
      cursor:pointer;border-radius:10px;transition:all .2s;backdrop-filter:blur(8px);
      display:flex;align-items:center;justify-content:center;gap:3px}
    .tab:hover{background:var(--bg-el)}
    .tab.active{background:linear-gradient(135deg,rgba(168,85,247,.2),rgba(236,72,153,.1));
      border-color:var(--accent);color:var(--text);box-shadow:0 0 16px var(--ag)}
    .tab-icon{font-size:.9rem}
    .tc{display:none;animation:fi .3s ease}
    .tc.active{display:block}
    @keyframes fi{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
    .card{background:var(--bg-card);border-radius:16px;padding:16px;margin-bottom:12px;
      border:1px solid var(--border);backdrop-filter:blur(12px)}
    .ct{font-size:.65rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
      color:var(--tm);margin-bottom:12px}
    .stats{display:grid;grid-template-columns:1fr 1fr;gap:10px}
    .stats4{display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:8px}
    .stat{background:var(--bg-el);border-radius:12px;padding:14px 10px;text-align:center;border:1px solid var(--border)}
    .sv{font-size:1.8rem;font-weight:700;background:linear-gradient(135deg,var(--accent),var(--pink));
      -webkit-background-clip:text;-webkit-text-fill-color:transparent}
    .sv2{font-size:1.4rem;font-weight:700;background:linear-gradient(135deg,var(--habit),var(--amber));
      -webkit-background-clip:text;-webkit-text-fill-color:transparent}
    .sl{font-size:.65rem;color:var(--tm);margin-top:3px}
    .dim{display:flex;align-items:center;padding:10px 0;border-bottom:1px solid var(--border)}
    .dim:last-child{border:none}
    .di{width:28px;font-size:1rem}
    .dn{flex:1;font-size:.82rem;font-weight:500}
    .db{width:90px;height:6px;background:var(--bg-el);border-radius:3px;margin:0 10px;overflow:hidden;flex-shrink:0}
    .df{height:100%;border-radius:3px;transition:width .5s}
    .dv{width:38px;text-align:right;font-size:.78rem;color:var(--ts);font-variant-numeric:tabular-nums}
    .li{display:flex;align-items:flex-start;gap:10px;padding:10px 0;border-bottom:1px solid var(--border)}
    .li:last-child{border:none}
    .badge{background:var(--bg-el);padding:3px 8px;border-radius:8px;font-size:.68rem;font-weight:600;
      text-transform:capitalize;white-space:nowrap;border:1px solid var(--border);flex-shrink:0}
    .bc{border-color:#10b981;color:#10b981}
    .ba{border-color:#f59e0b;color:#f59e0b}
    .bf{border-color:#f97316;color:#f97316}
    .br{border-color:#ef4444;color:#ef4444}
    .lt{flex:1;font-size:.78rem;color:var(--ts);line-height:1.5}
    .steps{font-size:.7rem;color:var(--tm);margin-top:3px;line-height:1.5}
    .sa{font-size:.7rem;color:var(--tm);display:block;margin-top:2px}
    .tags{display:flex;flex-wrap:wrap;gap:8px}
    .tag{background:var(--bg-el);padding:6px 12px;border-radius:20px;font-size:.75rem;
      color:var(--ts);border:1px solid var(--border)}
    .sup{background:rgba(239,68,68,.08);border-color:rgba(239,68,68,.3);color:#f87171;
      font-size:.75rem;padding:6px 12px;border-radius:20px;border:1px solid}
    .qd{display:grid;grid-template-columns:1fr 1fr;gap:8px}
    .qc{background:var(--bg-el);border-radius:12px;padding:14px 10px;text-align:center;
      border:1px solid var(--border);transition:all .3s}
    .qc .em2{font-size:1.5rem;margin-bottom:4px}
    .qc .lbl{font-size:.75rem;font-weight:500}
    .qc.active{border-color:var(--accent);background:linear-gradient(135deg,rgba(168,85,247,.15),rgba(236,72,153,.1));
      box-shadow:0 0 20px var(--ag);transform:scale(1.02)}
    .dm{text-align:center;padding:24px 16px}
    .dv2{font-size:3.5rem;font-weight:700;background:linear-gradient(135deg,var(--amber),#ef4444);
      -webkit-background-clip:text;-webkit-text-fill-color:transparent}
    .dl{font-size:.85rem;color:var(--tm);margin-top:4px}
    .dbar{height:8px;background:var(--bg-el);border-radius:4px;margin-top:16px;overflow:hidden}
    .dfill{height:100%;background:linear-gradient(90deg,var(--amber),#ef4444);border-radius:4px;
      transition:width .5s;box-shadow:0 0 12px rgba(245,158,11,.4)}
    .empty{color:var(--tm);text-align:center;padding:20px;font-size:.85rem}
    .ip{text-align:center;padding:32px 16px}
    .ip .ic{font-size:3rem;margin-bottom:12px;opacity:.4}
    .ip p{color:var(--tm);font-size:.9rem;margin-bottom:8px}
    .ip code{display:inline-block;background:var(--bg-el);padding:10px 16px;border-radius:8px;
      font-size:.8rem;border:1px solid var(--border);margin-top:8px}
    .footer{text-align:center;margin-top:24px;padding-top:16px;font-size:.7rem;color:var(--tm)}
    .footer a{color:var(--accent);text-decoration:none}
  </style>
</head>
<body>
<div class="container">
HTMLHEAD

AVATAR_ICON="🎯"
ACTIVE_COLOR="#f59e0b"
# Avatar
cat >> "$OUTPUT_FILE" << 'HEADERSTART'
  <div class="header">
    <div class="avatar-wrap">
HEADERSTART
if [ -n "$AVATAR_BASE64" ]; then
  echo "      <img src=\"$AVATAR_BASE64\" class=\"avatar\">" >> "$OUTPUT_FILE"
else
  echo "      <div class=\"avatar-ph\">$AVATAR_ICON</div>" >> "$OUTPUT_FILE"
fi
cat >> "$OUTPUT_FILE" << HEADEREND
      <div class="dot" style="background:$ACTIVE_COLOR;"></div>
    </div>
    <div class="header-info">
      <h1>$AGENT_NAME</h1>
      <div class="subtitle">Brain Dashboard</div>
      <div class="mood"><span>$MOOD_EMOJI</span><span style="color:$MOOD_COLOR">$MOOD_LABEL</span></div>
    </div>
  </div>

  <div class="tabs">
    <button class="tab $TA_HIPPO" data-tab="hippocampus"><span class="tab-icon">🧠</span> Memory</button>
    <button class="tab $TA_AMY" data-tab="amygdala"><span class="tab-icon">🎭</span> Emotions</button>
    <button class="tab " data-tab="vta"><span class="tab-icon">⭐</span> Drive</button>
    <button class="tab active" data-tab="basal"><span class="tab-icon">🎯</span> Habits</button>
    <button class="tab " data-tab="insula"><span class="tab-icon">🌡️</span> Sense</button>
    <button class="tab " data-tab="oversight"><span class="tab-icon">⚡</span> Oversight</button>
  </div>
HEADEREND

# ── Hippocampus tab ───────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'HTAB'
  <!-- Memory -->
  <div class="tc $TC_HIPPO" id="tab-hippocampus">
HTAB
if [ "$HAS_HIPPOCAMPUS" = "true" ]; then
cat >> "$OUTPUT_FILE" << HDATA
    <div class="card"><div class="stats">
      <div class="stat"><div class="sv">$MEMORY_COUNT</div><div class="sl">Total Memories</div></div>
      <div class="stat"><div class="sv">$CORE_COUNT</div><div class="sl">Core (≥0.7)</div></div>
    </div></div>
    <div class="card"><div class="ct">Top Memories</div><div id="topMemories"></div></div>
HDATA
else
  cat >> "$OUTPUT_FILE" << 'HNONE'
    <div class="card"><div class="ip"><div class="ic">🧠</div><p><strong>Hippocampus</strong> not installed</p><p>Add memory formation &amp; recall</p><code>clawdhub install hippocampus</code></div></div>
HNONE
fi

# ── Amygdala tab ──────────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'ATAB'
  </div>
  <!-- Emotions -->
  <div class="tc $TC_AMY" id="tab-amygdala">
    <div class="card"><div class="ct">Dimensions</div><div id="dimensions"></div></div>
    <div class="card"><div class="ct">Mood Quadrant</div>
      <div class="qd">
        <div class="qc" id="q-stressed"><div class="em2">😤</div><div class="lbl">Stressed</div></div>
        <div class="qc" id="q-energized"><div class="em2">😄</div><div class="lbl">Energized</div></div>
        <div class="qc" id="q-depleted"><div class="em2">😔</div><div class="lbl">Depleted</div></div>
        <div class="qc" id="q-content"><div class="em2">😌</div><div class="lbl">Content</div></div>
      </div>
    </div>
    <div class="card"><div class="ct">Recent Feelings</div><div id="recentEmotions"></div></div>
  </div>
ATAB

# ── VTA tab ───────────────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'VTAB'
  <!-- Drive -->
  <div class="tc " id="tab-vta">
VTAB
if [ "$HAS_VTA" = "true" ]; then
cat >> "$OUTPUT_FILE" << VDATA
    <div class="card"><div class="dm"><div class="dv2">${DRIVE_PCT}%</div><div class="dl">Drive Level</div><div class="dbar"><div class="dfill" style="width:${DRIVE_PCT}%"></div></div></div></div>
    <div class="card"><div class="ct">Seeking</div><div id="vtaSeeking" class="tags"></div></div>
    <div class="card"><div class="ct">Looking Forward To</div><div id="vtaAnticipating" class="tags"></div></div>
    <div class="card"><div class="ct">Recent Rewards</div><div id="recentRewards"></div></div>
VDATA
else
  cat >> "$OUTPUT_FILE" << 'VNONE'
    <div class="card"><div class="ip"><div class="ic">⭐</div><p><strong>VTA</strong> not installed</p><p>Add motivation &amp; rewards</p><code>clawdhub install vta-memory</code></div></div>
VNONE
fi

# ── Basal Ganglia tab ─────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'BTAB'
  </div>
  <!-- Habits -->
  <div class="tc active" id="tab-basal">
BTAB
if [ "$HAS_BASAL" = "true" ]; then
cat >> "$OUTPUT_FILE" << BDATA
    <div class="card"><div class="stats4">
      <div class="stat"><div class="sv2">$CHUNKED_COUNT</div><div class="sl">🟢 Chunked</div></div>
      <div class="stat"><div class="sv2">$HABIT_COUNT</div><div class="sl">Habits</div></div>
      <div class="stat"><div class="sv2">$PROCEDURE_COUNT</div><div class="sl">Procedures</div></div>
      <div class="stat"><div class="sv2">$SUPPRESSION_COUNT</div><div class="sl">🚫 Suppressed</div></div>
    </div></div>
    <div class="card"><div class="ct">Habits by Strength</div><div id="habitBars"></div></div>
    <div class="card"><div class="ct">Procedures</div><div id="procList"></div></div>
    <div class="card"><div class="ct">Suppressions</div><div id="suppList" class="tags"></div></div>
BDATA
else
  cat >> "$OUTPUT_FILE" << 'BNONE'
    <div class="card"><div class="ip"><div class="ic">🎯</div><p><strong>Basal Ganglia</strong> not installed</p><p>Add habit formation &amp; procedural learning</p><code>clawdhub install basal-ganglia-memory</code></div></div>
BNONE
fi

# ── Insula tab ────────────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'ITAB'
  </div>
  <!-- Sense -->
  <div class="tc " id="tab-insula">
ITAB
if [ "$HAS_INSULA" = "true" ]; then
cat >> "$OUTPUT_FILE" << IDATA
    <div class="card"><div class="ct">Interoceptive Channels</div><div id="insulaChannels"></div></div>
    <div class="card"><div class="ct">Recent Signals</div><div id="recentSignals"></div></div>
IDATA
else
  cat >> "$OUTPUT_FILE" << 'INONE'
    <div class="card"><div class="ip"><div class="ic">🌡️</div><p><strong>Insula</strong> not installed</p><p>Add interoceptive awareness &amp; gut sense</p><code>clawdhub install insula-memory</code></div></div>
INONE
fi

# ── Oversight tab (ACC Conflict + ACC Error) ───────────────────────────────────
cat >> "$OUTPUT_FILE" << 'OTAB'
  </div>
  <!-- Oversight -->
  <div class="tc " id="tab-oversight">
OTAB
if [ "$HAS_ACC_CONFLICT" = "true" ]; then
cat >> "$OUTPUT_FILE" << ODATA
    <div class="card">
      <div class="dm" style="padding:16px">
        <div style="font-size:1.5rem;font-weight:700;color:$CONFLICT_COLOR">$CONFLICT_STATUS</div>
        <div class="dl">Conflict Load: ${CONFLICT_PCT}%</div>
        <div class="dbar"><div class="dfill" style="width:${CONFLICT_PCT}%;background:$CONFLICT_COLOR;box-shadow:0 0 12px ${CONFLICT_COLOR}66"></div></div>
      </div>
    </div>
    <div class="card"><div class="stats">
      <div class="stat"><div class="sv">$ACTIVE_CONFLICTS</div><div class="sl">Active Conflicts</div></div>
    </div></div>
    <div class="card"><div class="ct">Attention Flags</div><div id="attentionFlags" class="tags"></div></div>
    <div class="card"><div class="ct">Active Conflicts</div><div id="conflictList"></div></div>
ODATA
else
  cat >> "$OUTPUT_FILE" << 'ONONE_CONFLICT'
    <div class="card"><div class="ip"><div class="ic">⚡</div><p><strong>Anterior Cingulate</strong> not installed</p><p>Add conflict detection &amp; uncertainty monitoring</p><code>clawdhub install anterior-cingulate-memory</code></div></div>
ONONE_CONFLICT
fi
if [ "$HAS_ACC_ERROR" = "true" ]; then
cat >> "$OUTPUT_FILE" << ERRDATA
    <div class="card"><div class="ct">Error Patterns</div><div class="stats4">
      <div class="stat"><div class="sv2">$ACTIVE_PATTERNS</div><div class="sl">Active</div></div>
      <div class="stat"><div class="sv2">$CRITICAL_PATTERNS</div><div class="sl">🔴 Critical</div></div>
      <div class="stat"><div class="sv2">$WARNING_PATTERNS</div><div class="sl">⚠️ Warning</div></div>
    </div></div>
    <div class="card"><div class="ct">Pattern Details</div><div id="errorPatterns"></div></div>
ERRDATA
else
  cat >> "$OUTPUT_FILE" << 'ONONE_ERROR'
    <div class="card"><div class="ip"><div class="ic">🔴</div><p><strong>ACC Error</strong> not installed</p><p>Add error pattern tracking &amp; correction learning</p><code>clawdhub install acc-error-memory</code></div></div>
ONONE_ERROR
fi


# ── Freshness (read-vs-write recency, best-effort) ─────────────────────────────
FRESH_ROWS=""
add_fresh_row() {
  local icon="$1" label="$2" file="$3"
  [ -f "$file" ] || return
  local upd con flag
  upd=$(jq -r '.lastUpdated // "never"' "$file" 2>/dev/null || echo "never")
  con=$(jq -r '.lastConsultedAt // "never"' "$file" 2>/dev/null || echo "never")
  flag="⚪"
  [ "$con" != "never" ] && flag="🟢"
  [ "$con" != "never" ] && [ "$upd" != "never" ] && [[ "$con" < "$upd" ]] && flag="🟡"
  FRESH_ROWS="$FRESH_ROWS<div class=\"li\"><span>$icon $label</span><span class=\"lt\">updated $upd &middot; read $con $flag</span></div>"
}
add_fresh_row "🧠" "Hippocampus" "$HIPPOCAMPUS_FILE"
add_fresh_row "🎭" "Amygdala" "$AMYGDALA_FILE"
add_fresh_row "⭐" "VTA" "$VTA_FILE"
add_fresh_row "🎯" "Basal Ganglia" "$BASAL_FILE"
add_fresh_row "🌡️" "Insula" "$INSULA_FILE"
add_fresh_row "⚡" "ACC Conflict" "$ACC_CONFLICT_FILE"
add_fresh_row "🔴" "ACC Error" "$ACC_ERROR_FILE"
[ -z "$FRESH_ROWS" ] && FRESH_ROWS="<div class=\"empty\">No state files found</div>"
cat >> "$OUTPUT_FILE" << FRESHDATA
    <div class="card"><div class="ct">State Freshness (🟢 read since last update &middot; 🟡 updated but not yet read &middot; ⚪ never read)</div>$FRESH_ROWS</div>
FRESHDATA

# ── Footer + JS ───────────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'FOOTER'
  </div>
  <div class="footer">Part of the <a href="https://clawhub.ai/skills?tag=ai-brain">AI Brain Series</a> 🧠</div>
</div>
<script>
FOOTER

cat >> "$OUTPUT_FILE" << JSDATA
const S = {
  hippocampus: { installed: $HAS_HIPPOCAMPUS, topMemories: $TOP_MEMORIES },
  amygdala: { installed: $HAS_AMYGDALA, dimensions: {valence:$VALENCE,arousal:$AROUSAL,connection:$CONNECTION,curiosity:$CURIOSITY,energy:$ENERGY,trust:$TRUST,anticipation:$ANTICIPATION}, recentEmotions: $RECENT_EMOTIONS },
  vta: { installed: $HAS_VTA, drive: $DRIVE, seeking: $SEEKING, anticipating: $ANTICIPATING, recentRewards: $RECENT_REWARDS },
  basal: { installed: $HAS_BASAL, habits: $TOP_HABITS, procedures: $TOP_PROCS, suppressions: $TOP_SUPPS },
  insula: { installed: $HAS_INSULA, channels: {gutSignal:$GUT_SIGNAL,cognitiveLoad:$COGNITIVE_LOAD,friction:$FRICTION,selfCoherence:$SELF_COHERENCE,empathicResonance:$EMPATHIC_RESONANCE,somaticComfort:$SOMATIC_COMFORT,contextSaturation:$CONTEXT_SATURATION}, recentSignals: $RECENT_SIGNALS },
  accConflict: { installed: $HAS_ACC_CONFLICT, conflictLoad: $CONFLICT_LOAD, activeConflicts: $ACTIVE_CONFLICTS, attentionFlags: $ATTENTION_FLAGS, conflicts: $ACC_CONFLICT_DATA },
  accError: { installed: $HAS_ACC_ERROR, activePatterns: $ACTIVE_PATTERNS, criticalPatterns: $CRITICAL_PATTERNS, warningPatterns: $WARNING_PATTERNS, patterns: $ERROR_PATTERN_DATA }
};
JSDATA

cat >> "$OUTPUT_FILE" << 'JSEND'
// Tabs
document.querySelectorAll('.tab').forEach(t=>t.addEventListener('click',()=>{
  document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));
  document.querySelectorAll('.tc').forEach(x=>x.classList.remove('active'));
  t.classList.add('active');
  document.getElementById('tab-'+t.dataset.tab).classList.add('active');
}));

// Hippocampus
if(S.hippocampus.installed){
  const el=document.getElementById('topMemories');
  if(S.hippocampus.topMemories?.length){
    S.hippocampus.topMemories.forEach(m=>{el.innerHTML+=`<div class="li"><span class="badge">${(m.importance*100).toFixed(0)}%</span><span class="lt">${m.summary}</span></div>`;});
  } else el.innerHTML='<div class="empty">No memories yet</div>';
}

// Amygdala
const dims=[
  {k:'valence',n:'Valence',i:'🎭',min:-1,max:1,c:'linear-gradient(90deg,#ef4444,#fbbf24,#10b981)'},
  {k:'arousal',n:'Arousal',i:'⚡',min:0,max:1,c:'linear-gradient(90deg,#3b82f6,#f97316)'},
  {k:'connection',n:'Connection',i:'💕',min:0,max:1,c:'#ec4899'},
  {k:'curiosity',n:'Curiosity',i:'🔍',min:0,max:1,c:'#06b6d4'},
  {k:'energy',n:'Energy',i:'🔋',min:0,max:1,c:'#eab308'},
  {k:'trust',n:'Trust',i:'🤝',min:0,max:1,c:'#10b981'},
  {k:'anticipation',n:'Anticipation',i:'✨',min:0,max:1,c:'#a855f7'}
];
const de=document.getElementById('dimensions');
dims.forEach(d=>{
  const v=S.amygdala.dimensions[d.k]||0;
  const pct=((v-d.min)/(d.max-d.min))*100;
  de.innerHTML+=`<div class="dim"><span class="di">${d.i}</span><span class="dn">${d.n}</span><div class="db"><div class="df" style="width:${pct}%;background:${d.c}"></div></div><span class="dv">${v.toFixed(2)}</span></div>`;
});
const va=S.amygdala.dimensions.valence,ar=S.amygdala.dimensions.arousal;
document.getElementById('q-'+(va>=0&&ar>=0.5?'energized':va>=0?'content':ar>=0.5?'stressed':'depleted'))?.classList.add('active');
const re=document.getElementById('recentEmotions');
if(S.amygdala.recentEmotions?.length){
  S.amygdala.recentEmotions.slice().reverse().forEach(e=>{re.innerHTML+=`<div class="li"><span class="badge">${e.label}</span><span class="lt">${e.trigger||'—'}</span></div>`;});
} else re.innerHTML='<div class="empty">No recent emotions</div>';

// VTA
if(S.vta.installed){
  const se=document.getElementById('vtaSeeking'),ae=document.getElementById('vtaAnticipating'),rr=document.getElementById('recentRewards');
  (S.vta.seeking||[]).forEach(s=>se.innerHTML+=`<span class="tag">${s}</span>`);
  if(!S.vta.seeking?.length) se.innerHTML='<div class="empty">Nothing actively sought</div>';
  (S.vta.anticipating||[]).forEach(a=>ae.innerHTML+=`<span class="tag">${a}</span>`);
  if(!S.vta.anticipating?.length) ae.innerHTML='<div class="empty">Nothing anticipated</div>';
  if(S.vta.recentRewards?.length){S.vta.recentRewards.slice().reverse().forEach(r=>{rr.innerHTML+=`<div class="li"><span class="badge">${r.type}</span><span class="lt">${r.source||'—'}</span></div>`;});}
  else rr.innerHTML='<div class="empty">No recent rewards</div>';
}

// Basal Ganglia
if(S.basal.installed){
  const he=document.getElementById('habitBars'),pe=document.getElementById('procList'),se2=document.getElementById('suppList');
  if(S.basal.habits?.length){
    S.basal.habits.forEach(h=>{
      const pct=Math.round(h.strength*100);
      const cl=h.strength>=.7?'#10b981':h.strength>=.4?'#f59e0b':'#f97316';
      const bc=h.strength>=.7?'bc':h.strength>=.4?'ba':'bf';
      const lb=h.strength>=.7?'chunked':h.strength>=.4?'active':'forming';
      he.innerHTML+=`<div class="dim"><span class="di">🎯</span><span class="dn" style="max-width:130px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${h.cue}→${h.routine}">${h.cue||'?'}<span class="sa">${h.routine||''}</span></span><div class="db"><div class="df" style="width:${pct}%;background:${cl}"></div></div><span class="dv"><span class="badge ${bc}" style="font-size:.6rem;padding:2px 5px">${lb}</span></span></div>`;
    });
  } else he.innerHTML='<div class="empty">No habits yet. Run encode-pipeline.sh</div>';
  if(S.basal.procedures?.length){
    S.basal.procedures.forEach(p=>{
      const steps=(p.steps||[]).join('<span style="color:#f59e0b"> → </span>');
      pe.innerHTML+=`<div class="li"><span class="badge">${Math.round((p.strength||0)*100)}%</span><div><span class="lt">${p.name||'?'}</span><div class="steps">${steps}</div></div></div>`;
    });
  } else pe.innerHTML='<div class="empty">No procedures chunked yet</div>';
  if(S.basal.suppressions?.length){
    S.basal.suppressions.forEach(s=>{se2.innerHTML+=`<span class="sup" title="${s.reason||''}">🚫 ${s.pattern||'?'}</span>`;});
  } else se2.innerHTML='<div class="empty">No suppressions</div>';
}

// Insula
if(S.insula.installed){
  const ich=document.getElementById('insulaChannels'),rs=document.getElementById('recentSignals');
  const chs=[
    {k:'gutSignal',n:'Gut Signal',i:'🎯',min:-1,max:1,c:'linear-gradient(90deg,#ef4444,#fbbf24,#10b981)'},
    {k:'cognitiveLoad',n:'Cognitive Load',i:'🧠',min:0,max:1,c:'linear-gradient(90deg,#3b82f6,#f97316)'},
    {k:'friction',n:'Friction',i:'🌊',min:0,max:1,c:'linear-gradient(90deg,#10b981,#ef4444)'},
    {k:'selfCoherence',n:'Self Coherence',i:'🔮',min:0,max:1,c:'#a855f7'},
    {k:'empathicResonance',n:'Empathic Resonance',i:'💕',min:0,max:1,c:'#ec4899'},
    {k:'somaticComfort',n:'Somatic Comfort',i:'🌿',min:-1,max:1,c:'linear-gradient(90deg,#ef4444,#fbbf24,#10b981)'},
    {k:'contextSaturation',n:'Context Saturation',i:'📊',min:0,max:1,c:'linear-gradient(90deg,#3b82f6,#a855f7)'},
  ];
  chs.forEach(d=>{
    const v=S.insula.channels[d.k]||0;
    const pct=((v-d.min)/(d.max-d.min))*100;
    ich.innerHTML+=`<div class="dim"><span class="di">${d.i}</span><span class="dn">${d.n}</span><div class="db"><div class="df" style="width:${pct}%;background:${d.c}"></div></div><span class="dv">${v.toFixed(2)}</span></div>`;
  });
  if(S.insula.recentSignals?.length){
    S.insula.recentSignals.slice().reverse().forEach(s=>{rs.innerHTML+=`<div class="li"><span class="badge">${s.label}</span><span class="lt">${s.source||'—'}</span></div>`;});
  } else rs.innerHTML='<div class="empty">No recent signals</div>';
}

// ACC Conflict
if(S.accConflict.installed){
  const af=document.getElementById('attentionFlags'),cl=document.getElementById('conflictList');
  (S.accConflict.attentionFlags||[]).forEach(f=>af.innerHTML+=`<span class="tag">📌 ${f}</span>`);
  if(!S.accConflict.attentionFlags?.length) af.innerHTML='<div class="empty">No attention flags</div>';
  if(S.accConflict.conflicts?.length){
    S.accConflict.conflicts.forEach(c=>{
      const bc=c.severity==='high'?'br':c.severity==='moderate'?'ba':'bf';
      cl.innerHTML+=`<div class="li"><span class="badge ${bc}">${c.type}</span><span class="lt">${c.description}</span></div>`;
    });
  } else cl.innerHTML='<div class="empty">No active conflicts</div>';
}

// ACC Error
if(S.accError.installed){
  const ep=document.getElementById('errorPatterns');
  if(S.accError.patterns?.length){
    S.accError.patterns.forEach(p=>{
      const bc=p.severity==='critical'?'br':p.severity==='warning'?'ba':'bf';
      ep.innerHTML+=`<div class="li"><span class="badge ${bc}">${p.severity}</span><div><span class="lt">${p.pattern}</span><div class="steps">${p.mitigation||'No mitigation set'}</div></div></div>`;
    });
  } else ep.innerHTML='<div class="empty">No active error patterns</div>';
}
</script></body></html>
JSEND

echo "✅ Brain Dashboard → $OUTPUT_FILE"
