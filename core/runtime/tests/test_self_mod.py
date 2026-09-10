#!/usr/bin/env python3
"""Self-mod pipeline tests — stdlib only, temp dirs only, never the live runtime.

Run: python3 -m unittest core.runtime.tests.test_self_mod -v
(from the repo root).

What these prove:
  (a) proposals targeting immutable paths are rejected;
  (b) failed verification blocks apply;
  (c) rollback restores prior state byte-for-byte (hash-proven);
  (d) a Tier 1 proposal without Dyther's approval does not apply.
Plus: tier classification, hard-rule escalation, traversal rejection,
agent-check gating, monitor auto-rollback, cron plan emission,
prompt_source enforcement (nothing unprompted), graduation bands
(Tier 1 requirements shrink with clean streak; tripwires never graduate),
streak accounting (clean monitor increments, rollback resets), and
approval revocation (no expiry; revocation never auto-rolls-back).
"""

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent.parent
sys.path.insert(0, str(ROOT))

from core.runtime.adapters import JunoRuntime  # noqa: E402
from core.runtime.self_mod import (  # noqa: E402
    GateRefused, ImmutableTargetError, JunoSelfMod, Pipeline, Proposal,
    StatusTransitionError, Tier, assert_mutable_target, classify,
    is_immutable_target,
)
from core.runtime.self_mod.apply import sha256_file  # noqa: E402


def make_proposal(pid, scope="memory", target="conventions.md",
                  change_kind="text", change="tweak wording",
                  rationale="review found the convention unclear",
                  new_content="new conventions text\n",
                  verification_plan=None, rollback_plan="restore from backup",
                  prompt_source="dyther_direct"):
    return Proposal(
        id=pid, scope=scope, target=target, change_kind=change_kind,
        change=change, rationale=rationale, new_content=new_content,
        verification_plan=verification_plan or [],
        rollback_plan=rollback_plan, prompt_source=prompt_source)


class SelfModTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="selfmod-test-")
        base = Path(self.tmp.name)
        (base / "skills").mkdir()
        (base / "memory").mkdir()
        # A seed file to modify in tests.
        (base / "memory" / "conventions.md").write_text(
            "original conventions\n", encoding="utf-8")
        (base / "skills" / "demo").mkdir()
        (base / "skills" / "demo" / "SKILL.md").write_text(
            "# Demo skill\n", encoding="utf-8")
        self.rt = JunoRuntime(root=str(base / "rt"))
        self.cap = JunoSelfMod(
            self.rt,
            skills_root=str(base / "skills"),
            memory_root=str(base / "memory"),
            plans_dir=str(base / "plans"),
            backup_root=str(base / "backups"))
        self.pipe = Pipeline(self.rt, self.cap)

    def tearDown(self):
        self.tmp.cleanup()

    # -- (a) immutable targets are rejected -----------------------------------
    def test_trust_anchor_all_rejected(self):
        for target in ("core/runtime/contract.py",
                       "core/runtime/RUNTIME_CONTRACT.md",
                       "core/runtime/schedule.py",
                       "core/runtime/self_mod/tiers.py",
                       "core/runtime/self_mod/pipeline.py"):
            with self.assertRaises(ImmutableTargetError, msg=target):
                assert_mutable_target(target)
            self.assertIsNotNone(is_immutable_target(target), target)

    def test_immutable_rejected_at_submit(self):
        # traversal is refused at construction...
        with self.assertRaises(ValueError):
            make_proposal("p-imm", scope="skills",
                          target="../../repo/core/runtime/contract.py")
        # ...and a bare immutable path is rejected at submit
        p2 = Proposal(id="p-imm3", scope="skills",
                      target="core/runtime/contract.py", change_kind="code",
                      change="rewrite the contract", rationale="x",
                      rollback_plan="y", prompt_source="dyther_direct")
        self.pipe.submit(p2)
        self.assertEqual(p2.status, "rejected")

    def test_heart_cannot_rewrite_own_valves(self):
        p = Proposal(id="p-valve", scope="skills",
                     target="core/runtime/self_mod/verify.py",
                     change_kind="code", change="loosen verification",
                     rationale="x", rollback_plan="y",
                     prompt_source="dyther_direct")
        self.pipe.submit(p)
        self.assertEqual(p.status, "rejected")
        self.assertIn("self_mod", p.history[-1]["note"])

    def test_traversal_rejected(self):
        with self.assertRaises((ValueError, Exception)):
            make_proposal("p-trav", scope="memory",
                          target="../secrets.txt")

    # -- tiers ------------------------------------------------------------------
    def test_tier0_classification(self):
        tier, flags = classify("memory", "text", "conventions.md",
                               "tweak wording", "clearer")
        self.assertEqual(tier, Tier.TIER_0)
        self.assertEqual(flags, ())

    def test_tier1_is_default(self):
        for scope, kind in (("skills", "text"), ("skills", "code"),
                            ("memory", "code"), ("cron", "schedule")):
            tier, _ = classify(scope, kind, "t", "c", "r")
            self.assertEqual(tier, Tier.TIER_1, (scope, kind))

    def test_hard_rule_escalates(self):
        tier, flags = classify("memory", "text", "notes.md",
                               "document the kernel upgrade steps",
                               "for codypc maintenance")
        self.assertEqual(tier, Tier.TIER_1)
        self.assertIn("no-kernel-change", flags)

    # -- (b) failed verification blocks apply ------------------------------------
    def test_failed_verification_blocks_apply(self):
        p = make_proposal(
            "p-fail",
            verification_plan=[{"kind": "command",
                                "run": ["python3", "-c",
                                        "import sys; sys.exit(3)"]}])
        self.pipe.submit(p)
        result = self.pipe.verify(p)
        self.assertFalse(result.ok)
        self.assertEqual(p.status, "rejected")
        with self.assertRaises(GateRefused):
            self.pipe.gate(p)
        with self.assertRaises(GateRefused):
            self.pipe.apply(p)
        # target untouched
        self.assertEqual(
            (Path(self.tmp.name) / "memory" / "conventions.md").read_text(
                encoding="utf-8"),
            "original conventions\n")

    def test_missing_rollback_plan_fails_verification(self):
        p = make_proposal("p-norb", rollback_plan="  ")
        self.pipe.submit(p)
        result = self.pipe.verify(p)
        self.assertFalse(result.ok)
        self.assertTrue(any(s.name == "rollback_plan" and not s.ok
                            for s in result.stages))

    # -- happy path: Tier 0 -------------------------------------------------------
    def test_tier0_full_cycle(self):
        p = make_proposal(
            "p-t0",
            verification_plan=[{"kind": "command",
                                "run": ["python3", "-c", "pass"]}])
        self.pipe.submit(p)
        self.assertEqual(p.tier, Tier.TIER_0)
        result = self.pipe.verify(p)
        self.assertTrue(result.ok, [s.detail for s in result.stages])
        p.approve_self("trivial wording tweak; reversible from backup")
        self.pipe.gate(p)
        applied = self.pipe.apply(p)
        self.assertTrue(applied.ok)
        self.assertIsNotNone(applied.backup)
        target = Path(self.tmp.name) / "memory" / "conventions.md"
        self.assertEqual(target.read_text(encoding="utf-8"),
                         "new conventions text\n")
        # monitor: still green -> done
        rb = self.pipe.monitor(p, applied.backup)
        self.assertIsNone(rb)
        self.assertEqual(p.status, "done")

    # -- (c) rollback is byte-for-byte ----------------------------------------------
    def test_rollback_byte_identical(self):
        original = (Path(self.tmp.name) / "memory" / "conventions.md"
                    ).read_bytes()
        p = make_proposal("p-rb")
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_self("rollback test")
        self.pipe.gate(p)
        applied = self.pipe.apply(p)
        changed = (Path(self.tmp.name) / "memory" / "conventions.md"
                   ).read_bytes()
        self.assertNotEqual(changed, original)
        rb = self.pipe.applier.rollback(applied.backup)
        self.assertTrue(rb.ok)
        self.assertTrue(rb.byte_identical)
        restored = (Path(self.tmp.name) / "memory" / "conventions.md"
                    ).read_bytes()
        self.assertEqual(restored, original)
        backup_file = (Path(applied.backup.backup_dir)
                       / "conventions.md.bak")
        self.assertEqual(sha256_file(Path(self.tmp.name) / "memory"
                                     / "conventions.md"),
                         sha256_file(backup_file))
        self.assertEqual(sha256_file(backup_file),
                         applied.backup.files[str(Path(self.tmp.name)
                                                  / "memory"
                                                  / "conventions.md")])

    # -- (d) Tier 1 without Dyther's approval does not apply --------------------------
    def test_tier1_without_approval_blocked(self):
        p = make_proposal("p-t1", scope="skills", target="demo/SKILL.md",
                          change_kind="code", change="add a new tool",
                          rationale="review found a gap",
                          new_content="# Demo skill\n\nNew tool.\n")
        self.pipe.submit(p)
        self.assertEqual(p.tier, Tier.TIER_1)
        self.pipe.verify(p)
        with self.assertRaises(GateRefused):
            self.pipe.gate(p)
        with self.assertRaises(GateRefused):
            self.pipe.apply(p)
        self.assertEqual(
            (Path(self.tmp.name) / "skills" / "demo" / "SKILL.md").read_text(
                encoding="utf-8"),
            "# Demo skill\n")

    def test_tier1_with_approval_applies(self):
        p = make_proposal("p-t1ok", scope="skills", target="demo/SKILL.md",
                          change_kind="code", change="add a new tool",
                          rationale="review found a gap",
                          new_content="# Demo skill\n\nNew tool.\n")
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_dyther("approved: the new tool is read-only and reversible")
        self.assertTrue(p.dyther_approved())
        self.pipe.gate(p)
        self.pipe.apply(p)
        self.assertEqual(p.status, "applied")

    def test_gate_refuses_tier1_self_approval_at_streak_0(self):
        # approve_self records; the gate authorizes. At streak 0 a Tier 1
        # self-approval does not satisfy the requirement.
        p = make_proposal("p-t1self", scope="skills", target="demo/SKILL.md",
                          change_kind="code", change="x", rationale="y",
                          new_content="z\n")
        self.pipe.submit(p)
        self.assertEqual(p.tier, Tier.TIER_1)
        p.approve_self("trying to self-approve a Tier 1")
        with self.assertRaises(GateRefused):
            self.pipe.gate(p)

    # -- agent-check gating -----------------------------------------------------------
    def test_agent_check_blocks_gate_until_resolved(self):
        p = make_proposal(
            "p-ac",
            verification_plan=[
                {"kind": "agent-check",
                 "description": "read the file back and eyeball it"}])
        self.pipe.submit(p)
        result = self.pipe.verify(p)
        self.assertTrue(result.ok)
        self.assertEqual(result.agent_checks_pending,
                         ["read the file back and eyeball it"])
        p.approve_self("tier 0")
        with self.assertRaises(GateRefused):
            self.pipe.gate(p)
        p.record_agent_check("read the file back and eyeball it",
                             passed=True, note="looks right")
        self.assertTrue(p.agent_checks_clear())
        self.pipe.gate(p)  # now passes

    # -- monitor auto-rollback ----------------------------------------------------------
    def test_monitor_auto_rollback_on_regression(self):
        marker = Path(self.tmp.name) / "healthy.marker"
        check = (f"import sys, pathlib; sys.exit(0 if pathlib.Path"
                 f"({str(marker)!r}).exists() else 1)")
        p = make_proposal(
            "p-mon",
            verification_plan=[{"kind": "command",
                                "run": ["python3", "-c", check]}])
        self.pipe.submit(p)
        # Healthy at verify/apply time...
        marker.write_text("ok", encoding="utf-8")
        self.pipe.verify(p)
        p.approve_self("monitor test")
        self.pipe.gate(p)
        applied = self.pipe.apply(p)
        # ...regression after deploy: the health signal disappears.
        marker.unlink()
        rb = self.pipe.monitor(p, applied.backup)
        self.assertIsNotNone(rb)
        self.assertTrue(rb.ok and rb.byte_identical)
        self.assertEqual(p.status, "rolled_back")
        self.assertEqual(
            (Path(self.tmp.name) / "memory" / "conventions.md").read_bytes(),
            b"original conventions\n")

    # -- cron targets become plans, not writes ----------------------------------------------
    def test_cron_target_issues_plan(self):
        p = make_proposal("p-cron", scope="cron",
                          target="recursive-self-improvement",
                          change_kind="schedule",
                          change="move to Saturday",
                          rationale="review found Sunday overloaded",
                          new_content="cron body saturday\n")
        self.pipe.submit(p)
        self.assertEqual(p.tier, Tier.TIER_1)
        self.pipe.verify(p)
        p.approve_dyther("approved: Saturday is fine")
        self.pipe.gate(p)
        result = self.pipe.apply(p)
        self.assertTrue(result.ok)
        self.assertIsNotNone(result.plan_path)
        self.assertEqual(p.status, "plan_issued")
        plan = Path(result.plan_path)
        self.assertTrue(plan.exists())
        self.assertIn("cron.update", plan.read_text(encoding="utf-8"))

    # -- prompt_source: nothing is ever unprompted -------------------------------
    def test_prompt_source_required(self):
        # Omitted entirely: construction itself is impossible...
        with self.assertRaises(TypeError):
            Proposal(id="p-np", scope="memory", target="conventions.md",
                     change_kind="text", change="x", rationale="y",
                     rollback_plan="z")  # no prompt_source
        # ...and an invalid value is rejected loudly.
        with self.assertRaises(ValueError):
            make_proposal("p-bad-src", prompt_source="it felt right")

    def test_prompt_source_recorded_at_submit(self):
        p = make_proposal("p-src", prompt_source="weekly_review")
        self.pipe.submit(p)
        self.assertEqual(p.status, "proposed")
        self.assertEqual(p.prompt_source, "weekly_review")

    # -- graduation bands -------------------------------------------------------------------
    def test_approval_requirement_bands(self):
        from core.runtime.self_mod.tiers import approval_requirement
        t1 = Tier.TIER_1
        self.assertEqual(approval_requirement(t1, "config", (), 0), "dyther")
        self.assertEqual(approval_requirement(t1, "config", (), 4), "dyther")
        self.assertEqual(approval_requirement(t1, "config", (), 5),
                         "self_notify")
        self.assertEqual(approval_requirement(t1, "code", (), 10), "dyther")
        self.assertEqual(approval_requirement(t1, "code", (), 19), "dyther")
        self.assertEqual(approval_requirement(t1, "code", (), 20),
                         "self_notify")
        # Hard-rule tripwires never graduate, at any streak.
        self.assertEqual(
            approval_requirement(t1, "config",
                                 ("no-reboot-without-approval",), 99),
            "dyther")
        self.assertEqual(
            approval_requirement(Tier.TIER_0, "text", (), 0), "self")

    def test_band1_routine_self_approval_notifies_dyther(self):
        for _ in range(5):
            self.pipe.graduation.record_clean()
        self.assertEqual(self.pipe.graduation.streak, 5)
        p = make_proposal("p-band1", scope="cron",
                          target="recursive-self-improvement",
                          change_kind="schedule",
                          change="shift by one hour",
                          rationale="review found the slot colliding",
                          new_content="cron body shifted\n")
        self.pipe.submit(p)
        self.assertEqual(p.tier, Tier.TIER_1)
        self.pipe.verify(p)
        p.approve_self("routine schedule shift; verified green; "
                       "reversible via plan re-issue")
        self.pipe.gate(p)  # no Dyther approval — and no GateRefused
        self.assertEqual(p.gate_requirement, "self_notify")
        result = self.pipe.apply(p)
        self.assertTrue(result.ok)
        note = (Path(self.tmp.name) / "rt" / "self_mod" / "notifications"
                / "p-band1.md")
        self.assertTrue(note.exists(), "Dyther must be notified")
        text = note.read_text(encoding="utf-8")
        self.assertIn("revoke", text)

    def test_band1_code_stays_dyther_gated(self):
        for _ in range(10):
            self.pipe.graduation.record_clean()
        p = make_proposal("p-band1code", scope="skills",
                          target="demo/SKILL.md", change_kind="code",
                          change="rewrite skill logic", rationale="y",
                          new_content="# new\n")
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_self("self-approving code at streak 10")
        with self.assertRaises(GateRefused):
            self.pipe.gate(p)
        p.approve_dyther("code changes stay mine until graduation")
        self.pipe.gate(p)  # now it passes

    # -- streak accounting --------------------------------------------------------------------
    def test_streak_increments_on_clean_monitor(self):
        self.assertEqual(self.pipe.graduation.streak, 0)
        p = make_proposal(
            "p-streak",
            verification_plan=[{"kind": "command",
                                "run": ["python3", "-c", "pass"]}])
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_self("streak test")
        self.pipe.gate(p)
        applied = self.pipe.apply(p)
        self.pipe.monitor(p, applied.backup)
        self.assertEqual(p.status, "done")
        self.assertEqual(self.pipe.graduation.streak, 1)

    def test_streak_resets_on_rollback(self):
        for _ in range(3):
            self.pipe.graduation.record_clean()
        self.assertEqual(self.pipe.graduation.streak, 3)
        marker = Path(self.tmp.name) / "healthy.marker"
        check = (f"import sys, pathlib; sys.exit(0 if pathlib.Path"
                 f"({str(marker)!r}).exists() else 1)")
        p = make_proposal(
            "p-streak-rb",
            verification_plan=[{"kind": "command",
                                "run": ["python3", "-c", check]}])
        self.pipe.submit(p)
        marker.write_text("ok", encoding="utf-8")
        self.pipe.verify(p)
        p.approve_self("streak reset test")
        self.pipe.gate(p)
        applied = self.pipe.apply(p)
        marker.unlink()  # regression after deploy
        rb = self.pipe.monitor(p, applied.backup)
        self.assertIsNotNone(rb)
        self.assertEqual(p.status, "rolled_back")
        self.assertEqual(self.pipe.graduation.streak, 0)

    # -- revocation: approvals never expire, only revocation ends them --------------------------
    def test_revocation_blocks_gate(self):
        p = make_proposal("p-rev", scope="skills", target="demo/SKILL.md",
                          change_kind="code", change="x", rationale="y",
                          new_content="z\n")
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_dyther("approved, then reconsidered")
        self.pipe.revoke(p, "dyther", "on reflection, not yet")
        self.assertFalse(p.dyther_approved())
        with self.assertRaises(GateRefused):
            self.pipe.gate(p)

    def test_revoke_with_no_active_approval_raises(self):
        p = make_proposal("p-rev2")
        with self.assertRaises(ValueError):
            p.revoke_approval("dyther")

    def test_approvals_do_not_expire(self):
        # An approval recorded long ago still counts — there is no TTL.
        p = make_proposal("p-noexp", scope="skills", target="demo/SKILL.md",
                          change_kind="code", change="x", rationale="y",
                          new_content="z\n")
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_dyther("approved months ago")
        p.approvals[0].at = "2020-01-01T00:00:00Z"  # backdate
        self.assertTrue(p.dyther_approved())
        self.pipe.gate(p)  # passes: age alone never invalidates

    def test_revocation_does_not_auto_rollback(self):
        p = make_proposal(
            "p-rev3",
            verification_plan=[{"kind": "command",
                                "run": ["python3", "-c", "pass"]}])
        self.pipe.submit(p)
        self.pipe.verify(p)
        p.approve_self("revocation target")
        self.pipe.gate(p)
        applied = self.pipe.apply(p)
        self.pipe.monitor(p, applied.backup)
        self.assertEqual(p.status, "done")
        target = Path(self.tmp.name) / "memory" / "conventions.md"
        # Revoking after apply flags for re-review — the change stands
        # until an explicit rollback proposal says otherwise.
        self.pipe.revoke(p, "self", "reconsidering")
        self.assertEqual(target.read_text(encoding="utf-8"),
                         "new conventions text\n")

    # -- status machine ----------------------------------------------------------------------
    def test_illegal_transitions_raise(self):
        p = make_proposal("p-st")
        with self.assertRaises(StatusTransitionError):
            p.transition("applied")  # draft -> applied skips everything
        with self.assertRaises(StatusTransitionError):
            self.pipe.verify(p)  # verify requires 'proposed'


if __name__ == "__main__":
    unittest.main()
