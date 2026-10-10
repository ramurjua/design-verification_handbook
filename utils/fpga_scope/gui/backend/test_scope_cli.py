"""Unit tests for scope_cli.py against a scripted port: python -m unittest test_scope_cli"""

import contextlib
import io
import unittest

import scope_cli
from protocol import Opcode, ScopeClient
from test_protocol import INFO_FRAME, FakePort, ok, reply

PORT_ARGS = ["--port", "FAKE", "--baud", "115200", "--timeout", "0.02"]


def run_cli(replies, *argv):
  port = FakePort(replies)
  out, err = io.StringIO(), io.StringIO()
  with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    code = scope_cli.main(PORT_ARGS + list(argv), scope=ScopeClient(port, timeout=0.02))
  return code, out.getvalue(), err.getvalue(), port


class TestCli(unittest.TestCase):

  def test_info(self):
    code, out, _, _ = run_cli([INFO_FRAME], "info")
    self.assertEqual(code, 0)
    self.assertIn("2 (ch0=1b, ch1=1b)", out)
    self.assertIn("100000000 Hz", out)

  def test_capture(self):
    code, out, _, port = run_cli([
      INFO_FRAME, ok(Opcode.ABORT), ok(Opcode.SET_MODE), ok(Opcode.SET_TRIGGER), ok(Opcode.ARM),
      reply(Opcode.GET_STATUS, bytes.fromhex("03 0008")),
      reply(Opcode.DUMP, bytes.fromhex("0000000001010101")),
      ok(Opcode.ABORT),
    ], "capture", "--trig", "0:rise", "--pre", "4", "--post", "4")
    self.assertEqual(code, 0)
    self.assertIn("ch0: 0 0 0 0 1 1 1 1", out)
    self.assertEqual(port.written[3], bytes.fromhex("AA 02 00 0F A0 00000000000000 00 0004 0004 0001 AC"))
    self.assertEqual(len(port.written), 8)

  def test_capture_without_trigger_gives_up_and_aborts(self):
    armed = reply(Opcode.GET_STATUS, bytes.fromhex("01 0004"))
    code, out, _, port = run_cli([
      INFO_FRAME, ok(Opcode.ABORT), ok(Opcode.SET_MODE), ok(Opcode.SET_TRIGGER), ok(Opcode.ARM),
      armed, armed, ok(Opcode.ABORT),
    ], "capture", "--trig", "0:rise", "--pre", "4", "--post", "4", "--wait", "0")
    self.assertEqual(code, 1)
    self.assertIn("state ARMED", out)
    self.assertEqual(port.written[-1], bytes.fromhex("AA 06 00 00 06"))

  def test_stream(self):
    code, out, _, port = run_cli([
      INFO_FRAME, ok(Opcode.ABORT), ok(Opcode.SET_TRIGGER), ok(Opcode.SET_MODE),
      ok(Opcode.STREAM_START) + b"\x01\x02\x03",
    ], "stream", "3", "--decim", "1000")
    self.assertEqual(code, 0)
    self.assertIn("ch0: 1 0 1", out)
    self.assertIn("ch1: 0 1 1", out)
    self.assertEqual(port.written[2][-3:-1], (1000).to_bytes(2, "big"))

  def test_rejected_command_exits_nonzero(self):
    code, _, err, _ = run_cli([reply(Opcode.ARM, b"\x01")], "arm")
    self.assertEqual(code, 1)
    self.assertIn("ARM rejected", err)

  def test_silent_device_exits_nonzero(self):
    code, _, err, _ = run_cli([b""], "info")
    self.assertEqual(code, 1)
    self.assertIn("no response to GET_INFO", err)

  def test_bad_trigger_spec(self):
    with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
      scope_cli.build_parser().parse_args(PORT_ARGS + ["capture", "--trig", "0:sideways"])


if __name__ == "__main__":
  unittest.main()
