#!/usr/bin/env python3
"""Synthetic framed-DAP ordering tests for the native-values probe harness."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE_PATH = ROOT / "scripts/probe_native_crystal_values.py"
spec = importlib.util.spec_from_file_location("native_values_probe_under_test", PROBE_PATH)
assert spec and spec.loader
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


LAUNCH_SEQUENCE = 7
INITIALIZED = {"seq": 20, "type": "event", "event": "initialized"}


def launch_response(*, success: bool = True) -> dict[str, object]:
    response: dict[str, object] = {
        "seq": 21,
        "type": "response",
        "request_seq": LAUNCH_SEQUENCE,
        "command": "launch",
        "success": success,
    }
    if not success:
        response["message"] = "launch denied"
    return response


def dap_with_frames(messages: list[dict[str, object]], *, cached_events=(), cached_responses=None):
    stream = tempfile.TemporaryFile()
    for message in messages:
        payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
        stream.write(f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii") + payload)
    stream.seek(0)

    dap = probe.DAP.__new__(probe.DAP)
    dap.process = types.SimpleNamespace(stdout=stream)
    dap.timeout = 0.1
    dap.pending_events = list(cached_events)
    dap.pending_responses = dict(cached_responses or {})
    dap.messages = 0
    return dap, stream


class LaunchOrderingTests(unittest.TestCase):
    def assert_initialized_then_launch_response(self, dap, stream):
        self.addCleanup(stream.close)
        event = dap.wait_event_after_request("initialized", LAUNCH_SEQUENCE)
        self.assertEqual(event, INITIALIZED)
        self.assertEqual(dap.wait_response(LAUNCH_SEQUENCE), launch_response())

    def test_response_before_initialized_is_preserved(self):
        dap, stream = dap_with_frames([launch_response(), INITIALIZED])
        self.assert_initialized_then_launch_response(dap, stream)

    def test_initialized_before_response_is_preserved(self):
        dap, stream = dap_with_frames([INITIALIZED, launch_response()])
        self.assert_initialized_then_launch_response(dap, stream)

    def test_cached_launch_response_before_initialized_is_preserved(self):
        dap, stream = dap_with_frames([INITIALIZED], cached_responses={LAUNCH_SEQUENCE: launch_response()})
        self.assert_initialized_then_launch_response(dap, stream)

    def test_cached_initialized_event_keeps_cached_launch_response(self):
        dap, stream = dap_with_frames(
            [],
            cached_events=[INITIALIZED],
            cached_responses={LAUNCH_SEQUENCE: launch_response()},
        )
        self.assert_initialized_then_launch_response(dap, stream)

    def test_initialized_event_cached_during_wait_keeps_early_response(self):
        other_event = {"seq": 22, "type": "event", "event": "output", "body": {"output": "probe"}}
        other_response = {
            "seq": 23,
            "type": "response",
            "request_seq": 99,
            "command": "threads",
            "success": True,
        }
        dap, stream = dap_with_frames([launch_response(), other_event, other_response])
        self.addCleanup(stream.close)
        read_message = dap._read_message
        reads = 0

        def read_with_cached_initialized(deadline):
            nonlocal reads
            reads += 1
            message = read_message(deadline)
            if reads == 3:
                dap.pending_events.append(INITIALIZED)
            return message

        dap._read_message = read_with_cached_initialized
        event = dap.wait_event_after_request("initialized", LAUNCH_SEQUENCE)
        self.assertEqual(event, INITIALIZED)
        self.assertEqual(dap.wait_response(LAUNCH_SEQUENCE), launch_response())

    def test_early_failed_launch_response_is_reported_before_initialized(self):
        dap, stream = dap_with_frames([launch_response(success=False), INITIALIZED])
        self.addCleanup(stream.close)
        with self.assertRaisesRegex(probe.ProbeError, "launch failed before initialized:.*launch denied"):
            dap.wait_event_after_request("initialized", LAUNCH_SEQUENCE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
