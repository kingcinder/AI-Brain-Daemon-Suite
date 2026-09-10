#!/usr/bin/env python3
"""Contract conformance tests — stdlib only, no substrate required.

Run: python3 -m unittest core.runtime.tests.test_contract -v
(from the repo root).
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent.parent
sys.path.insert(0, str(ROOT))

from core.runtime.adapters import (  # noqa: E402
    CodypcMemoryStore, CodypcRuntime, CodypcScheduler, JunoRuntime,
    JunoScheduler,
)
from core.runtime.contract import (  # noqa: E402
    ContractError, JobSpec, MemoryViolation, Runtime, ScriptResult,
)
from core.runtime.jobs import WeeklyReflectionJob  # noqa: E402
from core.runtime.jobs.direct_job import (  # noqa: E402
    DirectJob, hippocampus_decay_job,
)
from core.runtime.schedule import (  # noqa: E402
    Job as SchedJob, ScheduleTable, due_now,
)


class JobSpecTest(unittest.TestCase):
    def test_valid(self):
        JobSpec(id="x", kind="spawn").validate()

    def test_bad_kind(self):
        with self.assertRaises(ContractError):
            JobSpec(id="x", kind="nope").validate()

    def test_empty_id(self):
        with self.assertRaises(ContractError):
            JobSpec(id="", kind="direct").validate()


class WeeklyReflectionJobTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rt-test-")
        self.rt = JunoRuntime(root=self.tmp.name, suite_root=ROOT)
        self.job = WeeklyReflectionJob()

    def tearDown(self):
        self.tmp.cleanup()

    def test_spec_matches_suite_slot(self):
        spec = self.job.spec()
        self.assertEqual(spec.id, "hippocampus_weekly_reflection")
        self.assertEqual(spec.kind, "spawn")
        self.assertEqual((spec.days, spec.hours, spec.minutes), ("6", "2", "44"))

    def test_build_prompt_has_weekly_questions(self):
        prompt = self.job.build_prompt(self.rt).lower()
        for q in ("how have i changed this week?",
                  "what opinions have shifted or strengthened?",
                  "how has my relationship with the user evolved",
                  "be honest, not performative"):
            self.assertIn(q, prompt)

    def test_build_prompt_includes_prior_self_state(self):
        self.rt.memory.write("memory/self/growth.md",
                             "## 2026-09-01\n\nPrior insight: closure-seeking.")
        prompt = self.job.build_prompt(self.rt)
        self.assertIn("closure-seeking", prompt)

    def test_complete_persists_and_audits(self):
        result = self.job.complete(self.rt, "Reflection text here.")
        self.assertTrue(result.ok)
        self.assertIn("memory/self/growth.md", result.artifacts)
        stored = self.rt.memory.read("memory/self/growth.md")
        self.assertIn("Reflection text here.", stored)
        self.assertIn("Weekly reflection", stored)

    def test_complete_rejects_empty(self):
        with self.assertRaises(ContractError):
            self.job.complete(self.rt, "   ")

    def test_complete_optional_updates(self):
        result = self.job.complete(self.rt, "growth text",
                                   opinions_update="new view: X",
                                   identity_update="I am becoming Y")
        self.assertIn("memory/self/opinions.md", result.artifacts)
        self.assertIn("memory/self/identity.md", result.artifacts)
        self.assertIn("new view: X", self.rt.memory.read("memory/self/opinions.md"))
        self.assertIn("becoming Y", self.rt.memory.read("memory/self/identity.md"))

    def test_run_with_embedded_mind_raises(self):
        # Juno runtime has mind=None: run() must direct to build_prompt/complete.
        with self.assertRaises(ContractError):
            self.job.run(self.rt)

    def test_provenance_appended(self):
        self.job.complete(self.rt, "text")
        prov = self.rt.memory.read("provenance-log.jsonl")
        self.assertIn("job.completed", prov)


class CodypcStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rt-test-")
        self.store = CodypcMemoryStore(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_roundtrip(self):
        self.store.write("memory/self/growth.md", "hello")
        self.assertEqual(self.store.read("memory/self/growth.md"), "hello")

    def test_missing_is_none(self):
        self.assertIsNone(self.store.read("memory/nope.md"))

    def test_traversal_rejected(self):
        for bad in ("../../etc/passwd", "/abs/path", "~/x", "../out"):
            with self.assertRaises(MemoryViolation, msg=bad):
                self.store.write(bad, "x")

    def test_scheduler_roundtrip(self):
        sched = CodypcScheduler(self.store)
        spec = JobSpec(id="j1", kind="spawn", days="6", hours="2", minutes="44",
                       task="do it")
        sched.schedule(spec)
        jobs = {j.id: j for j in sched.list_jobs()}
        self.assertEqual(jobs["j1"].minutes, "44")
        sched.unschedule("j1")
        self.assertEqual(sched.list_jobs(), [])
        sched.unschedule("missing")  # no-op, not an error

    def test_to_kernel_job_shape(self):
        spec = JobSpec(id="hippocampus_weekly_reflection", kind="spawn",
                       days="6", hours="2", minutes="44", task="reflect")
        rendered = CodypcScheduler.to_kernel_job(spec)
        self.assertIn('Job("hippocampus_weekly_reflection", "spawn", "2", "44"',
                      rendered)
        self.assertIn('days="6"', rendered)


class JunoAdapterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rt-test-")
        self.rt = JunoRuntime(root=self.tmp.name, suite_root=ROOT)

    def tearDown(self):
        self.tmp.cleanup()

    def test_mind_is_none(self):
        self.assertIsNone(self.rt.mind)

    def test_self_paths_are_markdown_files(self):
        job = WeeklyReflectionJob()
        self.rt.memory.write("memory/self/growth.md", "first insight")
        result = job.complete(self.rt, "second insight")
        text = self.rt.memory.read("memory/self/growth.md")
        self.assertIn("first insight", text)
        self.assertIn("second insight", text)
        self.assertIn("Weekly reflection", text)
        self.assertIn("memory/self/growth.md", result.artifacts)

    def test_traversal_rejected(self):
        with self.assertRaises(MemoryViolation):
            self.rt.memory.write("../../evil", "x")

    def test_scheduler_emits_request_doc(self):
        sched = JunoScheduler(self.tmp.name)
        spec = JobSpec(id="hippocampus_weekly_reflection", kind="spawn",
                       days="6", hours="2", minutes="44", task="reflect")
        sched.schedule(spec)
        doc_path = Path(self.tmp.name) / "schedule-requests" / \
            "hippocampus_weekly_reflection.json"
        self.assertTrue(doc_path.exists())
        doc = json.loads(doc_path.read_text())
        self.assertEqual(doc["action"], "cron.add")
        self.assertEqual(doc["schedule"]["kind"], "weekly")
        self.assertEqual(doc["schedule"]["dow"], ["Sun"])
        self.assertIn("build_prompt", doc["body"])
        # list_jobs reports requested (pending-install) specs
        self.assertEqual(sched.list_jobs()[0].id,
                         "hippocampus_weekly_reflection")

    def test_asset_reads_suite_prompts(self):
        text = self.rt.asset(
            "skills/hippocampus-memory/prompts/self-reflect.md")
        self.assertIn("How have I changed this week?", text)

    def test_asset_rejects_escape(self):
        self.assertIsNone(self.rt.asset("../../etc/passwd"))


class SafetyKernelTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rt-test-")
        self.rt = CodypcRuntime(workspace=self.tmp.name, suite_root=ROOT)

    def tearDown(self):
        self.tmp.cleanup()

    def test_immutable_core_patterns(self):
        for p in ("core/self-mod/run-pipeline.sh",
                  "core/locks/rwlock.sh",
                  "core/runtime/contract.py",
                  "core/runtime/RUNTIME_CONTRACT.md",
                  "core/runtime/schedule.py",
                  "core/runtime/self_mod/pipeline.py",
                  "skills/prefrontal-cortex-memory/scripts/decide.sh"):
            self.assertTrue(self.rt.check_immutable(p), p)
        for p in ("skills/hippocampus-memory/scripts/reflect.sh",
                  "core/runtime/jobs/weekly_reflection.py",
                  "core/runtime/adapters/juno.py",
                  "deep-brain-kernel.py"):
            self.assertFalse(self.rt.check_immutable(p), p)

    def test_autonomy_fail_safe(self):
        # Missing/invalid evidence => steward_mode, never auto.
        self.assertEqual(self.rt.autonomy_mode({}), "steward_mode")
        self.assertEqual(self.rt.autonomy_mode({"graduated": True}),
                         "steward_mode")
        self.assertEqual(self.rt.autonomy_mode({"bogus": object()}),
                         "steward_mode")

    def test_autonomy_granted_only_on_full_evidence(self):
        ev = {"graduated": True, "clean_streak": 20,
              "clean_streak_target": 20, "unhealthy_jobs": 0,
              "auto_rollbacks_in_window": 1, "max_auto_rollbacks": 3}
        self.assertEqual(self.rt.autonomy_mode(ev), "auto_mode")
        ev["unhealthy_jobs"] = 1
        self.assertEqual(self.rt.autonomy_mode(ev), "steward_mode")

    def test_provenance_never_raises(self):
        # Even when the store fails, provenance must not break callers (S7).
        rt = CodypcRuntime(workspace=self.tmp.name, suite_root=ROOT)

        def _boom(relpath: str, record: dict):
            raise OSError("disk on fire")
        rt.memory.append_jsonl = _boom  # type: ignore[method-assign]
        rt.provenance("test.event", {"k": "v"})  # must not raise


class DirectJobTest(unittest.TestCase):
    """Slice 2: direct-kind jobs through the contract."""

    def _runtime_with(self, script_result=None, exc=None):
        tmp = tempfile.TemporaryDirectory(prefix="rt-direct-")
        rt = JunoRuntime(root=tmp.name, suite_root=ROOT)
        if exc is not None:
            def _raise(relpath, args=None, timeout_s=300):
                raise exc
            rt.run_script = _raise  # type: ignore[method-assign]
        else:
            def _ok(relpath, args=None, timeout_s=300):
                return script_result
            rt.run_script = _ok  # type: ignore[method-assign]
        rt._tmp = tmp  # keep alive
        return rt

    def test_direct_job_happy_path(self):
        rt = self._runtime_with(ScriptResult(returncode=0, output="decayed 3"))
        job = DirectJob(job_id="d", script="x/decay.sh")
        result = job.run(rt)
        self.assertTrue(result.ok)
        self.assertIn("exited 0", result.summary)
        rt._tmp.cleanup()

    def test_direct_job_nonzero_is_failure(self):
        rt = self._runtime_with(ScriptResult(returncode=1, output="boom"))
        job = DirectJob(job_id="d", script="x/decay.sh")
        result = job.run(rt)
        self.assertFalse(result.ok)
        self.assertIn("rc=1", result.summary)
        rt._tmp.cleanup()

    def test_direct_job_missing_script_is_loud(self):
        rt = self._runtime_with(exc=ContractError("script not found"))
        job = DirectJob(job_id="d", script="x/missing.sh")
        result = job.run(rt)
        self.assertFalse(result.ok)
        self.assertIn("script not found", result.error)
        rt._tmp.cleanup()

    def test_direct_job_needs_no_mind(self):
        # Direct jobs run on embedded-mind runtimes (mind is None).
        rt = self._runtime_with(ScriptResult(returncode=0, output="ok"))
        self.assertIsNone(rt.mind)
        job = DirectJob(job_id="d", script="x/decay.sh")
        self.assertTrue(job.run(rt).ok)
        rt._tmp.cleanup()

    def test_hippocampus_decay_mirrors_jobs_table(self):
        job = hippocampus_decay_job()
        spec = job.spec()
        self.assertEqual(spec.id, "hippocampus_decay")
        self.assertEqual(spec.kind, "direct")
        self.assertEqual(spec.days, "3")
        self.assertEqual(spec.hours, "2")
        self.assertEqual(spec.task, "skills/hippocampus-memory/scripts/decay.sh")

    def test_base_run_script_raises(self):
        class Bare(Runtime):
            name = "bare"
            def __init__(self):
                pass
            def asset(self, relpath): return None
            def log(self, level, message, **fields): pass
            def provenance(self, event, detail): pass
        rt = Bare()
        rt.mind = None
        rt.memory = None
        rt.scheduler = None
        with self.assertRaises(ContractError):
            rt.run_script("x.sh")


class RunScriptAdapterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rt-runscript-")

    def tearDown(self):
        self.tmp.cleanup()

    def _make_script(self, suite_root: Path, name: str, body: str) -> str:
        p = suite_root / name
        p.write_text(body)
        p.chmod(0o755)
        return name

    def test_codypc_missing_script_raises(self):
        rt = CodypcRuntime(workspace=self.tmp.name, suite_root=ROOT)
        with self.assertRaises(ContractError):
            rt.run_script("nope/missing.sh")

    def test_codypc_runs_real_script(self):
        suite = Path(self.tmp.name) / "suite"
        suite.mkdir()
        rel = self._make_script(suite, "hello.sh",
                                "#!/bin/bash\necho \"ws=$WORKSPACE\"\n")
        rt = CodypcRuntime(workspace=self.tmp.name, suite_root=suite)
        res = rt.run_script(rel)
        self.assertEqual(res.returncode, 0)
        self.assertIn("ws=", res.output)

    def test_juno_runs_real_script(self):
        suite = Path(self.tmp.name) / "suite"
        suite.mkdir()
        rel = self._make_script(suite, "hello.sh",
                                "#!/bin/bash\necho hello-juno\n")
        rt = JunoRuntime(root=self.tmp.name, suite_root=suite)
        res = rt.run_script(rel)
        self.assertEqual(res.returncode, 0)
        self.assertIn("hello-juno", res.output)

    def test_juno_reports_nonzero(self):
        suite = Path(self.tmp.name) / "suite"
        suite.mkdir()
        rel = self._make_script(suite, "fail.sh",
                                "#!/bin/bash\necho oops >&2\nexit 3\n")
        rt = JunoRuntime(root=self.tmp.name, suite_root=suite)
        res = rt.run_script(rel)
        self.assertEqual(res.returncode, 3)
        self.assertIn("oops", res.output)

    def test_run_script_rejects_escape(self):
        rt = JunoRuntime(root=self.tmp.name, suite_root=ROOT)
        with self.assertRaises(ContractError):
            rt.run_script("../../etc/passwd")


class ScheduleTableTest(unittest.TestCase):
    """Slice 3: portable schedule-table core."""

    def test_due_now_and_dedupe(self):
        from datetime import datetime
        job = SchedJob(name="w", kind="spawn", hours="2", minutes="44",
                       target="t", days="6")  # Sunday 02:44
        sunday = datetime(2026, 9, 13, 2, 44)  # a Sunday
        self.assertEqual(sunday.weekday(), 6)
        self.assertTrue(due_now(job, sunday))
        table = ScheduleTable([job])
        self.assertEqual(table.due_at(sunday), [job])
        table.mark_fired(job, sunday)
        self.assertEqual(table.due_at(sunday), [])  # deduped this minute
        # next week: due again (date-qualified key, not H:M)
        next_sunday = datetime(2026, 9, 20, 2, 44)
        self.assertEqual(table.due_at(next_sunday), [job])

    def test_spec_wildcards_and_lists(self):
        from datetime import datetime
        job = SchedJob(name="h", kind="direct", hours="*", minutes="6,21",
                       target="t")
        self.assertTrue(due_now(job, datetime(2026, 9, 10, 3, 21)))
        self.assertFalse(due_now(job, datetime(2026, 9, 10, 3, 22)))

    def test_minute_collisions_reported(self):
        a = SchedJob(name="a", kind="direct", hours="*", minutes="5",
                     target="t")
        b = SchedJob(name="b", kind="direct", hours="*", minutes="5",
                     target="t")
        c = SchedJob(name="c", kind="direct", hours="*", minutes="6",
                     target="t")
        table = ScheduleTable([a, b, c])
        self.assertEqual(table.minute_collisions(), {"5": ["a", "b"]})

    def test_kernel_table_loads_into_schedule_table(self):
        # The extraction is behavior-identical: the kernel's own JOBS table
        # answers due_at() through the portable core.
        import importlib.util
        kpath = ROOT / "deep-brain-kernel.py"
        spec = importlib.util.spec_from_file_location("kb", kpath)
        kb = importlib.util.module_from_spec(spec)
        import os
        os.environ["WORKSPACE"] = str(ROOT)
        spec.loader.exec_module(kb)
        table = ScheduleTable(list(kb.JOBS))
        from datetime import datetime
        sunday = datetime(2026, 9, 13, 2, 44)
        names = [j.name for j in table.due_at(sunday)]
        self.assertIn("hippocampus_weekly_reflection", names)
        # consolidation is the next slot over (Sunday 02:34 per JOBS).
        names2 = [j.name for j in table.due_at(datetime(2026, 9, 13, 2, 34))]
        self.assertIn("hippocampus_weekly_consolidation", names2)


if __name__ == "__main__":
    unittest.main()
