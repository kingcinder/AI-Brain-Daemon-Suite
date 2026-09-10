#!/usr/bin/env python3
"""Production wiring for the Juno runtime — the sewn-up incision.

Constructs the substrate-independent runtime against the agent's REAL
directories (not test sandboxes):

  * memory store  -> the agent's live memory tree (~/memory)
  * self-mod      -> ~/workspace/skills (skills scope),
                     ~/memory (memory scope)

This module constructs only. It submits no proposals, approves nothing,
and starts no autonomous loop. The heart beats when a prompt source
(the weekly reflection, the agent, or Dyther directly) submits the first
proposal — every one of which still passes through verify -> gate ->
apply -> monitor, with Tier 1 gated per the graduation bands.

Usage (from the repo root):
    python3 -c "
    from core.runtime.juno_main import get_pipeline
    pipe = get_pipeline()  # constructed; nothing submitted, nothing applied
    "
"""

from __future__ import annotations

from pathlib import Path

from .adapters.juno import JunoRuntime
from .self_mod.pipeline import Pipeline


def get_runtime() -> JunoRuntime:
    """The live Juno runtime. Defaults already target the real trees;
    spelled out here so production wiring is explicit, not accidental."""
    home = Path.home()
    return JunoRuntime(
        root=home / ".juno-brain",
        # suite_root defaults to the repo containing this file
        skills_root=home / "workspace" / "skills",
        memory_root=home / "memory",
    )


def get_pipeline(runtime: JunoRuntime | None = None) -> Pipeline:
    """The beating heart, constructed against the live runtime.
    Construction only — no proposals, no approvals, no loop."""
    rt = get_runtime() if runtime is None else runtime
    return Pipeline(rt, rt.self_mod)
