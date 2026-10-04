#!/usr/bin/env python3
"""Bounded real-LLDB-DAP probe for stock Crystal String/Array values."""

from __future__ import annotations

import argparse
import json
import os
import select
import shlex
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CRYSTAL = Path("/opt/homebrew/bin/crystal")
DEFAULT_ADAPTER = Path("/opt/homebrew/opt/llvm/bin/lldb-dap")
DEFAULT_DEBUGSERVER = Path(
    "/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver"
)
FIXTURE = ROOT / "spec/fixtures/debugger/native_values.cr"


class ProbeError(RuntimeError):
    pass


class DAP:
    def __init__(self, command: list[str], env: dict[str, str], timeout: float):
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=0,
        )
        self.timeout = timeout
        self.next_sequence = 1
        self.pending_events: list[dict[str, Any]] = []
        self.pending_responses: dict[int, dict[str, Any]] = {}
        self.messages = 0

    def _read_exactly(self, length: int, deadline: float) -> bytes:
        assert self.process.stdout is not None
        result = bytearray()
        while len(result) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise ProbeError("timed out reading DAP frame")
            chunk = self.process.stdout.read(length - len(result))
            if not chunk:
                raise ProbeError("LLDB-DAP closed stdout during a frame")
            result.extend(chunk)
        return bytes(result)

    def _read_message(self, deadline: float) -> dict[str, Any]:
        assert self.process.stdout is not None
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise ProbeError("timed out reading DAP header")
            byte = self.process.stdout.read(1)
            if not byte:
                raise ProbeError("LLDB-DAP closed stdout before a DAP header")
            header.extend(byte)
            if len(header) > 4096:
                raise ProbeError("DAP header exceeded 4096 bytes")
        lengths = [
            line.split(b":", 1)[1].strip()
            for line in header.split(b"\r\n")
            if line.lower().startswith(b"content-length:")
        ]
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise ProbeError("invalid DAP Content-Length header")
        length = int(lengths[0])
        if length > 4 * 1024 * 1024:
            raise ProbeError(f"DAP message exceeds 4 MiB limit: {length}")
        try:
            message = json.loads(self._read_exactly(length, deadline))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProbeError(f"invalid DAP JSON: {error}") from error
        self.messages += 1
        if self.messages > 512:
            raise ProbeError("DAP message count exceeds 512")
        if not isinstance(message, dict):
            raise ProbeError("DAP message is not an object")
        return message

    def send(self, command: str, arguments: dict[str, Any] | None = None) -> int:
        assert self.process.stdin is not None
        sequence = self.next_sequence
        self.next_sequence += 1
        body: dict[str, Any] = {"seq": sequence, "type": "request", "command": command}
        if arguments is not None:
            body["arguments"] = arguments
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii") + data)
        self.process.stdin.flush()
        return sequence

    def request(self, command: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        request_sequence = self.send(command, arguments)
        response = self.wait_response(request_sequence)
        if not response.get("success"):
            raise ProbeError(f"{command} failed: {json.dumps(response, ensure_ascii=False)}")
        return response

    def wait_response(self, request_sequence: int) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        while True:
            cached = self.pending_responses.pop(request_sequence, None)
            if cached is not None:
                return cached
            message = self._read_message(deadline)
            if message.get("type") == "event":
                self.pending_events.append(message)
            elif message.get("type") == "response" and isinstance(message.get("request_seq"), int):
                self.pending_responses[message["request_seq"]] = message

    def wait_event(self, event_name: str) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        while True:
            for index, message in enumerate(self.pending_events):
                if message.get("event") == event_name:
                    return self.pending_events.pop(index)
            message = self._read_message(deadline)
            if message.get("type") == "event":
                if message.get("event") == event_name:
                    return message
                self.pending_events.append(message)
            elif message.get("type") == "response" and isinstance(message.get("request_seq"), int):
                self.pending_responses[message["request_seq"]] = message

    def wait_event_after_request(self, event_name: str, request_sequence: int) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        launch_response: dict[str, Any] | None = None

        def preserve_launch_response() -> None:
            if launch_response is not None:
                self.pending_responses[request_sequence] = launch_response

        while True:
            for index, message in enumerate(self.pending_events):
                if message.get("event") == event_name:
                    preserve_launch_response()
                    return self.pending_events.pop(index)
            cached = self.pending_responses.pop(request_sequence, None)
            if cached is not None:
                launch_response = cached
                if not cached.get("success"):
                    raise ProbeError(f"launch failed before {event_name}: {json.dumps(cached, ensure_ascii=False)}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                status = "no launch response" if launch_response is None else "launch succeeded without initialized event"
                if launch_response is not None:
                    self.pending_responses[request_sequence] = launch_response
                raise ProbeError(f"timed out waiting for {event_name}; {status}")
            message = self._read_message(deadline)
            if message.get("type") == "event":
                if message.get("event") == event_name:
                    preserve_launch_response()
                    return message
                self.pending_events.append(message)
            elif message.get("type") == "response" and isinstance(message.get("request_seq"), int):
                self.pending_responses[message["request_seq"]] = message

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.request("disconnect", {"terminateDebuggee": True})
            except (ProbeError, BrokenPipeError, OSError):
                self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)

    def stderr_excerpt(self) -> str:
        if self.process.stderr is None:
            return ""
        try:
            if not select.select([self.process.stderr], [], [], 0.05)[0]:
                return ""
            raw = os.read(self.process.stderr.fileno(), 8192)
        except OSError:
            return ""
        return raw.decode("utf-8", errors="replace")[-2048:]


def launch_probe(adapter: Path, debugserver: Path, program: Path, cwd: Path,
                 formatter_source: Path | None, timeout: float) -> dict[str, Any]:
    env = os.environ.copy()
    env["LLDB_DEBUGSERVER_PATH"] = str(debugserver)
    dap = DAP([str(adapter), "--no-lldbinit"], env, timeout)
    stage = "initialize"
    try:
        dap.request(
            "initialize",
            {
                "adapterID": "lldb",
                "clientID": "adamantine-native-values-probe",
                "linesStartAt1": True,
                "columnsStartAt1": True,
                "supportsRunInTerminalRequest": False,
            },
        )
        launch: dict[str, Any] = {
            "name": "Owned stock Crystal native-values probe",
            "type": "lldb",
            "request": "launch",
            "program": str(program),
            "cwd": str(cwd),
            "args": [],
            "stopOnEntry": False,
        }
        if formatter_source is not None:
            # Only this probe accepts an explicit, task-owned source path. The
            # product embeds the reviewed source and does not expose commands.
            launch["initCommands"] = [
                "command script import " + shlex.quote(str(formatter_source))
            ]
        stage = "launch request / initialized event"
        launch_sequence = dap.send("launch", launch)
        dap.wait_event_after_request("initialized", launch_sequence)
        stage = "source breakpoint configuration"
        dap.request(
            "setBreakpoints",
            {
                "source": {"name": FIXTURE.name, "path": str(FIXTURE)},
                "breakpoints": [{"line": breakpoint_line()}],
            },
        )
        stage = "configurationDone"
        dap.request("configurationDone")
        stage = "launch response"
        launch_response = dap.wait_response(launch_sequence)
        if not launch_response.get("success"):
            raise ProbeError(f"launch failed: {json.dumps(launch_response, ensure_ascii=False)}")
        stage = "stopped event"
        stopped = dap.wait_event("stopped")
        thread_id = stopped.get("body", {}).get("threadId")
        if not isinstance(thread_id, int):
            raise ProbeError("stopped event did not provide a thread id")
        threads = dap.request("threads").get("body", {}).get("threads", [])
        if not any(thread.get("id") == thread_id for thread in threads):
            raise ProbeError("stopped thread was absent from threads response")
        frames = dap.request("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 8})
        stack_frames = frames.get("body", {}).get("stackFrames", [])
        frame = next(
            (item for item in stack_frames if item.get("source", {}).get("path") == str(FIXTURE)),
            None,
        )
        if frame is None:
            raise ProbeError("stock Crystal fixture frame was not present in stackTrace")
        scope_response = dap.request("scopes", {"frameId": frame["id"]})
        scopes = scope_response.get("body", {}).get("scopes", [])
        locals_scope = next((scope for scope in scopes if scope.get("name") == "Locals"), None)
        if locals_scope is None:
            raise ProbeError("Locals scope missing")
        variables = dap.request(
            "variables", {"variablesReference": locals_scope["variablesReference"]}
        ).get("body", {}).get("variables", [])
        by_name = {item.get("name"): item for item in variables if isinstance(item, dict)}
        observations: dict[str, Any] = {}
        for name in (
            "native_string_empty",
            "native_string_utf8",
            "native_string_nul",
            "native_string_long",
            "native_array_empty",
            "native_array",
            "native_array_large",
            "native_array_shifted",
        ):
            variable = by_name.get(name)
            if variable is None:
                raise ProbeError(f"fixture local missing: {name}")
            row = {
                "name": name,
                "type": variable.get("type"),
                "value": variable.get("value"),
                "variablesReference": variable.get("variablesReference"),
                "indexedVariables": variable.get("indexedVariables"),
                "namedVariables": variable.get("namedVariables"),
            }
            reference = variable.get("variablesReference")
            if isinstance(reference, int) and reference > 0:
                children = dap.request(
                    "variables",
                    {"variablesReference": reference, "start": 0, "count": 32},
                ).get("body", {}).get("variables", [])
                row["children"] = [
                    {"name": child.get("name"), "type": child.get("type"), "value": child.get("value")}
                    for child in children[:32]
                ]
                row["childrenReturned"] = len(children)
                if formatter_source is not None and name == "native_array_large":
                    at_cap = dap.request(
                        "variables",
                        {"variablesReference": reference, "start": 255, "count": 32},
                    ).get("body", {}).get("variables", [])
                    past_cap = dap.request(
                        "variables",
                        {"variablesReference": reference, "start": 256, "count": 32},
                    ).get("body", {}).get("variables", [])
                    row["pageAtCap"] = [
                        {"name": child.get("name"), "type": child.get("type"), "value": child.get("value")}
                        for child in at_cap
                    ]
                    row["pagePastCap"] = [
                        {"name": child.get("name"), "type": child.get("type"), "value": child.get("value")}
                        for child in past_cap
                    ]
            observations[name] = row
        result = {
            "stopReason": stopped.get("body", {}).get("reason"),
            "sourceLine": frame.get("line"),
            "formatterEnabled": formatter_source is not None,
            "variables": observations,
        }
        assert_probe_observations(result, formatter_source is not None)
        return result
    except Exception as error:
        excerpt = dap.stderr_excerpt()
        raise ProbeError(f"{stage}: {error}; LLDB-DAP stderr excerpt: {excerpt}") from error
    finally:
        dap.close()


def breakpoint_line() -> int:
    for line_number, line in enumerate(FIXTURE.read_text(encoding="utf-8").splitlines(), 1):
        if "DAP_BREAKPOINT: native values" in line:
            return line_number
    raise ProbeError("fixture breakpoint marker missing")


def assert_probe_observations(result: dict[str, Any], formatted: bool) -> None:
    """Fail closed unless both modes match their native-value golden contract."""
    if result.get("stopReason") != "breakpoint":
        raise ProbeError("fixture did not stop at the expected breakpoint")
    variables = result["variables"]
    string_names = (
        "native_string_empty",
        "native_string_utf8",
        "native_string_nul",
        "native_string_long",
    )
    array_names = (
        "native_array_empty",
        "native_array",
        "native_array_large",
        "native_array_shifted",
    )
    for name in string_names:
        row = variables[name]
        if row.get("type") != "String *":
            raise ProbeError(f"{name} had unexpected real SBValue type: {row.get('type')!r}")
    for name in array_names:
        row = variables[name]
        if row.get("type") != "Array(Int32) *":
            raise ProbeError(f"{name} had unexpected real SBValue type: {row.get('type')!r}")

    if not formatted:
        for name, suffix in (
            ("native_string_empty", "bytesize/length/c"),
            ("native_string_utf8", "bytesize/length/c"),
            ("native_string_nul", "bytesize/length/c"),
            ("native_string_long", "bytesize/length/c"),
        ):
            row = variables[name]
            if not str(row.get("value", "")).startswith("0x"):
                raise ProbeError(f"baseline {name} did not expose a raw pointer")
            children = [child.get("name") for child in row.get("children", [])]
            if children != ["bytesize", "length", "c"]:
                raise ProbeError(f"baseline {name} did not expose raw String fields: {children!r}")
        for name in array_names:
            row = variables[name]
            if not str(row.get("value", "")).startswith("0x"):
                raise ProbeError(f"baseline {name} did not expose a raw pointer")
            children = [child.get("name") for child in row.get("children", [])]
            if children != ["size", "capacity", "offset_to_buffer", "buffer"]:
                raise ProbeError(f"baseline {name} did not expose raw Array fields: {children!r}")
        return

    string_suffixes = {
        "native_string_empty": '"" (0 bytes)',
        "native_string_utf8": '"snowman ☃" (11 bytes)',
        "native_string_nul": '"left\\u0000right" (10 bytes)',
    }
    for name, suffix in string_suffixes.items():
        if not str(variables[name].get("value", "")).endswith(suffix):
            raise ProbeError(f"{name} did not produce its exact String summary: {variables[name].get('value')!r}")
    long_summary = str(variables["native_string_long"].get("value", ""))
    if not long_summary.endswith("(2048 bytes; preview limited to 1024 bytes)") or "…" not in long_summary:
        raise ProbeError("large String summary did not disclose its bounded preview")

    array_suffixes = {
        "native_array_empty": "[] (size=0)",
        "native_array": "[22, 44] (size=2)",
        "native_array_shifted": "[5, 7] (size=2)",
    }
    for name, suffix in array_suffixes.items():
        if not str(variables[name].get("value", "")).endswith(suffix):
            raise ProbeError(f"{name} did not produce its exact Array summary: {variables[name].get('value')!r}")

    empty = variables["native_array_empty"]
    if empty.get("indexedVariables", 0) not in (None, 0) or empty.get("children"):
        raise ProbeError("empty Array unexpectedly exposed indexed children")
    for name, expected in (("native_array", [22, 44]), ("native_array_shifted", [5, 7])):
        row = variables[name]
        children = row.get("children", [])
        observed = [child.get("value") for child in children]
        expected_names = [f"[{index}]" for index in range(len(expected))]
        if observed != [str(item) for item in expected] or [child.get("name") for child in children] != expected_names:
            raise ProbeError(f"{name} indexed values differ from its logical buffer: {children!r}")
        if row.get("indexedVariables") != len(expected) or row.get("childrenReturned") != len(expected):
            raise ProbeError(f"{name} did not expose the exact child count")

    large = variables["native_array_large"]
    if not str(large.get("value", "")).endswith(
        "[0, 1, 2, 3, 4, 5, 6, 7, …] (size=300); preview shows 8 of 300; indexed children capped at 256"
    ):
        raise ProbeError("large Array summary omitted exact size, preview, or child cap")
    if large.get("indexedVariables") != 256:
        raise ProbeError(f"large Array child count is not capped at 256: {large.get('indexedVariables')!r}")
    children = large.get("children", [])
    if len(children) != 32 or [child.get("value") for child in children] != [str(i) for i in range(32)]:
        raise ProbeError("large Array did not return its first 32 exact lazy children")
    if large.get("pageAtCap") != [{"name": "[255]", "type": "int", "value": "255"}]:
        raise ProbeError(f"large Array final allowed child was incorrect: {large.get('pageAtCap')!r}")
    if large.get("pagePastCap"):
        raise ProbeError(f"large Array exposed children past the advertised cap: {large.get('pagePastCap')!r}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, default=DEFAULT_ADAPTER)
    parser.add_argument("--compiler", type=Path, default=DEFAULT_CRYSTAL)
    parser.add_argument("--debugserver", type=Path, default=DEFAULT_DEBUGSERVER)
    parser.add_argument("--formatter-source", type=Path)
    parser.add_argument(
        "--production-controller",
        action="store_true",
        help="build and run the owned Crystal consumer through the production DebugController and embedded profile provider",
    )
    parser.add_argument("--timeout", type=float, default=15.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for label, path in (
        ("adapter", args.adapter),
        ("compiler", args.compiler),
        ("debugserver", args.debugserver),
    ):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ProbeError(f"{label} is not an executable file: {path}")
    if args.formatter_source is not None and not args.formatter_source.is_file():
        raise ProbeError(f"formatter source is not a file: {args.formatter_source}")
    if args.production_controller and args.formatter_source is not None:
        raise ProbeError("--production-controller uses the profile-embedded provider; omit --formatter-source")
    if args.timeout <= 0 or args.timeout > 60:
        raise ProbeError("timeout must be between 0 and 60 seconds")
    with tempfile.TemporaryDirectory(prefix="adamantine-native-crystal-") as temporary:
        private = Path(temporary)
        cache = private / "cache"
        cache.mkdir()
        program = private / "native-values"
        env = os.environ.copy()
        env["CRYSTAL_CACHE_DIR"] = str(cache)
        build_argv = [
            str(args.compiler),
            "build",
            "--debug",
            "-O",
            "0",
            "-o",
            str(program),
        ]
        if os.uname().sysname == "Darwin":
            build_argv.append("--link-flags=-fuse-ld=/usr/bin/ld")
        build_argv.append(str(FIXTURE))
        build = subprocess.run(
            build_argv,
            cwd=private,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if build.returncode != 0:
            raise ProbeError(f"owned Crystal fixture build failed: {build.stderr[-2048:]}")
        production_probe: dict[str, Any] | None = None
        if args.production_controller:
            controller_program = private / "native-controller-probe"
            controller_build_argv = [
                str(args.compiler),
                "build",
                str(ROOT / "scripts/probe_native_crystal_controller.cr"),
                "-o",
                str(controller_program),
            ]
            if os.uname().sysname == "Darwin":
                controller_build_argv[2:2] = ["--link-flags=-fuse-ld=/usr/bin/ld"]
            controller_build = subprocess.run(
                controller_build_argv,
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            if controller_build.returncode != 0:
                raise ProbeError(f"owned DebugController consumer build failed: {controller_build.stderr[-2048:]}")
            controller_env = env.copy()
            controller_env["LLDB_DEBUGSERVER_PATH"] = str(args.debugserver.resolve())
            controller = subprocess.run(
                [
                    str(controller_program),
                    "--adapter",
                    str(args.adapter.resolve()),
                    "--program",
                    str(program.resolve()),
                    "--cwd",
                    str(private.resolve()),
                    "--source",
                    str(FIXTURE.resolve()),
                    "--project-root",
                    str(ROOT.resolve()),
                ],
                cwd=private,
                env=controller_env,
                capture_output=True,
                text=True,
                timeout=90,
            )
            if controller.returncode != 0:
                raise ProbeError(
                    "production DebugController probe failed: "
                    + (controller.stderr[-2048:] or controller.stdout[-2048:])
                )
            production_probe = {
                "mode": "production-DebugController-with-embedded-provider",
                "stdout": controller.stdout.strip(),
                "stderr": controller.stderr[-2048:],
                "fixture": str(program),
            }
        result = {
            "compiler": subprocess.run(
                [str(args.compiler), "--version"], capture_output=True, text=True, check=True, timeout=5
            ).stdout.strip(),
            "adapter": subprocess.run(
                [str(args.adapter), "--version"], capture_output=True, text=True, check=True, timeout=5
            ).stdout.strip(),
            "debugserver": str(args.debugserver.resolve()),
            "program": str(program),
            "formatterSource": str(args.formatter_source.resolve()) if args.formatter_source else None,
            "probe": production_probe
            if production_probe is not None
            else launch_probe(
                    args.adapter.resolve(),
                    args.debugserver.resolve(),
                    program.resolve(),
                    private.resolve(),
                    args.formatter_source.resolve() if args.formatter_source else None,
                    args.timeout,
                ),
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ProbeError, subprocess.SubprocessError, OSError) as error:
        raise SystemExit(f"FAIL: {error}")
