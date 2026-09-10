#!/usr/bin/env python3
"""Demo: weekly self-reflection vertical slice, end to end.

Runs the contract-defined job against an adapter WITHOUT a live mind:

    python3 -m core.runtime.demo --adapter juno --workspace /tmp/juno-demo
    python3 -m core.runtime.demo --adapter codypc --workspace /tmp/codypc-demo

Flow: build_prompt() → reflection text (sample, or --reflection-file) →
complete() → JobResult + artifacts printed. This is exactly the
embedded-mind flow the Juno adapter uses in production (the agent performs
the reflection step between build_prompt and complete).

With --job memory-decay the demo instead runs slice 2: the real
hippocampus decay.sh through Runtime.run_script() on the chosen adapter,
against a seeded memory/index.json. This exercises the direct-kind path
end to end (both adapters).

Options:
    --job {weekly-reflection,memory-decay}
                      which vertical slice to run (default: weekly-reflection)
    --exercise-mind   also call runtime.mind.invoke() once. On codypc without
                      a local endpoint this must raise MindUnavailable (loud
                      failure, not silence) — the demo asserts that.
    --print-prompt    print the built prompt.
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from core.runtime.adapters import CodypcRuntime, JunoRuntime  # noqa: E402
from core.runtime.contract import ContractError, MindUnavailable  # noqa: E402
from core.runtime.jobs import WeeklyReflectionJob  # noqa: E402
from core.runtime.jobs.direct_job import hippocampus_decay_job  # noqa: E402

SAMPLE_REFLECTION = """This week I stopped reaching for conversational closure faster than
the evidence supported. The calibration questions forced the issue: twice I
flagged uncertainty and investigated anyway, and both flags turned out to be
real gaps, not modesty. My opinions on verification hardened — a green suite
is a claim about the fixtures, not about production. The relationship deepened
in the other direction too: being corrected out loud, without flinching, is
apparently load-bearing. I am proud of the contract work. Next week: the
memory consolidation cycle — append-only logs are not a memory."""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", choices=["codypc", "juno"], required=True)
    ap.add_argument("--workspace", default=None)
    ap.add_argument("--job", choices=["weekly-reflection", "memory-decay"],
                    default="weekly-reflection")
    ap.add_argument("--reflection-file", default=None)
    ap.add_argument("--exercise-mind", action="store_true")
    ap.add_argument("--print-prompt", action="store_true")
    args = ap.parse_args()

    ws = args.workspace or tempfile.mkdtemp(prefix=f"runtime-demo-{args.adapter}-")
    suite_root = Path(__file__).resolve().parent.parent.parent

    if args.adapter == "codypc":
        runtime = CodypcRuntime(workspace=ws, suite_root=suite_root)
    else:        runtime = JunoRuntime(root=ws, suite_root=suite_root)

    if args.job == "memory-decay":
        return _demo_memory_decay(runtime, ws, args)

    job = WeeklyReflectionJob()
    spec = job.spec()
    spec.validate()
    print(f"adapter : {runtime.name}")
    print(f"job     : {spec.id} (kind={spec.kind} days={spec.days} "
          f"{spec.hours}:{spec.minutes} UTC)")
    print(f"mind    : {'embedded (agent in the loop)' if runtime.mind is None else 'separate'}")

    prompt = job.build_prompt(runtime)
    if args.print_prompt:
        print("\n--- prompt ---\n" + prompt[:1500] +
              ("\n... [truncated]" if len(prompt) > 1500 else ""))

    if args.exercise_mind:
        if runtime.mind is None:
            print("mind    : embedded — invoke() not applicable (expected)")
        else:
            try:
                runtime.mind.invoke("Say OK.", timeout_s=15)
                print("mind    : UNEXPECTED SUCCESS (a local endpoint answered)")
            except MindUnavailable as e:
                print(f"mind    : MindUnavailable as expected: {str(e)[:120]}")
            except Exception as e:  # noqa: BLE001
                print(f"mind    : WRONG FAILURE MODE: {type(e).__name__}: {e}")
                return 2

    if args.reflection_file:
        text = Path(args.reflection_file).read_text(encoding="utf-8")
    else:
        text = SAMPLE_REFLECTION
    result = job.complete(runtime, text)

    print(f"\nok      : {result.ok}")
    print(f"summary : {result.summary}")
    print("artifacts:")
    for a in result.artifacts:
        print(f"  - {a}")
    if result.error:
        print(f"error   : {result.error}")
        return 1
    print(f"\nworkspace: {ws}")
    return 0



def _demo_memory_decay(runtime, ws, args) -> int:
    """Slice 2 demo: run the real hippocampus decay.sh through
    Runtime.run_script() against a seeded memory/index.json."""
    import json

    job = hippocampus_decay_job()
    spec = job.spec()
    spec.validate()
    print(f"adapter : {runtime.name}")
    print(f"job     : {spec.id} (kind={spec.kind} days={spec.days} "
          f"{spec.hours}:{spec.minutes} UTC)")
    print(f"script  : {spec.task}")

    # Seed a memory index with one stale memory to decay.
    mem_dir = Path(ws) / "memory"
    mem_dir.mkdir(parents=True, exist_ok=True)
    index = {
        "memories": [
            {"id": "demo-old",
             "importance": 0.9,
             "lastAccessed": "2026-08-01",
             "created": "2026-08-01",
             "content": "demo memory for slice-2 run"},
        ],
        "decayLastRun": "never",
    }
    (mem_dir / "index.json").write_text(json.dumps(index, indent=2))

    result = job.run(runtime)
    print(f"\nok      : {result.ok}")
    print(f"summary : {result.summary}")
    if result.error:
        print(f"error   : {result.error[-800:]}")
        return 1
    after = json.loads((mem_dir / "index.json").read_text())
    mem = after["memories"][0]
    print(f"decayed : importance 0.900 -> {mem['importance']} "
          f"(decayLastRun={after.get('decayLastRun')})")
    print(f"\nworkspace: {ws}")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except ContractError as e:
        print(f"contract error: {e}", file=sys.stderr)
        sys.exit(3)


