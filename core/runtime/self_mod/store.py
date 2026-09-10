#!/usr/bin/env python3
"""Proposal persistence — the heart's memory between beats.

Proposals live as JSON documents under ``{root}/proposals/{id}.json``.
The heartbeat loads them, advances each through its automatable stages,
and saves them back. A beat never loses a proposal's place in the
pipeline: the store is the continuity the rhythm depends on.

Writes are atomic (tmp + rename). IDs are sanitized to a safe charset so
a hostile id can never escape the directory.
"""

from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path

from .proposal import Proposal


_SAFE_ID = re.compile(r"[^A-Za-z0-9_.-]+")


def _safe_id(proposal_id: str) -> str:
    cleaned = _SAFE_ID.sub("_", proposal_id).strip("._")
    if not cleaned:
        raise ValueError(f"proposal id {proposal_id!r} has no safe form")
    return cleaned


class ProposalStore:
    """JSON-file proposal store rooted at ``root/proposals``."""

    def __init__(self, root: Path | str):
        self.dir = Path(root) / "proposals"
        self.dir.mkdir(parents=True, exist_ok=True)

    def _path(self, proposal_id: str) -> Path:
        return self.dir / f"{_safe_id(proposal_id)}.json"

    def save(self, proposal: Proposal) -> Path:
        """Atomic save. Returns the document path."""
        path = self._path(proposal.id)
        payload = json.dumps(proposal.to_dict(), indent=2) + "\n"
        with tempfile.NamedTemporaryFile("w", dir=self.dir,
                                         delete=False,
                                         encoding="utf-8") as tmp:
            tmp.write(payload)
            tmp_path = Path(tmp.name)
        tmp_path.replace(path)
        return path

    def load(self, proposal_id: str) -> Proposal | None:
        path = self._path(proposal_id)
        try:
            return Proposal.from_dict(
                json.loads(path.read_text(encoding="utf-8")))
        except FileNotFoundError:
            return None
        except (json.JSONDecodeError, KeyError, ValueError):
            # A corrupt document never breaks the beat; it is reported
            # and left for the agent to inspect.
            raise

    def all(self) -> list[Proposal]:
        out: list[Proposal] = []
        for path in sorted(self.dir.glob("*.json")):
            try:
                out.append(Proposal.from_dict(
                    json.loads(path.read_text(encoding="utf-8"))))
            except (json.JSONDecodeError, KeyError, ValueError):
                continue  # corrupt docs are skipped, never fatal
        return out

    def ids(self) -> list[str]:
        return [p.stem for p in sorted(self.dir.glob("*.json"))]
