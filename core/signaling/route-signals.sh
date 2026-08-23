#!/bin/bash
# route-signals.sh — The brain's "white matter tracts."
#
# This is the canonical signal routing table. When a skill emits a signal
# (via publish.sh), the thalamus consults this table to determine which
# downstream skills should receive it and at what intensity.
#
# Output: JSON array of {source, signal, target_module, target_script, args_template}
# for every known cross-module signal path. Read by thalamus/gate.sh.
#
# NEW SKILLS: add your signal routes here. This is the ONE place to register
# cross-module coupling — don't hardcode skill-A-calls-skill-B anywhere else.

set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/.hermes/workspace}"
SKILLS_DIR="${WORKSPACE}/skills"

# ── Routing Table ───────────────────────────────────────────────────────
# Format: source_module | source_signal | target_module | target_script | arg_template
#
# arg_template uses {intensity}, {source}, {signal}, {payload_key} placeholders
# that gate.sh fills in at dispatch time.
#
# This table is the machine-readable version of every "Signal to Send" section
# currently documented in each skill's SKILL.md.

cat <<'TABLE'
amygdala-memory|positive_state|vta-memory|scripts/log-reward.sh|--type social --intensity {energy} --source "positive emotional state"
amygdala-memory|fatigue|vta-memory|scripts/decay-drive.sh|
insula-memory|discord|amygdala-memory|scripts/update-state.sh|--emotion anxiety --intensity {intensity} --trigger "gut discord"
insula-memory|resonance|amygdala-memory|scripts/update-state.sh|--emotion connection --intensity {intensity} --trigger "empathic resonance"
insula-memory|flow|vta-memory|scripts/log-reward.sh|--type competence --intensity 0.2 --source "flow state detected"
insula-memory|depletion|vta-memory|scripts/decay-drive.sh|
insula-memory|overwhelm|vta-memory|scripts/decay-drive.sh|
anterior-cingulate-memory|conflict_logged|insula-memory|scripts/update-state.sh|--signal strain --intensity {intensity} --source "conflict detected: {payload_type}"
anterior-cingulate-memory|conflict_resolved|insula-memory|scripts/update-state.sh|--signal ease --intensity 0.4 --source "conflict resolved"
anterior-cingulate-memory|critical_load|vta-memory|scripts/decay-drive.sh|
acc-error-memory|critical_pattern|amygdala-memory|scripts/update-state.sh|--emotion frustration --intensity 0.4 --trigger "critical error pattern: {signal}"
acc-error-memory|pattern_resolved|amygdala-memory|scripts/update-state.sh|--emotion satisfaction --intensity 0.5 --trigger "error pattern resolved: {signal}"
acc-error-memory|recurring_pattern|basal-ganglia-memory|reinforce-habit.sh|--suppress "{payload_pattern}" --reason "{payload_mitigation}" --strength 0.7
acc-error-memory|critical_pattern|insula-memory|scripts/update-state.sh|--signal vigilance --intensity 0.6 --source "critical error patterns active"
acc-error-memory|clean_analysis|vta-memory|scripts/log-reward.sh|--type competence --intensity 0.3 --source "clean ACC error analysis run"
vta-memory|reward_received|amygdala-memory|scripts/update-state.sh|--emotion joy --intensity {intensity} --trigger "reward: {payload_type}"
basal-ganglia-memory|habit_fired|vta-memory|scripts/log-reward.sh|--type competence --intensity 0.5 --source "habit fired: {signal}"
basal-ganglia-memory|habit_success|amygdala-memory|scripts/update-state.sh|--emotion satisfaction --intensity 0.3 --trigger "habit success: {signal}"
prefrontal-cortex-memory|goal_promoted|thalamus-memory|scripts/gate.sh|--boost-goal "{payload_description}"
prefrontal-cortex-memory|goal_achieved|vta-memory|scripts/log-reward.sh|--type accomplishment --intensity 0.7 --source "goal achieved: {payload_description}"
prefrontal-cortex-memory|goal_achieved|amygdala-memory|scripts/update-state.sh|--emotion joy --intensity 0.6 --trigger "goal achieved"
hippocampus-memory|significant_memory|insula-memory|scripts/update-state.sh|--signal expansion --intensity 0.3 --source "significant memory encoded"
# ── Learning-signal propagation (the new mechanism fields cross regions) ──
# VTA RPE → ACC: a notable reward-prediction error means the world is more
# volatile than expected — the ACC flags that reward domain for attention
# (Botvinick conflict monitoring; Holroyd & Coles ERN-style surprise).
vta-memory|rpe_logged|anterior-cingulate-memory|scripts/flag-attention.sh|--add "rpe_{payload_type}" --reason "reward prediction error"
# Amygdala salience → hippocampus: a high-salience tag (McGaugh memory
# enhancement) boosts the encoding weight of that domain downstream — the
# amygdala's computational output is a tag that biases encoding strength.
amygdala-memory|salience_tag|hippocampus-memory|scripts/note-salience.sh|--emotion {payload_type} --salience {intensity}
# Insula discrepancy → PFC: a high interoceptive prediction error (Craig's
# predictive-coding model; Critchley's confidence extension) lowers executive
# confidence — the body's "something's off" signal damps decision scores.
insula-memory|interoceptive_discrepancy|prefrontal-cortex-memory|scripts/note-uncertainty.sh|--value {intensity}
cerebellum-memory|calibration_drift|insula-memory|scripts/update-state.sh|--signal vigilance --intensity 0.4 --source "execution calibration drift detected"
heartbeat-memory|action_chosen|insula-memory|scripts/update-state.sh|--signal ease --intensity 0.2 --source "autonomous action chosen: {signal}"
social-memory|trust_shift|amygdala-memory|scripts/update-state.sh|--emotion connection --intensity {intensity} --trigger "relationship trust shift: {signal}"
thalamus-memory|attention_shift|insula-memory|scripts/update-state.sh|--signal vigilance --intensity {intensity} --source "attentional shift: {signal}"
thalamus-memory|gate_suppressed|insula-memory|scripts/update-state.sh|--signal ease --intensity 0.15 --source "signal suppressed by attention gate"
# ── Verification region (proprioception): manifest-driven test execution ──
# Inbound: a module's key signals re-trigger that module's own declared tests.
# {source} resolves to the emitting module, so run-module-tests.sh re-verifies
# exactly the region that just acted. Cooldown in run-module-tests.sh prevents storms.
prefrontal-cortex-memory|goal_promoted|verification-memory|scripts/run-module-tests.sh|--module {source}
cerebellum-memory|calibration_drift|verification-memory|scripts/run-module-tests.sh|--module {source}
hippocampus-memory|significant_memory|verification-memory|scripts/run-module-tests.sh|--module {source}
heartbeat-memory|action_chosen|verification-memory|scripts/run-module-tests.sh|--module {source}
acc-error-memory|pattern_resolved|verification-memory|scripts/run-module-tests.sh|--module {source}
# Outbound: green suites are rewarding, red suites feed error + emotion systems.
# NOTE: gate.sh word-splits arg templates, so args must be single tokens.
# {payload_pattern} / {payload_description} come from run-declared-tests.sh's
# publish payload (pattern = the failing owner:path, single-token).
verification-memory|tests_passed|vta-memory|scripts/log-reward.sh|--type competence --intensity 0.4 --source all_declared_tests_green
verification-memory|test_failure|acc-error-memory|scripts/log-error.sh|--pattern {payload_pattern} --context verification_failure
verification-memory|test_failure|amygdala-memory|scripts/update-state.sh|--emotion frustration --intensity {intensity} --trigger test_failure
TABLE

exit 0
