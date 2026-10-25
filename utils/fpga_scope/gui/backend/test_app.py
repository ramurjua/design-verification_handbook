"""Tests for sim_device.py, session.py and app.py, all against the simulated device:
python -m unittest test_app
"""

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fastapi.testclient import TestClient

import app as app_module
from protocol import (
  ChannelTrigger, Mode, Opcode, ScopeClient, ScopeError, ScopeRejected, ScopeState, ScopeTimeout, TriggerConfig,
  TriggerType,
)
from sim_device import SimDevice

RISE_CH0 = {"enable": True, "type": "rise", "bit_select": 0}
OFF = {"enable": False, "type": "rise", "bit_select": 0}


def sim_client(**kwargs):
  return ScopeClient(SimDevice(realtime=False, **kwargs), timeout=0.02)


class TestSimDevice(unittest.TestCase):

  def test_info(self):
    info = sim_client().get_info()
    self.assertEqual(info.channel_widths[:info.num_channels], (1, 1, 4, 8))
    self.assertEqual(info.frame_bytes, 2)
    self.assertEqual(info.buffer_depth, 1024)

  def test_capture_is_centred_on_the_trigger(self):
    scope = sim_client()
    info = scope.get_info()
    scope.set_trigger(TriggerConfig([ChannelTrigger(True, TriggerType.EDGE_RISE)], pre_trigger_count=8, post_trigger_count=8))
    scope.arm()
    self.assertEqual(scope.get_status().state, ScopeState.DONE)
    ch0 = info.split_channels(scope.dump())[0]
    self.assertEqual(ch0, [0] * 8 + [1] * 8)

  def test_done_blocks_until_abort(self):
    scope = sim_client()
    scope.set_trigger(TriggerConfig([ChannelTrigger(True, TriggerType.LEVEL_HIGH)], post_trigger_count=4))
    scope.arm()
    with self.assertRaises(ScopeRejected):
      scope.arm()
    with self.assertRaises(ScopeRejected):
      scope.set_mode(Mode.STREAM)
    scope.abort()
    scope.arm()

  def test_no_trigger_enabled_stays_armed_and_dump_is_ignored(self):
    scope = sim_client()
    scope.set_trigger(TriggerConfig(post_trigger_count=4))
    scope.arm()
    self.assertEqual(scope.get_status().state, ScopeState.ARMED)
    with self.assertRaises(ScopeTimeout):
      scope.dump()

  def test_stream(self):
    scope = sim_client()
    info = scope.get_info()
    with self.assertRaises(ScopeRejected):
      scope.stream(4) # still in scope mode
    scope.set_mode(Mode.STREAM)
    ramp = info.split_channels(scope.stream(32))[2]
    self.assertEqual(ramp, [i // 8 for i in range(32)])
    self.assertEqual(info.split_channels(scope.stream(8))[2], [4] * 8) # carries on where the last burst ended


  def test_controls_start_at_zero_and_keep_what_is_written(self):
    scope = sim_client()
    self.assertEqual(scope.get_info().num_controls, 8)
    self.assertEqual(scope.read_controls(), [0] * 8)
    scope.write_control(3, 0xDEADBEEF)
    scope.write_control(7, 1)
    self.assertEqual(scope.read_controls(), [0, 0, 0, 0xDEADBEEF, 0, 0, 0, 1])

  def test_controls_do_not_depend_on_the_capture_state(self):
    scope = sim_client()
    scope.set_trigger(TriggerConfig(post_trigger_count=4)) # no trigger enabled: stays armed
    scope.arm()
    scope.write_control(0, 5)
    self.assertEqual(scope.get_status().state, ScopeState.ARMED)
    scope.abort() # an abort is not a reset
    self.assertEqual(scope.read_control(0), 5)

  def test_malformed_control_frames(self):
    scope = sim_client()
    scope.get_info()
    with self.assertRaises(ScopeRejected):
      scope._status_command(Opcode.CONTROL_WRITE, bytes([8, 0, 0, 0, 1])) # no control 8
    with self.assertRaises(ScopeRejected):
      scope._status_command(Opcode.CONTROL_WRITE, bytes([1, 0, 0, 1])) # a byte short
    with self.assertRaises(ScopeTimeout):
      scope._command(Opcode.CONTROL_READ, bytes([8]))
    self.assertEqual(scope.read_controls(), [0] * 8)

  def test_a_core_from_before_the_controls_ignores_their_commands(self):
    scope = sim_client(protocol_version=1)
    self.assertEqual(scope.get_info().num_controls, 0)
    with self.assertRaises(ScopeError):
      scope.write_control(0, 1)
    with self.assertRaises(ScopeTimeout):
      scope._command(Opcode.CONTROL_WRITE, bytes([0, 0, 0, 0, 1])) # what it does if asked anyway


class TestSimStates(unittest.TestCase):
  """The sim-fsm port: state machines for named values, matching gui/examples/sim-fsm.json."""

  EXAMPLE = Path(__file__).resolve().parent.parent / "examples" / "sim-fsm.json"

  def capture(self, scope):
    info = scope.get_info()
    scope.set_trigger(TriggerConfig([ChannelTrigger(True, TriggerType.EDGE_RISE)], pre_trigger_count=0, post_trigger_count=1000, decimation=2))
    scope.arm()
    return info.split_channels(scope.dump())

  def test_states_are_the_ones_the_example_names(self):
    config = json.loads(self.EXAMPLE.read_text(encoding="utf-8"))["channels"]
    scope = sim_client(signals="states")
    self.assertEqual(scope.get_info().channel_widths[:4], (1, 4, 8, 8))
    _, sensor, state, _ = self.capture(scope)
    card, fsm = (field["values"] for field in config["2"]["fields"])
    self.assertEqual({str(v >> 4) for v in state} - set(card), set())
    self.assertEqual({str(v & 15) for v in state} - set(fsm), set())
    self.assertGreaterEqual(len({v & 15 for v in state}), 6, "a capture shows most of the run")
    self.assertEqual({str(v) for v in sensor} - set(config["1"]["values"]), {"6"}, "one state without a name, on purpose")

  def test_control_0_sets_the_speed(self):
    scope = sim_client(signals="states")
    slow = max(self.capture(scope)[3])
    scope.abort()
    scope.write_control(0, 2)
    self.assertEqual((slow, max(self.capture(scope)[3])), (60, 180))


class TestApp(unittest.TestCase):

  def setUp(self):
    self.http = TestClient(app_module.app)
    self.http.__enter__()
    self.addCleanup(self.http.__exit__, None, None, None)

  def receive_until(self, ws, kind):
    seen = []
    while True:
      message = ws.receive_json()
      seen.append(message)
      if message["type"] == kind:
        return message, seen

  def test_serves_frontend(self):
    self.assertEqual(self.http.get("/").status_code, 200)

  def test_ports_include_sim(self):
    ports = [p["device"] for p in self.http.get("/api/ports").json()]
    self.assertEqual(ports[:2], ["sim", "sim-fsm"])
    self.assertNotIn("sim-v1", ports) # the old-core stand-in is for tests, not for the list

  def test_commands_need_a_connection(self):
    self.assertEqual(self.http.post("/api/stop").status_code, 409)
    self.assertEqual(self.http.post("/api/stream", json={}).status_code, 409)
    self.assertEqual(self.http.get("/api/controls").status_code, 409)
    self.assertEqual(self.http.post("/api/controls/0", json={"value": 1}).status_code, 409)

  def test_connect_reports_info(self):
    info = self.http.post("/api/connect", json={"port": "sim"}).json()
    self.assertEqual(info["channel_widths"], [1, 1, 4, 8])
    self.assertEqual(info["clk_freq_hz"], 1_000_000)
    self.assertEqual((info["protocol_version"], info["num_controls"]), (2, 8))
    self.assertEqual(self.http.get("/api/state").json()["state"], "idle")

  def test_bad_port_is_a_502(self):
    r = self.http.post("/api/connect", json={"port": "COM_DOES_NOT_EXIST"})
    self.assertEqual(r.status_code, 502)

  def test_capture_over_websocket(self):
    self.http.post("/api/connect", json={"port": "sim"})
    with self.http.websocket_connect("/ws") as ws:
      self.assertEqual(ws.receive_json()["type"], "hello")
      r = self.http.post("/api/capture", json={"channels": [RISE_CH0, OFF, OFF, OFF], "pre": 50, "post": 150})
      self.assertEqual(r.status_code, 200)
      capture, seen = self.receive_until(ws, "capture")
      self.assertIn({"type": "state", "state": "armed", "fill_count": 0}, seen)
      self.assertEqual(len(capture["channels"]), 4)
      self.assertEqual(len(capture["channels"][0]), 200)
      self.assertEqual(capture["channels"][0][49:51], [0, 1]) # rising edge at the trigger sample
      self.assertEqual(capture["pre"], 50)
      state, _ = self.receive_until(ws, "state")
      self.assertEqual(state["state"], "idle")

  def test_capture_validation(self):
    self.http.post("/api/connect", json={"port": "sim"})
    no_trigger = self.http.post("/api/capture", json={"channels": [OFF], "pre": 10, "post": 10})
    self.assertEqual(no_trigger.status_code, 400)
    too_long = self.http.post("/api/capture", json={"channels": [RISE_CH0], "pre": 1000, "post": 1000})
    self.assertEqual(too_long.status_code, 400)
    whole_buffer = self.http.post("/api/capture", json={"channels": [RISE_CH0], "pre": 512, "post": 512})
    self.assertEqual(whole_buffer.status_code, 400) # 1024-sample buffer: at most 1023
    no_post = self.http.post("/api/capture", json={"channels": [RISE_CH0], "pre": 1023, "post": 0})
    self.assertEqual(no_post.status_code, 400)
    bad_type = self.http.post("/api/capture", json={"channels": [{"enable": True, "type": "sideways"}], "pre": 1, "post": 1})
    self.assertEqual(bad_type.status_code, 422)

  def test_stop_an_armed_capture(self):
    self.http.post("/api/connect", json={"port": "sim"})
    # bit 7 of the 4-bit ramp channel is never set, so this trigger cannot fire
    never = {"enable": True, "type": "high", "bit_select": 7}
    self.http.post("/api/capture", json={"channels": [OFF, OFF, never, OFF], "pre": 10, "post": 10})
    self.assertEqual(self.http.get("/api/state").json()["state"], "armed")
    self.assertEqual(self.http.post("/api/stop").status_code, 200)
    self.assertEqual(self.http.get("/api/state").json()["state"], "idle")

  def test_stream_over_websocket(self):
    self.http.post("/api/connect", json={"port": "sim"})
    with self.http.websocket_connect("/ws") as ws:
      ws.receive_json()
      self.http.post("/api/stream", json={"decimation": 8, "batch": 50})
      first, _ = self.receive_until(ws, "stream")
      second, _ = self.receive_until(ws, "stream")
      self.assertEqual(first["channels"][2][:17], list(range(16)) + [0]) # ramp steps once per sample at decimation 8
      self.assertEqual(len(second["channels"][0]), 50)
      self.http.post("/api/stop")
    self.assertEqual(self.http.get("/api/state").json()["state"], "idle")


  def test_controls_are_written_and_read_back(self):
    self.http.post("/api/connect", json={"port": "sim"})
    self.assertEqual(self.http.get("/api/controls").json(), {"values": [0] * 8})
    r = self.http.post("/api/controls/2", json={"value": 1234})
    self.assertEqual((r.status_code, r.json()), (200, {"value": 1234}))
    r = self.http.post("/api/controls/7", json={"value": 0xFFFFFFFF})
    self.assertEqual(r.json(), {"value": 0xFFFFFFFF})
    self.assertEqual(self.http.get("/api/controls").json(), {"values": [0, 0, 1234, 0, 0, 0, 0, 0xFFFFFFFF]})

  def test_control_validation(self):
    self.http.post("/api/connect", json={"port": "sim"})
    self.assertEqual(self.http.post("/api/controls/8", json={"value": 1}).status_code, 400)
    self.assertEqual(self.http.post("/api/controls/-1", json={"value": 1}).status_code, 400)
    self.assertEqual(self.http.post("/api/controls/0", json={"value": -1}).status_code, 422)
    self.assertEqual(self.http.post("/api/controls/0", json={"value": 0x1_0000_0000}).status_code, 422)
    self.assertEqual(self.http.post("/api/controls/0", json={"value": 1.5}).status_code, 422)
    self.assertEqual(self.http.post("/api/controls/0", json={}).status_code, 422)
    self.assertEqual(self.http.post("/api/controls/zero", json={"value": 1}).status_code, 422)
    self.assertEqual(self.http.get("/api/controls").json(), {"values": [0] * 8})

  def test_a_core_without_controls(self):
    info = self.http.post("/api/connect", json={"port": "sim-v1"}).json()
    self.assertEqual((info["protocol_version"], info["num_controls"]), (1, 0))
    self.assertEqual(self.http.get("/api/controls").json(), {"values": []})
    r = self.http.post("/api/controls/0", json={"value": 1})
    self.assertEqual(r.status_code, 400)
    self.assertIn("no controls", r.json()["detail"])
    # and the rest of it still works
    self.assertEqual(self.http.post("/api/stream", json={"batch": 20}).status_code, 200)
    self.assertEqual(self.http.post("/api/stop").status_code, 200)

  def test_control_write_while_a_capture_is_armed(self):
    self.http.post("/api/connect", json={"port": "sim"})
    never = {"enable": True, "type": "high", "bit_select": 7}
    self.http.post("/api/capture", json={"channels": [OFF, OFF, never, OFF], "pre": 10, "post": 10})
    for value in range(1, 6): # several, so that some land while the job is polling the status
      self.assertEqual(self.http.post("/api/controls/1", json={"value": value}).json(), {"value": value})
    self.assertEqual(self.http.get("/api/state").json()["state"], "armed")
    self.http.post("/api/stop")
    self.assertEqual(self.http.get("/api/controls").json()["values"][1], 5)

  def test_control_write_while_streaming(self):
    self.http.post("/api/connect", json={"port": "sim"})
    with self.http.websocket_connect("/ws") as ws:
      ws.receive_json()
      self.http.post("/api/stream", json={"decimation": 8, "batch": 50})
      self.receive_until(ws, "stream")
      for value in (7, 8, 9):
        r = self.http.post("/api/controls/4", json={"value": value})
        self.assertEqual((r.status_code, r.json()), (200, {"value": value}))
      # the stream is still alive and its samples are still in step: nothing of the control exchange leaked into a burst
      _, seen = self.receive_until(ws, "stream")
      self.assertNotIn("error", [m["type"] for m in seen])
      later, _ = self.receive_until(ws, "stream")
      ramp = later["channels"][2]
      self.assertEqual(len(ramp), 50)
      self.assertTrue(all((b - a) % 16 == 1 for a, b in zip(ramp, ramp[1:])), ramp)
      self.assertEqual(self.http.get("/api/state").json()["state"], "streaming")
      self.http.post("/api/stop")
    self.assertEqual(self.http.get("/api/controls").json()["values"][4], 9)


class TestConfigs(unittest.TestCase):

  def setUp(self):
    self.dir = Path(self.enterContext(tempfile.TemporaryDirectory())) / "configs" # not created yet, as on a fresh checkout
    self.enterContext(mock.patch.object(app_module, "CONFIG_DIR", self.dir))
    self.http = self.enterContext(TestClient(app_module.app))

  def test_empty_before_anything_is_saved(self):
    self.assertEqual(self.http.get("/api/configs").json(), [])
    self.assertEqual(self.http.get("/api/configs/nothing").status_code, 404)
    self.assertEqual(self.http.delete("/api/configs/nothing").status_code, 404)

  def test_save_list_load_delete(self):
    config = {"version": 1, "channels": [{"name": "gyro_x", "unit": "\u00b0/s", "gain": 0.0625}]}
    self.assertEqual(self.http.put("/api/configs/drone_imu", json=config).status_code, 200)
    self.assertEqual(self.http.put("/api/configs/a-2", json={}).status_code, 200)
    self.assertEqual(self.http.get("/api/configs").json(), ["a-2", "drone_imu"])
    self.assertEqual(self.http.get("/api/configs/drone_imu").json(), config)
    self.assertTrue((self.dir / "drone_imu.json").is_file()) # on disk, where the user can keep or copy it
    self.assertEqual(self.http.delete("/api/configs/a-2").status_code, 200)
    self.assertEqual(self.http.get("/api/configs").json(), ["drone_imu"])

  def test_saving_again_overwrites(self):
    self.http.put("/api/configs/one", json={"n": 1})
    self.http.put("/api/configs/one", json={"n": 2})
    self.assertEqual(self.http.get("/api/configs/one").json(), {"n": 2})

  def test_names_cannot_leave_the_directory(self):
    for name in ["..%2Fescaped", "..%5Cescaped", "..", "a.b", "with space", "x" * 65]:
      r = self.http.put(f"/api/configs/{name}", json={})
      self.assertNotEqual(r.status_code, 200, name)
    self.assertEqual(list(self.dir.parent.rglob("*.json")), [])

  def test_body_must_be_an_object(self):
    self.assertEqual(self.http.put("/api/configs/list", json=[1, 2]).status_code, 422)

  def test_unreadable_file_is_reported(self):
    self.dir.mkdir()
    (self.dir / "broken.json").write_text("{not json", encoding="utf-8")
    self.assertEqual(self.http.get("/api/configs/broken").status_code, 500)


if __name__ == "__main__":
  unittest.main()
