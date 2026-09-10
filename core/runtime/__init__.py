"""Runtime contract — substrate-independent interface for the AI Brain Suite.

See RUNTIME_CONTRACT.md. Reference implementation: contract.py.
Adapters: adapters/codypc.py (Linux host, existing path preserved),
adapters/juno.py (AI-assistant agent runtime, embedded-mind pattern).
"""

from .contract import (
    CONTRACT_VERSION,
    IMMUTABLE_CORE_PATTERNS,
    ContractError,
    ContractJob,
    JobResult,
    JobSpec,
    MemoryStore,
    MemoryViolation,
    Mind,
    MindUnavailable,
    Runtime,
    ScheduleError,
    Scheduler,
)

__all__ = [
    "CONTRACT_VERSION",
    "IMMUTABLE_CORE_PATTERNS",
    "ContractError",
    "ContractJob",
    "JobResult",
    "JobSpec",
    "MemoryStore",
    "MemoryViolation",
    "Mind",
    "MindUnavailable",
    "Runtime",
    "ScheduleError",
    "Scheduler",
]
