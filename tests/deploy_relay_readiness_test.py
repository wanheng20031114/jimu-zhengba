"""Pure deployment readiness checks; never connect to SSH or launch a relay."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parents[1] / "tools" / "deploy_relay.py"
SPEC = importlib.util.spec_from_file_location("deploy_relay", MODULE)
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)

READY = "JIMU_RELAY_READY protocol=4 rooms=1 humans=4"
STATE = {
    "InvocationID": "a" * 32,
    "MainPID": "279695",
    "ActiveState": "active",
    "SubState": "running",
    "NRestarts": "0",
}


def properties(**changes: str) -> str:
    return "\n".join(key + "=" + value for key, value in (STATE | changes).items())


class RelayReadinessTest(unittest.TestCase):
    def test_failed_first_migration_cannot_restart_or_boot_both_services(self):
        state = {"new_running": True, "new_enabled": True, "legacy_running": False}
        def run(command):
            if command == "systemctl stop " + DEPLOY.SERVICE:
                state["new_running"] = False
            elif command == "systemctl disable " + DEPLOY.SERVICE:
                state["new_enabled"] = False
            elif command == "systemctl start " + DEPLOY.LEGACY_SERVICE:
                self.assertFalse(state["new_running"], "legacy cannot recover while new service holds its port")
                state["legacy_running"] = True
            else:
                self.fail("Rollback touched an unexpected service")
        DEPLOY.rollback_failed_start(run, legacy_active=True, was_enabled=False)
        self.assertEqual(state, {"new_running": False, "new_enabled": False, "legacy_running": True})

    def test_failed_stop_does_not_start_a_competing_legacy(self):
        def run(command):
            self.assertEqual(command, "systemctl stop " + DEPLOY.SERVICE)
            raise RuntimeError("Unable to stop new service")
        with self.assertRaises(RuntimeError):
            DEPLOY.rollback_failed_start(run, legacy_active=True, was_enabled=False)

    def test_existing_service_enable_preference_is_preserved(self):
        calls = []
        DEPLOY.rollback_failed_start(calls.append, legacy_active=False, was_enabled=True)
        self.assertEqual(calls, ["systemctl stop " + DEPLOY.SERVICE])

    def test_clean_current_invocation_is_ready(self):
        self.assertTrue(DEPLOY.relay_journal_ready("Godot Engine v4.7.2\n" + READY))

    def test_rejected_peer_after_ready_does_not_fail_deployment(self):
        for name in ("TLS", "DTLS"):
            with self.subTest(name=name):
                journal = READY + "\nERROR: " + name + " handshake error: -30464\nmbedtls error: returned -0x7700\n"
                self.assertTrue(DEPLOY.relay_journal_ready(journal))

    def test_rejected_peer_does_not_fabricate_readiness(self):
        self.assertFalse(DEPLOY.relay_journal_ready("ERROR: TLS handshake error: -30464"))

    def test_ready_does_not_hide_script_or_host_errors(self):
        for error in ("SCRIPT ERROR: Parse Error", "ERROR: RELAY_START_FAILED code=20",
                      "ERROR: RELAY_TRANSPORT_ERROR", "RELAY_TRANSPORT_ERROR", "ERROR: Unknown failure"):
            with self.subTest(error=error), self.assertRaises(RuntimeError):
                DEPLOY.relay_journal_ready(READY + "\n" + error)

    def test_handshake_exception_requires_an_exact_native_error_line(self):
        for error in ("ERROR: TLS handshake error: -30464 other failure", "ERROR: TLS handshake error: invalid",
                      "ERROR: TLS handshake error: 30464", "SCRIPT ERROR: TLS handshake error: -30464"):
            with self.subTest(error=error), self.assertRaises(RuntimeError):
                DEPLOY.relay_journal_ready(READY + "\n" + error)

    def test_partial_or_embedded_ready_marker_is_not_readiness(self):
        for line in ("JIMU_RELAY_READY", "old log says " + READY, READY + " invalid"):
            with self.subTest(line=line):
                self.assertFalse(DEPLOY.relay_journal_ready(line))

    def test_healthy_service_identity_remains_stable(self):
        expected = ("a" * 32, 279695, 0)
        self.assertEqual(DEPLOY.relay_service_identity(properties()), expected)
        self.assertEqual(DEPLOY.relay_service_identity(properties(), expected), expected)

    def test_restart_or_replaced_process_is_rejected_after_ready(self):
        expected = DEPLOY.relay_service_identity(properties())
        for changes in ({"InvocationID": "b" * 32}, {"MainPID": "279696"}, {"NRestarts": "1"}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                DEPLOY.relay_service_identity(properties(**changes), expected)

    def test_nonrunning_or_unverifiable_service_is_rejected(self):
        for changes in ({"ActiveState": "failed"}, {"SubState": "auto-restart"}, {"MainPID": "0"},
                        {"InvocationID": ""}, {"NRestarts": ""}, {"MainPID": "invalid"}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                DEPLOY.relay_service_identity(properties(**changes))

    def test_missing_systemd_properties_are_rejected(self):
        with self.assertRaises(RuntimeError):
            DEPLOY.relay_service_identity("ActiveState=active")


if __name__ == "__main__":
    unittest.main(verbosity=2)
