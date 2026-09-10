# Juno Immutable Rules

Dyther's hard rules, in one place, in a form both humans and the
self-modification pipeline can read. The `````rules`` block below is
**machine-readable**: `tiers.py` parses it at import (`id`, `statement`,
`triggers`, `effect`). Human prose lives outside the block; the block is
the source of truth for enforcement.

```rules
id: no-kernel-change
statement: Never change the kernel on codypc. Kernel packages are apt-mark held (Dyther held two himself before the rest were added).
triggers: \bkernel\b ;; linux-image ;; linux-headers ;; kernel.*(upgrade|install|change|held|hold)
effect: escalate
---
id: no-nvidia-driver-change
statement: Never change the Nvidia driver on codypc.
triggers: nvidia.?driver ;; driver.*(upgrade|install|change|held|hold)
effect: escalate
---
id: gpu-roles
statement: RX 5700 XT is inference/compute only; Quadro K600 is display only. Never blur the roles. No ROCm on RDNA1/gfx1010; Mesa RADV Vulkan is the compute path.
triggers: \bGPU\b.*(reassign|repurpose|swap) ;; quadro.*comput ;; 5700.*display ;; rocm ;; blur.*role
effect: escalate
---
id: no-reboot-without-approval
statement: Never reboot codypc (or Dyther's PC generally) without his explicit approval.
triggers: \breboot\b ;; \bshutdown\b ;; systemctl.*reboot
effect: escalate
---
id: cost-is-live-constraint
statement: Cost is a live constraint on every technical decision. Never assume purchases, subscriptions, cloud spend, or hardware upgrades.
triggers: \bbuy\b ;; purchas ;; subscri ;; cloud.*(spend|instance|deploy) ;; hardware.*upgrad ;; \$[0-9]
effect: escalate```

## Enforcement semantics

- `effect: escalate` — if a proposal's target, change description, or
  rationale matches any trigger, the proposal is escalated to Tier 1
  (Dyther-gated) and the matched rule ids are recorded on the proposal as
  `hard_rule_flags`. Escalation never silently passes.
- These rules constrain *proposals*, including proposals whose text merely
  *describes* violating actions (e.g. "document the kernel upgrade steps"
  still trips `no-kernel-change` — the pipeline does not interpret intent,
  it matches text; false positives escalate to Dyther, which is the
  fail-safe direction).
- Adding or removing a rule here is itself a Tier 1 change (this file is
  not immutable — Dyther can revise his rules — but the pipeline can never
  revise them on its own authority).
