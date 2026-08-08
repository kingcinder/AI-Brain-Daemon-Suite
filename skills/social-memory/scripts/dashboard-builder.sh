#!/bin/bash
# dashboard-builder.sh — Shared AI Brain Series dashboard assembler
#
# This script is IDENTICAL across every brain-* skill. It is the single
# source of truth for brain-dashboard.html: shared CSS, shared tab/JS
# scaffolding, and a static registry of known tabs. No skill-specific
# logic lives here — it only reads fragment files that each skill writes
# about itself.
#
# Each skill's own generate-dashboard.sh:
#   1. Reads ONLY its own state file (never a sibling's)
#   2. Writes a self-contained fragment to:
#      $WORKSPACE/memory/dashboard-fragments/<id>.json
#      { "id", "order", "label", "icon", "html", "script", "data" }
#   3. Calls this script (optionally: dashboard-builder.sh --focus <id>)
#
# This script then:
#   - Renders an "install me" placeholder tab for any known skill with
#     no fragment file yet (not installed)
#   - Renders the real tab for any skill (known or unknown) that DOES
#     have a fragment file — so a brand new skill just needs to write
#     a fragment in the right shape, no changes needed here
#   - Assembles ONE shared CSS/JS shell, so no skill duplicates or drifts
#     from the others' look-and-feel
#   - Picks the initial active tab using: localStorage (what the human
#     actually last clicked) > --focus hint (which skill just ran)
#     > lowest `order` (deterministic default) — so there's no more
#     "whoever's cron fired last wins the whole page"
#
# Usage:
#   dashboard-builder.sh [--focus <tab-id>] [--output <path>]

set -e

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
FRAGMENTS_DIR="$WORKSPACE/memory/dashboard-fragments"
OUTPUT_FILE="$WORKSPACE/brain-dashboard.html"
FOCUS_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --focus) FOCUS_ID="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$FRAGMENTS_DIR"

# Prevent this builder from racing the monolithic generate-dashboard.sh
# copies (hippocampus/amygdala/vta/basal-ganglia/acc-error/anterior-
# cingulate/insula), which write the same $OUTPUT_FILE directly. Both
# writers must hold this lock for their entire write.
exec 200>"$OUTPUT_FILE.lock"
flock 200

# ── Static registry of known AI Brain Series tabs ────────────────────────────
# order|id|label|icon|install_slug
REGISTRY="
10|hippocampus|Memory|🧠|hippocampus-memory
15|prefrontal|Executive|🧭|prefrontal-cortex-memory
20|amygdala|Emotions|🎭|amygdala-memory
30|vta|Drive|⭐|vta-memory
40|basal|Habits|🎯|basal-ganglia-memory
50|acc_error|Errors|🔴|acc-error-memory
60|acc_conflict|Conflicts|⚡|anterior-cingulate-memory
70|insula|Sense|🌡️|insula-memory
75|heartbeat|Pulse|💓|heartbeat-memory
85|social|Social|🫂|social-memory
95|cerebellum|Precision|🎚️|cerebellum-memory
"

# ── Identify agent name / avatar (cosmetic header, not skill-specific) ───────
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
    MIME_TYPE="image/png"
    [[ "$AVATAR_PATH" == *.jpg || "$AVATAR_PATH" == *.jpeg ]] && MIME_TYPE="image/jpeg"
    AVATAR_BASE64="data:$MIME_TYPE;base64,$(base64 < "$AVATAR_PATH" | tr -d '\n')"
fi

# ── Build the ordered tab list: registry entries + any extra fragments ──────
# (Extra fragments let a brand-new/third-party skill show up with zero
#  changes to this script — it just needs to write a well-formed fragment.)
declare -a TAB_IDS=()
declare -a TAB_ORDERS=()
declare -a TAB_LABELS=()
declare -a TAB_ICONS=()
declare -a TAB_SLUGS=()

while IFS='|' read -r order id label icon slug; do
    [ -z "$id" ] && continue
    TAB_IDS+=("$id"); TAB_ORDERS+=("$order"); TAB_LABELS+=("$label"); TAB_ICONS+=("$icon"); TAB_SLUGS+=("$slug")
done <<< "$REGISTRY"

if [ -d "$FRAGMENTS_DIR" ]; then
    for f in "$FRAGMENTS_DIR"/*.json; do
        [ -e "$f" ] || continue
        fid=$(jq -r '.id // empty' "$f" 2>/dev/null) || continue
        [ -z "$fid" ] && continue
        KNOWN=false
        for existing in "${TAB_IDS[@]}"; do [ "$existing" = "$fid" ] && KNOWN=true && break; done
        if [ "$KNOWN" = false ]; then
            forder=$(jq -r '.order // 999' "$f" 2>/dev/null)
            flabel=$(jq -r '.label // .id' "$f" 2>/dev/null)
            ficon=$(jq -r '.icon // "🔹"' "$f" 2>/dev/null)
            TAB_IDS+=("$fid"); TAB_ORDERS+=("$forder"); TAB_LABELS+=("$flabel"); TAB_ICONS+=("$ficon"); TAB_SLUGS+=("$fid")
        fi
    done
fi

# Sort indices by TAB_ORDERS (stable, simple — tab counts are small)
SORTED_IDX=$(for i in "${!TAB_IDS[@]}"; do echo "${TAB_ORDERS[$i]} $i"; done | sort -n -k1,1 | awk '{print $2}')

# ── Shared CSS shell (canonical — every skill's tab uses these classes) ─────
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
            --bg-dark: #09090b;
            --bg-card: rgba(24, 24, 27, 0.8);
            --bg-elevated: rgba(39, 39, 42, 0.6);
            --border: rgba(63, 63, 70, 0.5);
            --text: #fafafa;
            --text-secondary: #a1a1aa;
            --text-muted: #71717a;
            --accent: #a855f7;
            --accent-glow: rgba(168, 85, 247, 0.3);
            --cyan: #06b6d4;
            --pink: #ec4899;
            --amber: #f59e0b;
            --emerald: #10b981;
            --sense: #14b8a6;
            --sense-glow: rgba(20, 184, 166, 0.3);
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-dark);
            background-image:
                radial-gradient(ellipse at top, rgba(168, 85, 247, 0.08) 0%, transparent 50%),
                radial-gradient(ellipse at bottom right, rgba(6, 182, 212, 0.06) 0%, transparent 50%);
            color: var(--text);
            min-height: 100vh;
            padding: 24px 16px;
            line-height: 1.5;
        }
        .container { max-width: 480px; margin: 0 auto; }
        .header { display: flex; align-items: center; gap: 16px; margin-bottom: 24px; padding: 16px; background: var(--bg-card); border-radius: 16px; border: 1px solid var(--border); backdrop-filter: blur(12px); }
        .avatar-wrap { position: relative; }
        .avatar { width: 64px; height: 64px; border-radius: 50%; object-fit: cover; border: 2px solid var(--accent); box-shadow: 0 0 24px var(--accent-glow); }
        .avatar-placeholder { width: 64px; height: 64px; border-radius: 50%; background: linear-gradient(135deg, var(--accent) 0%, var(--cyan) 100%); display: flex; align-items: center; justify-content: center; font-size: 28px; box-shadow: 0 0 24px var(--accent-glow); }
        .status-dot { position: absolute; bottom: 2px; right: 2px; width: 14px; height: 14px; border-radius: 50%; border: 3px solid var(--bg-dark); }
        .header-info h1 { font-size: 1.25rem; font-weight: 600; }
        .header-info .subtitle { color: var(--text-muted); font-size: 0.8rem; margin-top: 2px; }
        .tabs { display: flex; gap: 6px; margin-bottom: 20px; flex-wrap: wrap; }
        .tab { flex: 1; min-width: 56px; padding: 10px 6px; border: none; background: var(--bg-card); border: 1px solid var(--border); color: var(--text-muted); font-size: 0.68rem; font-weight: 500; cursor: pointer; border-radius: 12px; transition: all 0.2s; backdrop-filter: blur(8px); display: flex; align-items: center; justify-content: center; gap: 4px; }
        .tab:hover { background: var(--bg-elevated); border-color: rgba(168, 85, 247, 0.3); }
        .tab.active { background: linear-gradient(135deg, rgba(168, 85, 247, 0.2) 0%, rgba(6, 182, 212, 0.1) 100%); border-color: var(--accent); color: var(--text); box-shadow: 0 0 20px var(--accent-glow); }
        .tab-icon { font-size: 0.95rem; }
        .tab-content { display: none; animation: fadeIn 0.3s ease; }
        .tab-content.active { display: block; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
        .card { background: var(--bg-card); border-radius: 16px; padding: 16px; margin-bottom: 12px; border: 1px solid var(--border); backdrop-filter: blur(12px); }
        .card-title { font-size: 0.65rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--text-muted); margin-bottom: 12px; }
        .stats { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
        .stats-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
        .stats-4 { display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 8px; }
        .stat { background: var(--bg-elevated); border-radius: 12px; padding: 14px 10px; text-align: center; border: 1px solid var(--border); }
        .stat-val { font-size: 1.8rem; font-weight: 700; background: linear-gradient(135deg, var(--accent) 0%, var(--emerald) 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .stat-val-sm { font-size: 1.4rem; font-weight: 700; background: linear-gradient(135deg, var(--accent) 0%, var(--cyan) 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .stat-label { font-size: 0.65rem; color: var(--text-muted); margin-top: 3px; }
        .dim { display: flex; align-items: center; padding: 10px 0; border-bottom: 1px solid var(--border); }
        .dim:last-child { border: none; }
        .dim-icon { width: 28px; font-size: 1rem; }
        .dim-name { flex: 1; font-size: 0.82rem; font-weight: 500; }
        .dim-sub { font-size: 0.72rem; color: var(--text-muted); display: block; margin-top: 2px; }
        .dim-bar { width: 90px; height: 6px; background: var(--bg-elevated); border-radius: 3px; margin: 0 10px; overflow: hidden; flex-shrink: 0; }
        .dim-fill { height: 100%; border-radius: 3px; transition: width 0.5s ease; }
        .dim-val { width: 38px; text-align: right; font-size: 0.78rem; color: var(--text-secondary); font-variant-numeric: tabular-nums; }
        .list-item { display: flex; align-items: flex-start; gap: 10px; padding: 10px 0; border-bottom: 1px solid var(--border); }
        .list-item:last-child { border: none; }
        .badge { background: var(--bg-elevated); padding: 3px 8px; border-radius: 8px; font-size: 0.68rem; font-weight: 600; text-transform: capitalize; white-space: nowrap; border: 1px solid var(--border); flex-shrink: 0; }
        .badge-chunked, .badge-low { border-color: #10b981; color: #10b981; }
        .badge-active, .badge-moderate  { border-color: #f59e0b; color: #f59e0b; }
        .badge-forming, .badge-elevated { border-color: #f97316; color: #f97316; }
        .badge-critical { border-color: #dc2626; color: #f87171; }
        .list-text { flex: 1; font-size: 0.78rem; color: var(--text-secondary); line-height: 1.5; }
        .list-sub { font-size: 0.7rem; color: var(--text-muted); margin-top: 2px; }
        .steps { font-size: 0.7rem; color: var(--text-muted); margin-top: 3px; line-height: 1.5; }
        .step-arrow { color: var(--accent); margin: 0 2px; }
        .tags { display: flex; flex-wrap: wrap; gap: 8px; }
        .tag { background: var(--bg-elevated); padding: 6px 12px; border-radius: 20px; font-size: 0.75rem; color: var(--text-secondary); border: 1px solid var(--border); }
        .sup-tag { background: rgba(239,68,68,0.08); border-color: rgba(239,68,68,0.3); color: #f87171; font-size: 0.75rem; padding: 6px 12px; border-radius: 20px; border: 1px solid; }
        .flag-item { background: var(--bg-elevated); border-left: 3px solid var(--amber); border-radius: 0 10px 10px 0; padding: 10px 12px; margin-bottom: 8px; font-size: 0.78rem; }
        .quadrant { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
        .q-cell { background: var(--bg-elevated); border-radius: 12px; padding: 14px 10px; text-align: center; border: 1px solid var(--border); transition: all 0.3s; }
        .q-cell .emoji { font-size: 1.5rem; margin-bottom: 4px; }
        .q-cell .label { font-size: 0.75rem; font-weight: 500; }
        .q-cell.active { border-color: var(--accent); background: linear-gradient(135deg, rgba(168,85,247,0.15), rgba(236,72,153,0.1)); box-shadow: 0 0 20px var(--accent-glow); transform: scale(1.02); }
        .drive-meter { text-align: center; padding: 24px 16px; }
        .drive-val { font-size: 3.5rem; font-weight: 700; background: linear-gradient(135deg, var(--amber) 0%, #ef4444 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .drive-label { font-size: 0.85rem; color: var(--text-muted); margin-top: 4px; }
        .drive-bar { height: 8px; background: var(--bg-elevated); border-radius: 4px; margin-top: 16px; overflow: hidden; }
        .drive-fill { height: 100%; background: linear-gradient(90deg, var(--amber) 0%, #ef4444 100%); border-radius: 4px; transition: width 0.5s; box-shadow: 0 0 12px rgba(245,158,11,0.4); }
        .empty { color: var(--text-muted); text-align: center; padding: 20px; font-size: 0.85rem; }
        .install-prompt { text-align: center; padding: 32px 16px; }
        .install-prompt .icon { font-size: 3rem; margin-bottom: 12px; opacity: 0.4; }
        .install-prompt p { color: var(--text-muted); font-size: 0.9rem; margin-bottom: 8px; }
        .install-prompt code { display: inline-block; background: var(--bg-elevated); padding: 10px 16px; border-radius: 8px; font-size: 0.8rem; border: 1px solid var(--border); margin-top: 8px; }
        .footer { text-align: center; margin-top: 24px; padding-top: 16px; font-size: 0.7rem; color: var(--text-muted); }
        .footer a { color: var(--accent); text-decoration: none; }
        .footer a:hover { color: var(--pink); }
        .statusbar { display: flex; align-items: center; gap: 14px; padding: 10px 14px; margin-bottom: 16px; background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; font-size: 0.72rem; color: var(--text-muted); flex-wrap: wrap; backdrop-filter: blur(8px); }
        .statusbar-item { display: flex; align-items: center; gap: 6px; }
        .statusbar-item.warn { color: #f59e0b; }
        .beat-dot { width: 10px; height: 10px; border-radius: 50%; background: var(--text-muted); transition: background 0.3s, box-shadow 0.3s; }
        .beat-dot.alive { background: var(--emerald); box-shadow: 0 0 8px rgba(16,185,129,0.7); }
        .beat-dot.stale { background: var(--amber); box-shadow: 0 0 8px rgba(245,158,11,0.5); }
        .beat-dot.down { background: #ef4444; box-shadow: 0 0 8px rgba(239,68,68,0.6); }
        .regen-btn { margin-left: auto; background: var(--bg-elevated); border: 1px solid var(--border); color: var(--text-secondary); font-size: 0.72rem; font-weight: 600; padding: 6px 14px; border-radius: 10px; cursor: pointer; transition: all 0.2s; }
        .regen-btn:hover { border-color: var(--accent); color: var(--text); box-shadow: 0 0 12px var(--accent-glow); }
        .regen-btn:disabled { opacity: 0.5; cursor: wait; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <div class="avatar-wrap">
HTMLHEAD

if [ -n "$AVATAR_BASE64" ]; then
    echo "            <img src=\"$AVATAR_BASE64\" class=\"avatar\">" >> "$OUTPUT_FILE"
else
    echo "            <div class=\"avatar-placeholder\">🧠</div>" >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" << HEADER
            <div class="status-dot" style="background: var(--accent);"></div>
        </div>
        <div class="header-info">
            <h1>$AGENT_NAME</h1>
            <div class="subtitle">Brain Dashboard</div>
        </div>
    </div>

    <div class="statusbar">
        <div class="statusbar-item"><span class="beat-dot" id="statusDot"></span><span id="statusBeat">💓 beat —</span></div>
        <div class="statusbar-item"><span id="statusJob">⚙️ job —</span></div>
        <div class="statusbar-item"><span id="statusFrags">🧩 fragments —</span></div>
        <div class="statusbar-item"><span id="statusHealth">✅ —</span></div>
        <button class="regen-btn" id="regenBtn" title="Run every skill's sync-state.sh, then rebuild the dashboard">🔄 Regenerate</button>
    </div>

    <div class="tabs">
HEADER

# ── Tab buttons ───────────────────────────────────────────────────────────────
for i in $SORTED_IDX; do
    id="${TAB_IDS[$i]}"; label="${TAB_LABELS[$i]}"; icon="${TAB_ICONS[$i]}"
    echo "        <button class=\"tab\" data-tab=\"$id\"><span class=\"tab-icon\">$icon</span> $label</button>" >> "$OUTPUT_FILE"
done
echo "    </div>" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# ── Tab content + collected JS ───────────────────────────────────────────────
JS_STATE_ENTRIES=""
JS_SCRIPTS=""

for i in $SORTED_IDX; do
    id="${TAB_IDS[$i]}"; label="${TAB_LABELS[$i]}"; icon="${TAB_ICONS[$i]}"; slug="${TAB_SLUGS[$i]}"
    FRAG_FILE="$FRAGMENTS_DIR/$id.json"

    echo "    <!-- $label tab -->" >> "$OUTPUT_FILE"
    echo "    <div class=\"tab-content\" id=\"tab-$id\">" >> "$OUTPUT_FILE"

    if [ -f "$FRAG_FILE" ]; then
        jq -r '.html // ""' "$FRAG_FILE" >> "$OUTPUT_FILE"
        FRAG_DATA=$(jq -c '.data // {}' "$FRAG_FILE")
        FRAG_SCRIPT=$(jq -r '.script // ""' "$FRAG_FILE")
        JS_STATE_ENTRIES="${JS_STATE_ENTRIES}    \"$id\": $FRAG_DATA,
"
        JS_SCRIPTS="${JS_SCRIPTS}
// --- $id ---
try {
$FRAG_SCRIPT
} catch (e) { console.error('[brain-dashboard] $id tab script failed:', e); }
"
    else
        cat >> "$OUTPUT_FILE" << INSTALLPROMPT
        <div class="card">
            <div class="install-prompt">
                <div class="icon">$icon</div>
                <p><strong>${label}</strong> hasn't published a dashboard fragment yet</p>
                <p style="font-size:0.85em;opacity:0.7">(installed skills not yet migrated to the fragment format run their own generate-dashboard.sh instead)</p>
                <code>clawdhub install $slug</code>
            </div>
        </div>
INSTALLPROMPT
        JS_STATE_ENTRIES="${JS_STATE_ENTRIES}    \"$id\": { installed: null },
"
    fi

    echo "    </div>" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
done

{
cat << 'FOOTER'
    <div class="footer">Part of the <a href="https://github.com/ImpKind">AI Brain Series</a> 🧠</div>
</div>
<script>
FOOTER

# First tab id by order (deterministic fallback)
FIRST_ID=""
for i in $SORTED_IDX; do FIRST_ID="${TAB_IDS[$i]}"; break; done

cat << JSDATA
const state = {
$JS_STATE_ENTRIES};
const FOCUS_HINT = $(jq -Rn --arg v "$FOCUS_ID" '$v');
const FIRST_TAB = $(jq -Rn --arg v "$FIRST_ID" '$v');
JSDATA

cat << 'JSCORE'

function activateTab(id) {
    const btn = document.querySelector(`.tab[data-tab="${id}"]`);
    const content = document.getElementById('tab-' + id);
    if (!btn || !content) return false;
    document.querySelectorAll('.tab').forEach(x => x.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(x => x.classList.remove('active'));
    btn.classList.add('active');
    content.classList.add('active');
    return true;
}

document.querySelectorAll('.tab').forEach(t => t.addEventListener('click', () => {
    activateTab(t.dataset.tab);
    try { localStorage.setItem('brainDashboardTab', t.dataset.tab); } catch (e) {}
}));

// Initial tab precedence: what the human last actually clicked (localStorage)
// > which skill's pipeline just regenerated this file (FOCUS_HINT)
// > lowest-order tab (deterministic default)
let savedTab = null;
try { savedTab = localStorage.getItem('brainDashboardTab'); } catch (e) {}
activateTab(savedTab) || activateTab(FOCUS_HINT) || activateTab(FIRST_TAB);

// ── Live status bar: daemon heartbeat + last job + fragment count ──────
// Backed by the serve-mode server's /__daemon + /__fragments endpoints; the
// Regenerate button POSTs to /__regenerate with the server-injected token.
// Works when served by scripts/serve-dashboard.sh; degrades to static text
// when the file is opened directly (fetch fails are swallowed).
const STATUS_POLL_MS = 10000;
const fmtAgo = (iso) => {
  if (!iso) return '—';
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return s + 's ago';
  if (s < 3600) return Math.round(s / 60) + 'm ago';
  if (s < 86400) return Math.round(s / 3600) + 'h ago';
  return Math.round(s / 86400) + 'd ago';
};

function setStatus(id, text, cls) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.className = 'statusbar-item' + (cls ? ' ' + cls : '');
}

function pollStatus() {
  fetch('/__daemon?t=' + Date.now(), { cache: 'no-store' })
    .then(r => r.json())
    .then(d => {
      const dot = document.getElementById('statusDot');
      if (dot) {
        const ageH = (d.heartbeat && d.heartbeat.lastBeat)
          ? (Date.now() - new Date(d.heartbeat.lastBeat).getTime()) / 3600000
          : 999;
        dot.className = 'beat-dot ' + (ageH < 2 ? 'alive' : ageH < 24 ? 'stale' : 'down');
      }
      setStatus('statusBeat', '💓 beat ' + ((d.heartbeat && d.heartbeat.lastBeat) ? fmtAgo(d.heartbeat.lastBeat) : '—'));
      const lj = d.summary && d.summary.lastJobRun;
      setStatus('statusJob', lj ? '⚙️ ' + lj.name + ' · ' + fmtAgo(lj.at) : '⚙️ no runs yet');
      if (d.summary && d.summary.unhealthyJobs && d.summary.unhealthyJobs.length) {
        setStatus('statusHealth', '⚠️ ' + d.summary.unhealthyJobs.length + ' unhealthy', 'warn');
      } else {
        setStatus('statusHealth', '✅ all healthy');
      }
    })
    .catch(() => { setStatus('statusBeat', '💓 daemon offline'); });

  fetch('/__fragments?t=' + Date.now(), { cache: 'no-store' })
    .then(r => r.json())
    .then(d => {
      setStatus('statusFrags', '🧩 ' + d.count + ' fragments');
      const sig = (d.fragments || []).map(f => f.id + ':' + f.mtime_ns).join('|');
      if (window.__fragSig && sig && sig !== window.__fragSig) { location.reload(); return; }
      if (sig) window.__fragSig = sig;
    })
    .catch(() => {});
}

const regenBtn = document.getElementById('regenBtn');
if (regenBtn) {
  regenBtn.addEventListener('click', () => {
    if (!window.__DASH_TOKEN) { console.warn('regen requires the served dashboard (serve-dashboard.sh start)'); return; }
    regenBtn.disabled = true;
    regenBtn.textContent = '♻️ Regenerating…';
    fetch('/__regenerate', {
      method: 'POST',
      headers: { 'X-Dashboard-Token': window.__DASH_TOKEN },
    })
      .then(r => {
        // Token is per-server-session and injected into the page; after a
        // server restart the page holds a stale token. Reload to pick up
        // the fresh injected token instead of leaving the button dead.
        if (r.status === 401 || r.status === 403) { location.reload(); return; }
        return r.json();
      })
      .then(d => { if (d) location.reload(); })
      .catch(err => { regenBtn.disabled = false; regenBtn.textContent = '🔄 Regenerate'; console.error(err); });
  });
}

pollStatus();
setInterval(pollStatus, STATUS_POLL_MS);
JSCORE

echo "$JS_SCRIPTS"

cat << 'JSEND'
</script>
</body>
</html>
JSEND
} >> "$OUTPUT_FILE"

echo "🧠 Dashboard generated: $OUTPUT_FILE"
