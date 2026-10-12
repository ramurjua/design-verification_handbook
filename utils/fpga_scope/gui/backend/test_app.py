"""Tests for sim_device.py, session.py and app.py, all against the simulated device:
python -m unittest test_app
"""

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fastapi.testclient import TestClient

import app as app_module
from protocol import (
  ChannelTrigger, Mode, ScopeClient, ScopeRejected, ScopeState, ScopeTimeout, TriggerConfig, TriggerType,
)
from sim_device import SimDevice

RISE_CH0 = {"enable": True, "type": "rise", "bit_select": 0}
OFF = {"enable": False, "type": "rise", "bit_select": 0}


def sim_client():
  return ScopeClient(SimDevice(realtime=False), timeout=0.02)


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
    self.assertEqual(self.http.get("/api/ports").json()[0]["device"], "sim")

  def test_commands_need_a_connection(self):
    self.assertEqual(self.http.post("/api/stop").status_code, 409)
    self.assertEqual(self.http.post("/api/stream", json={}).status_code, 409)

  def test_connect_reports_info(self):
    info = self.http.post("/api/connect", json={"port": "sim"}).json()
    self.assertEqual(info["channel_widths"], [1, 1, 4, 8])
    self.assertEqual(info["clk_freq_hz"], 1_000_000)
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
