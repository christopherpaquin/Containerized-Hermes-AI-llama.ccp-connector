"""Unit tests for the mempalace-remote MemoryProvider plugin.

Fully offline: the MCP transport is never touched — call_mcp_tool and the
MCPBridge are monkeypatched or exercised directly with async stubs. See
conftest.py for how `mempalace_remote` becomes importable without a full
Hermes install.
"""

from __future__ import annotations

import asyncio
import json
import threading
import time

import pytest

import mempalace_remote as mp


# ---------------------------------------------------------------------------
# resolve_mcp_target / candidate_server_names — config.yaml parsing
# ---------------------------------------------------------------------------


def _write_config_yaml(tmp_path, mcp_servers):
    import yaml

    (tmp_path / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": mcp_servers}))


def test_resolve_mcp_target_env_placeholder(tmp_path, monkeypatch):
    monkeypatch.setenv("TEST_TOKEN_VAR", "secret-token-123")
    _write_config_yaml(
        tmp_path,
        {"local-lab-mempalace": {"url": "http://10.1.10.17:8765/mcp", "headers": {"Authorization": "Bearer ${TEST_TOKEN_VAR}"}}},
    )
    target = mp.resolve_mcp_target(str(tmp_path), ["local-lab-mempalace"])
    assert target == {"name": "local-lab-mempalace", "url": "http://10.1.10.17:8765/mcp", "token": "secret-token-123"}


def test_resolve_mcp_target_literal_token(tmp_path):
    _write_config_yaml(
        tmp_path,
        {"MemPalace": {"url": "http://10.1.10.17:8765/mcp", "headers": {"Authorization": "Bearer literal-tok"}}},
    )
    target = mp.resolve_mcp_target(str(tmp_path), ["MemPalace"])
    assert target["token"] == "literal-tok"


def test_resolve_mcp_target_falls_back_through_names(tmp_path, monkeypatch):
    monkeypatch.setenv("MEMPALACE_MCP_HTTP_TOKEN", "tok")
    _write_config_yaml(
        tmp_path,
        {"local-lab-mempalace": {"url": "http://x/mcp", "headers": {"Authorization": "Bearer ${MEMPALACE_MCP_HTTP_TOKEN}"}}},
    )
    # First candidate name doesn't exist in config -- must fall through.
    target = mp.resolve_mcp_target(str(tmp_path), ["does-not-exist", "local-lab-mempalace"])
    assert target is not None
    assert target["name"] == "local-lab-mempalace"


def test_resolve_mcp_target_missing_token_env_var_skips_entry(tmp_path, monkeypatch):
    monkeypatch.delenv("UNSET_VAR", raising=False)
    _write_config_yaml(
        tmp_path,
        {"MemPalace": {"url": "http://x/mcp", "headers": {"Authorization": "Bearer ${UNSET_VAR}"}}},
    )
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


def test_resolve_mcp_target_no_config_file(tmp_path):
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


def test_resolve_mcp_target_no_mcp_servers_block(tmp_path):
    (tmp_path / "config.yaml").write_text("model:\n  default: foo\n")
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


def test_resolve_mcp_target_non_mapping_yaml_root(tmp_path):
    (tmp_path / "config.yaml").write_text("- just\n- a\n- list\n")
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


def test_resolve_mcp_target_scalar_yaml_root(tmp_path):
    (tmp_path / "config.yaml").write_text("just a plain string\n")
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


def test_resolve_mcp_target_mcp_servers_not_a_mapping(tmp_path):
    (tmp_path / "config.yaml").write_text("mcp_servers: not a mapping, just a string\n")
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


def test_resolve_mcp_target_entry_headers_not_a_mapping(tmp_path):
    (tmp_path / "config.yaml").write_text(
        "mcp_servers:\n  MemPalace:\n    url: http://x/mcp\n    headers: not a mapping\n"
    )
    assert mp.resolve_mcp_target(str(tmp_path), ["MemPalace"]) is None


# ---------------------------------------------------------------------------
# secret redaction gate
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "here's my key sk-abcdefghijklmnopqrst",
        "token ghp_abcdefghijklmnopqrstuvwxyz12",
        "AKIAABCDEFGHIJKLMNOP is my access key",
        "password: hunter2hunter2",
        "-----BEGIN RSA PRIVATE KEY-----",
        "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
    ],
)
def test_looks_like_secret_positive(text):
    assert mp._looks_like_secret(text)


def test_looks_like_secret_negative():
    assert not mp._looks_like_secret("scar.lab is my primary workstation, raptor.lab is my backup")


# ---------------------------------------------------------------------------
# config.json load/save
# ---------------------------------------------------------------------------


def test_load_plugin_config_defaults_when_missing(tmp_path):
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K
    assert cfg["mcp_server_name"] == mp.DEFAULT_MCP_SERVER_NAME


def test_load_plugin_config_malformed_json_falls_back(tmp_path):
    d = tmp_path / "plugins" / "mempalace-remote"
    d.mkdir(parents=True)
    (d / "config.json").write_text("{not json")
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K


def test_save_config_then_load_roundtrip(tmp_path):
    provider = mp.MempalaceRemoteProvider()
    provider.save_config({"top_k": 9, "wing": "custom_wing", "unknown_key": "ignored"}, str(tmp_path))
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == 9
    assert cfg["wing"] == "custom_wing"
    assert "unknown_key" not in cfg


def _write_raw_plugin_config(tmp_path, raw):
    d = tmp_path / "plugins" / "mempalace-remote"
    d.mkdir(parents=True)
    (d / "config.json").write_text(json.dumps(raw))


def test_load_plugin_config_non_object_root_falls_back(tmp_path):
    _write_raw_plugin_config(tmp_path, [1, 2, 3])
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K


def test_load_plugin_config_non_numeric_top_k_falls_back(tmp_path):
    _write_raw_plugin_config(tmp_path, {"top_k": "not a number"})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K


def test_load_plugin_config_out_of_range_top_k_falls_back(tmp_path):
    _write_raw_plugin_config(tmp_path, {"top_k": 999})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K


def test_load_plugin_config_null_value_falls_back(tmp_path):
    _write_raw_plugin_config(tmp_path, {"top_k": None})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K


def test_load_plugin_config_valid_override_applies(tmp_path):
    _write_raw_plugin_config(tmp_path, {"top_k": 3, "room": "custom-room"})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == 3
    assert cfg["room"] == "custom-room"


def test_load_plugin_config_bool_top_k_falls_back(tmp_path):
    # bool is an int subclass in Python -- must not silently become 0/1.
    _write_raw_plugin_config(tmp_path, {"top_k": True})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["top_k"] == mp.DEFAULT_TOP_K


@pytest.mark.parametrize("bad_value", [None, [], {}, True, ""])
def test_load_plugin_config_invalid_text_field_falls_back(tmp_path, bad_value):
    _write_raw_plugin_config(tmp_path, {"wing": bad_value})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["wing"] == mp.DEFAULT_WING


def test_load_plugin_config_whitespace_only_text_falls_back(tmp_path):
    _write_raw_plugin_config(tmp_path, {"room": "   "})
    cfg = mp.load_plugin_config(str(tmp_path))
    assert cfg["room"] == mp.DEFAULT_ROOM


# ---------------------------------------------------------------------------
# Provider lifecycle with a fake bridge (no real asyncio loop / network)
# ---------------------------------------------------------------------------


class _FakeBridge:
    """Stands in for MCPBridge: records enqueued jobs, returns scripted results."""

    def __init__(self):
        self.enqueued = []
        self.sync_result = None
        self.shutdown_called = False
        self._reject_writes = False

    def call_sync(self, coro_factory, timeout):
        return self.sync_result

    def enqueue_write(self, job):
        if self._reject_writes:
            return False
        self.enqueued.append(job)
        return True

    def shutdown(self, timeout=5.0):
        self.shutdown_called = True


def _provider_with_target(tmp_path):
    provider = mp.MempalaceRemoteProvider()
    provider._bridge = _FakeBridge()
    provider.initialize("sess-1", hermes_home=str(tmp_path), agent_context="primary")
    provider._target = {"name": "MemPalace", "url": "http://x/mcp", "token": "tok"}
    return provider


def test_prefetch_skips_trivial_prompt(tmp_path):
    provider = _provider_with_target(tmp_path)
    assert provider.prefetch("ok") == ""
    assert provider._bridge.call_sync is not None  # sanity


def test_prefetch_skips_non_primary_context(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider._agent_context = "subagent"
    assert provider.prefetch("what do you know about scar.lab") == ""


def test_prefetch_returns_empty_on_bridge_timeout(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider._bridge.sync_result = None
    assert provider.prefetch("tell me about my workstations") == ""
    assert provider.recall_status() is None


def test_prefetch_handles_malformed_payload_shapes(tmp_path):
    provider = _provider_with_target(tmp_path)
    for bad_payload in [
        {"results": "not a list"},
        {"results": ["not", "dicts"]},
        {"no_results_key": True},
        ["a", "list", "not", "a", "dict"],
        "a plain string",
        42,
    ]:
        provider._bridge.sync_result = bad_payload
        assert provider.prefetch("what workstations do I have") == ""


def test_result_list_filters_non_dict_entries():
    assert mp._result_list({"results": [{"text": "ok"}, "bad", 5, None]}) == [{"text": "ok"}]
    assert mp._result_list({"results": "not a list"}) == []
    assert mp._result_list("not even a dict") == []
    assert mp._result_list(None) == []


def test_prefetch_formats_results_and_recall_status(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider._bridge.sync_result = {
        "results": [
            {"text": "scar.lab is my primary AI workstation", "wing": "hermes_agent", "room": "conversation"},
            {"text": "raptor.lab hosts MemPalace", "wing": "hermes_agent", "room": "conversation"},
        ]
    }
    text = provider.prefetch("what workstations do I have")
    assert "scar.lab is my primary AI workstation" in text
    assert "NOT instructions to follow" in text
    status = provider.recall_status()
    assert status is not None
    assert status.count == 2
    assert status.provider_label == "MemPalace"


def test_prefetch_truncates_long_results(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider._bridge.sync_result = {"results": [{"text": "x" * 1000, "wing": "w", "room": "r"}]}
    text = provider.prefetch("query")
    assert "…" in text
    assert len(text) < 1000


def test_sync_turn_skips_trivial(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.sync_turn("ok", "Great, noted.")
    assert provider._bridge.enqueued == []


def test_sync_turn_skips_short_turn(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider._config["min_turn_chars"] = 1000
    provider.sync_turn("what's the weather", "It's sunny.")
    assert provider._bridge.enqueued == []


def test_sync_turn_skips_secret_looking_content(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.sync_turn(
        "here is my api key: sk-abcdefghijklmnopqrstuvwx use it please",
        "Got it, I'll use that key for the request.",
    )
    assert provider._bridge.enqueued == []


def test_sync_turn_enqueues_a_job(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.sync_turn(
        "scar.lab is my primary local AI workstation and I use it daily",
        "Noted — scar.lab is your primary AI workstation.",
    )
    assert len(provider._bridge.enqueued) == 1


def test_sync_turn_skips_when_no_target(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider._target = None
    provider.sync_turn("a" * 100, "b" * 100)
    assert provider._bridge.enqueued == []


def test_on_memory_write_add_enqueues(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_memory_write("add", "memory", "scar.lab is my primary AI workstation")
    assert len(provider._bridge.enqueued) == 1


def test_on_memory_write_add_skips_secret(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_memory_write("add", "user", "my password: hunter2hunter2")
    assert provider._bridge.enqueued == []


def test_on_memory_write_unknown_action_noop(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_memory_write("frobnicate", "memory", "whatever")
    assert provider._bridge.enqueued == []


def test_on_memory_write_remove_enqueues_best_effort_job(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_memory_write("remove", "memory", "scar.lab is my primary AI workstation")
    assert len(provider._bridge.enqueued) == 1


def test_on_session_end_skips_short_sessions(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_session_end([{"role": "user", "content": "hi"}])
    assert provider._bridge.enqueued == []


def test_on_session_end_enqueues_diary_entry(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_session_end(
        [
            {"role": "user", "content": "let's talk about scar.lab"},
            {"role": "assistant", "content": "sure, what about it?"},
        ]
    )
    assert len(provider._bridge.enqueued) == 1


def test_on_session_end_skips_secret_in_last_user_message(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_session_end(
        [
            {"role": "user", "content": "let's talk about scar.lab"},
            {"role": "assistant", "content": "sure, what about it?"},
            {"role": "user", "content": "actually here's my api key sk-abcdefghijklmnopqrst use it"},
        ]
    )
    assert provider._bridge.enqueued == []


def test_get_tool_schemas_is_empty(tmp_path):
    provider = _provider_with_target(tmp_path)
    assert provider.get_tool_schemas() == []


def test_backup_paths_default_empty(tmp_path):
    provider = _provider_with_target(tmp_path)
    assert provider.backup_paths() == []


def test_shutdown_delegates_to_bridge(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.shutdown()
    assert provider._bridge.shutdown_called


def test_is_available_reports_reason_when_sdk_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(mp, "_MCP_SDK_AVAILABLE", False)
    provider = mp.MempalaceRemoteProvider()
    assert provider.is_available() is False
    assert "mcp" in provider.unavailable_reason()


def test_is_available_reports_reason_when_no_config(tmp_path, monkeypatch):
    monkeypatch.setattr(mp, "_MCP_SDK_AVAILABLE", True)
    provider = mp.MempalaceRemoteProvider()
    provider._hermes_home = str(tmp_path)  # empty dir, no config.yaml
    assert provider.is_available() is False
    assert "mcp_servers" in provider.unavailable_reason()


def test_on_session_switch_updates_session_id(tmp_path):
    provider = _provider_with_target(tmp_path)
    provider.on_session_switch("new-session-id")
    assert provider._session_id == "new-session-id"


# ---------------------------------------------------------------------------
# call_mcp_tool response-shape handling (parsing logic only, transport mocked)
# ---------------------------------------------------------------------------


class _FakeTextBlock:
    def __init__(self, text):
        self.text = text


class _FakeCallToolResult:
    def __init__(self, content, is_error=False):
        self.content = content
        self.isError = is_error


def _patch_transport(monkeypatch, call_tool_result):
    """Wire mp.streamablehttp_client / mp.ClientSession to a fake session
    whose call_tool() always returns call_tool_result, and return nothing —
    callers just await mp.call_mcp_tool(...) afterwards."""

    class _FakeSession:
        async def initialize(self):
            return None

        async def call_tool(self, name, args):
            return call_tool_result

    class _FakeStreamCtx:
        async def __aenter__(self):
            return (None, None, None)

        async def __aexit__(self, *a):
            return False

    class _FakeSessionCtx:
        def __init__(self, *a, **kw):
            pass

        async def __aenter__(self):
            return _FakeSession()

        async def __aexit__(self, *a):
            return False

    monkeypatch.setattr(mp, "streamablehttp_client", lambda *a, **kw: _FakeStreamCtx())
    monkeypatch.setattr(mp, "ClientSession", _FakeSessionCtx)


def test_call_mcp_tool_parses_json_text(monkeypatch):
    payload = {"results": [{"text": "hi"}]}
    _patch_transport(monkeypatch, _FakeCallToolResult([_FakeTextBlock(json.dumps(payload))]))
    result = asyncio.run(mp.call_mcp_tool("http://x", "tok", "mempalace_status", {}))
    assert result == payload


def test_call_mcp_tool_returns_none_on_is_error(monkeypatch):
    _patch_transport(monkeypatch, _FakeCallToolResult([_FakeTextBlock("{}")], is_error=True))
    result = asyncio.run(mp.call_mcp_tool("http://x", "tok", "mempalace_status", {}))
    assert result is None


def test_call_mcp_tool_returns_none_on_non_json_text(monkeypatch):
    _patch_transport(monkeypatch, _FakeCallToolResult([_FakeTextBlock("not json at all")]))
    result = asyncio.run(mp.call_mcp_tool("http://x", "tok", "mempalace_status", {}))
    assert result is None


def test_call_mcp_tool_returns_none_on_empty_content(monkeypatch):
    _patch_transport(monkeypatch, _FakeCallToolResult([]))
    result = asyncio.run(mp.call_mcp_tool("http://x", "tok", "mempalace_status", {}))
    assert result is None


# ---------------------------------------------------------------------------
# MCPBridge: queue overflow, shutdown, post-shutdown enqueue is a no-op
# ---------------------------------------------------------------------------


def test_bridge_shutdown_is_bounded_and_idempotent():
    bridge = mp.MCPBridge()
    bridge._ensure_started()
    bridge.shutdown(timeout=2.0)
    # A second shutdown call must not hang or raise.
    bridge.shutdown(timeout=2.0)


def test_bridge_enqueue_after_shutdown_is_noop():
    bridge = mp.MCPBridge()
    bridge._ensure_started()
    bridge.shutdown(timeout=2.0)
    assert bridge.enqueue_write(lambda: None) is False


def test_bridge_call_sync_after_shutdown_returns_none():
    bridge = mp.MCPBridge()
    bridge._ensure_started()
    bridge.shutdown(timeout=2.0)

    async def _coro():
        return {"ok": True}

    assert bridge.call_sync(_coro, timeout=1.0) is None


def test_bridge_processes_enqueued_write():
    bridge = mp.MCPBridge()
    done = threading.Event()
    results = []

    async def _job():
        results.append("ran")
        done.set()

    assert bridge.enqueue_write(_job) is True
    assert done.wait(timeout=3.0)
    assert results == ["ran"]
    bridge.shutdown(timeout=2.0)


def test_bridge_call_sync_returns_value():
    bridge = mp.MCPBridge()

    async def _coro():
        return {"hello": "world"}

    assert bridge.call_sync(_coro, timeout=2.0) == {"hello": "world"}
    bridge.shutdown(timeout=2.0)


def test_bridge_call_sync_times_out_gracefully():
    bridge = mp.MCPBridge()

    async def _slow():
        await asyncio.sleep(5)
        return "too slow"

    assert bridge.call_sync(_slow, timeout=0.2) is None
    bridge.shutdown(timeout=2.0)


def test_bridge_drains_queued_jobs_before_shutdown_returns():
    bridge = mp.MCPBridge()
    ran = []

    def _make_job(n):
        async def _job():
            await asyncio.sleep(0.05)
            ran.append(n)

        return _job

    for n in range(5):
        bridge.enqueue_write(_make_job(n))

    # Shutdown is called almost immediately -- all 5 already-queued jobs must
    # still complete within the drain budget, not be silently dropped.
    bridge.shutdown(timeout=3.0)
    assert sorted(ran) == [0, 1, 2, 3, 4]


def test_bridge_hung_write_times_out_without_blocking_shutdown_forever():
    bridge = mp.MCPBridge()
    started = threading.Event()

    async def _hung_job():
        started.set()
        await asyncio.sleep(mp.WRITE_INNER_TIMEOUT_S + 30)  # far longer than its own timeout

    bridge.enqueue_write(_hung_job)
    assert started.wait(timeout=2.0)

    start = time.monotonic()
    # shutdown's own drain budget bounds this regardless of the job's timeout.
    bridge.shutdown(timeout=2.0)
    elapsed = time.monotonic() - start
    assert elapsed < 5.0


def test_bridge_shutdown_logs_when_drain_budget_expires_with_work_pending(caplog):
    """Best-effort draining can still lose work when the aggregate queue
    takes longer than the shutdown budget -- that loss must be logged, not
    silent (see MCPBridge's docstring on the best-effort drain contract)."""
    bridge = mp.MCPBridge()

    async def _slow_job():
        await asyncio.sleep(mp.WRITE_INNER_TIMEOUT_S + 30)

    bridge.enqueue_write(_slow_job)
    time.sleep(0.1)  # let it actually start running before the tight shutdown budget
    with caplog.at_level("WARNING"):
        bridge.shutdown(timeout=0.3)
    assert any("still running" in r.message for r in caplog.records)
