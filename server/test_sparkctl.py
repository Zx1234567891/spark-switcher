"""Regression tests for switch state transitions; no Spark/Docker access."""
import json
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

if sys.platform == "win32":
    # The controller only runs on Linux. These transaction tests do not use flock.
    sys.modules["fcntl"] = types.ModuleType("fcntl")
import sparkctl as ctl


class ConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = json.loads(pathlib.Path(__file__).with_name("server.example.json").read_text(encoding="utf-8"))
        self.path = pathlib.Path(self.tmp.name) / "server.json"

    def load(self):
        self.path.write_text(json.dumps(self.config), encoding="utf-8")
        return ctl.load_config(self.path)

    def test_example_configuration(self):
        nodes, fabric, models = self.load()
        self.assertEqual(nodes[0]["roce_address"], "192.0.2.10")
        self.assertEqual(nodes[1]["ssh_target"], "spark@spark-worker.example")
        self.assertEqual(fabric["mtu"], 9000)
        self.assertEqual(models["deepseek"]["port"], 18888)

    def test_configuration_rejects_ssh_options_as_target(self):
        self.config["worker"]["ssh_target"] = "-oProxyCommand=invalid"
        with self.assertRaisesRegex(ValueError, r"worker\.ssh_target"):
            self.load()

    def test_model_overrides_do_not_change_fixed_ports(self):
        self.config["models"]["glm"]["port"] = 9000
        with self.assertRaisesRegex(ValueError, r"models\.glm"):
            self.load()


class SwitchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = patch.object(ctl, "DATA", pathlib.Path(self.tmp.name))
        p.start()
        self.addCleanup(p.stop)
        self.job = dict(id="test", target="glm", previous=None, state="running", phase="queued", message="test")
        self.nodes = [{"vllm-fn"}, {"vllm-fn"}]
        self.calls = []
        self.failure = None

    def stop(self, name):
        self.calls.append(("stop", name))
        for node in self.nodes:
            node.discard(ctl.MODELS[name]["container"])

    def launch(self, name):
        self.calls.append(("launch", name))
        container = ctl.MODELS[name]["container"]
        self.nodes[0].add(container)
        if self.failure == name:
            raise RuntimeError("simulated missing second rank")
        self.nodes[1].add(container)

    def invoke(self, force=False, healthy=True):
        with patch.multiple(ctl, topology=lambda: None, inventory_checked=lambda: self.nodes,
                            ensure_offline_assets=lambda name: self.calls.append(("check", name)),
                            ready=lambda name: healthy, in_flight=lambda name: 0,
                            occupied=lambda port: False, stop_model=self.stop, launch=self.launch,
                            smoke=lambda name: self.calls.append(("smoke", name))):
            with patch.object(ctl.time, "sleep"):
                ctl.perform(self.job, force)

    def test_swaps_both_ranks_and_smokes_before_reporting(self):
        self.invoke()
        self.assertEqual(self.job["state"], "succeeded")
        self.assertEqual(self.calls, [("check", "glm"), ("check", "qwen"), ("stop", "qwen"),
                                      ("launch", "glm"), ("smoke", "glm")])
        self.assertEqual(self.nodes, [{"glm53-flash-tf"}, {"glm53-flash-tf"}])

    def test_partial_target_rollback_removes_it_before_restoring_old_model(self):
        self.failure = "glm"
        self.invoke()
        self.assertEqual(self.job["state"], "rolled_back")
        self.assertEqual(self.calls[-3:], [("stop", "glm"), ("launch", "qwen"), ("smoke", "qwen")])
        self.assertEqual(self.nodes, [{"vllm-fn"}, {"vllm-fn"}])

    def test_unmanaged_model_blocks_before_any_mutation(self):
        self.nodes[1].add("ds41-1017-tf")
        self.invoke()
        self.assertEqual(self.job["state"], "failed")
        self.assertIn("Unmanaged", self.job["error"])
        self.assertEqual(self.calls, [])

    def test_unhealthy_incumbent_requires_explicit_force(self):
        self.invoke(healthy=False)
        self.assertEqual(self.job["state"], "failed")
        self.assertIn("before forcing", self.job["error"])
        self.assertEqual(self.calls, [("check", "glm"), ("check", "qwen")])

    def test_noop_preserves_already_running_model(self):
        self.job["target"] = "qwen"
        self.invoke()
        self.assertEqual(self.job["state"], "succeeded")
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
