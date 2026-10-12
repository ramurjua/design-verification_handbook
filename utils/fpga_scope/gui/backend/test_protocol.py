"""Unit tests for protocol.py, no serial port needed: python -m unittest test_protocol

The byte vectors are the ones ../../test/scope_tb.v sends to / checks against
the RTL (2 channels x 1 bit, buffer_depth_log2 = 4, 100 MHz).
"""

import unittest

from protocol import (
  ChannelTrigger, Mode, Opcode, ScopeClient, ScopeError, ScopeInfo, ScopeRejected, ScopeState,
  ScopeTimeout, TriggerConfig, TriggerType, encode_frame, SYNC_DEV,
)

INFO_PAYLOAD = bytes.fromhex("02 03 02 0101000000000000 04 01 05F5E100")
INFO_FRAME = encode_frame(Opcode.GET_INFO, INFO_PAYLOAD, sync=SYNC_DEV)
# the same core built from the RTL as it was before the controls: protocol version 1
OLD_INFO_FRAME = encode_frame(Opcode.GET_INFO, b"\x01" + INFO_PAYLOAD[1:], sync=SYNC_DEV)


def reply(opcode, payload):
  return encode_frame(opcode, payload, sync=SYNC_DEV)


def ok(opcode):
  return reply(opcode, b"\x00")


class FakePort:
  """Hands out one scripted reply per frame written, `chunk` bytes per read."""

  def __init__(self, replies, chunk=None):
    self.replies = list(replies)
    self.written = []
    self.pending = bytearray()
    self.chunk = chunk

  def write(self, data):
    self.written.append(bytes(data))
    if self.replies:
      self.pending += self.replies.pop(0)

  def read(self, size):
    size = min(size, self.chunk or size)
    out = bytes(self.pending[:size])
    del self.pending[:size]
    return out

  def reset_input_buffer(self):
    self.pending.clear()


def client(replies, chunk=None):
  port = FakePort(replies, chunk)
  return ScopeClient(port, timeout=0.02), port


class TestFrames(unittest.TestCase):

  def test_encode_no_payload(self):
    self.assertEqual(encode_frame(Opcode.GET_INFO), bytes.fromhex("AA 01 00 00 01"))

  def test_encode_stream_start(self):
    self.assertEqual(encode_frame(Opcode.STREAM_START, (5).to_bytes(4, "big")),
                     bytes.fromhex("AA 08 00 04 00000005 09"))

  def test_set_trigger_payload(self):
    cfg = TriggerConfig(channels=[ChannelTrigger(True, TriggerType.EDGE_RISE)],
                        pre_trigger_count=4, post_trigger_count=4, decimation=1)
    self.assertEqual(encode_frame(Opcode.SET_TRIGGER, cfg.pack()),
                     bytes.fromhex("AA 02 00 0F A0 00000000000000 00 0004 0004 0001 AC"))

  def test_encode_control_write(self):
    # control 3 = 0xDEADBEEF, as in scope_tb.v's Test 7
    self.assertEqual(encode_frame(Opcode.CONTROL_WRITE, bytes([3]) + (0xDEADBEEF).to_bytes(4, "big")),
                     bytes.fromhex("AA 09 00 05 03 DEADBEEF 2D"))

  def test_encode_control_read(self):
    self.assertEqual(encode_frame(Opcode.CONTROL_READ, bytes([3])), bytes.fromhex("AA 0A 00 01 03 08"))

  def test_channel_cfg_bits(self):
    self.assertEqual(ChannelTrigger(True, TriggerType.EDGE_FALL, 5).pack(), 0b1011_0101)
    self.assertEqual(ChannelTrigger(False, TriggerType.LEVEL_HIGH, 0).pack(), 0b0001_0000)

  def test_trigger_range_checks(self):
    with self.assertRaises(ValueError):
      ChannelTrigger(True, bit_select=8).pack()
    with self.assertRaises(ValueError):
      TriggerConfig(pre_trigger_count=0x10000).pack()
    with self.assertRaises(ValueError):
      TriggerConfig(channels=[ChannelTrigger()] * 9).pack()


class TestInfo(unittest.TestCase):

  def test_unpack(self):
    info = ScopeInfo.unpack(INFO_PAYLOAD)
    self.assertEqual(info.protocol_version, 2)
    self.assertEqual(info.num_controls, 8)
    self.assertTrue(info.supports(Mode.SCOPE) and info.supports(Mode.STREAM))
    self.assertEqual(info.num_channels, 2)
    self.assertEqual(info.channel_widths, (1, 1, 0, 0, 0, 0, 0, 0))
    self.assertEqual(info.buffer_depth, 16)
    self.assertEqual(info.frame_bytes, 1)
    self.assertEqual(info.clk_freq_hz, 100_000_000)
    self.assertEqual(info.max_capture_samples, 16)

  def test_a_core_from_before_the_controls_has_none(self):
    self.assertEqual(ScopeInfo.unpack(b"\x01" + INFO_PAYLOAD[1:]).num_controls, 0)

  def test_max_capture_capped_by_len_field(self):
    info = ScopeInfo(1, 3, 8, (8,) * 8, 15, 8, 100_000_000)
    self.assertEqual(info.max_capture_samples, 8191)

  def test_multibyte_samples(self):
    # 3-bit + 8-bit channel = 11 bits = 2 bytes per sample, MSB first, channel 0 at the LSB end
    info = ScopeInfo(1, 3, 2, (3, 8, 0, 0, 0, 0, 0, 0), 4, 2, 100_000_000)
    samples = info.unpack_samples(bytes.fromhex("02AD 07FF"))
    self.assertEqual(samples, [0x02AD, 0x07FF])
    self.assertEqual(info.split_channels(samples), [[5, 7], [0x55, 0xFF]])


class TestClient(unittest.TestCase):

  def test_get_info(self):
    scope, port = client([INFO_FRAME])
    self.assertEqual(scope.get_info().num_channels, 2)
    self.assertEqual(port.written, [bytes.fromhex("AA 01 00 00 01")])

  def test_capture_sequence(self):
    scope, port = client([
      INFO_FRAME,
      ok(Opcode.ARM),
      bytes.fromhex("55 04 00 03 03 0008 0C"),
      bytes.fromhex("55 05 00 08 0000000001010101 0D"),
      ok(Opcode.ABORT),
    ])
    info = scope.get_info()
    scope.arm()
    status = scope.get_status()
    self.assertEqual((status.state, status.fill_count), (ScopeState.DONE, 8))
    samples = scope.dump()
    self.assertEqual(samples, [0, 0, 0, 0, 1, 1, 1, 1])
    self.assertEqual(info.split_channels(samples), [[0, 0, 0, 0, 1, 1, 1, 1], [0] * 8])
    scope.abort()
    self.assertEqual(port.written[1:], [
      bytes.fromhex("AA 03 00 00 03"), bytes.fromhex("AA 04 00 00 04"),
      bytes.fromhex("AA 05 00 00 05"), bytes.fromhex("AA 06 00 00 06"),
    ])

  def test_stream_burst(self):
    scope, port = client([INFO_FRAME, ok(Opcode.SET_MODE), ok(Opcode.STREAM_START) + b"\x01" * 5])
    scope.get_info()
    scope.set_mode(Mode.STREAM)
    self.assertEqual(scope.stream(5), [1] * 5)
    self.assertEqual(port.written[1], bytes.fromhex("AA 07 00 01 01 07"))
    self.assertEqual(port.written[2], bytes.fromhex("AA 08 00 04 00000005 09"))

  def test_stream_samples_that_look_like_sync(self):
    scope, _ = client([INFO_FRAME, ok(Opcode.STREAM_START) + b"\x55" * 4])
    scope.get_info()
    self.assertEqual(scope.stream(4), [0x55] * 4)

  def test_stream_short_burst_times_out(self):
    scope, _ = client([INFO_FRAME, ok(Opcode.STREAM_START) + b"\x01" * 3])
    scope.get_info()
    with self.assertRaises(ScopeTimeout):
      scope.stream(5)

  def test_rejected(self):
    scope, _ = client([reply(Opcode.ARM, b"\x01")])
    with self.assertRaises(ScopeRejected) as ctx:
      scope.arm()
    self.assertEqual(ctx.exception.status, 0x01)

  def test_no_response_times_out(self):
    scope, _ = client([b""])
    with self.assertRaises(ScopeTimeout):
      scope.get_status()

  def test_bad_checksum_is_dropped(self):
    frame = bytearray(ok(Opcode.ARM))
    frame[-1] ^= 0xFF
    scope, _ = client([bytes(frame)])
    with self.assertRaises(ScopeTimeout):
      scope.arm()

  def test_byte_at_a_time_delivery(self):
    scope, _ = client([INFO_FRAME], chunk=1)
    self.assertEqual(scope.get_info().clk_freq_hz, 100_000_000)

  def test_resync_past_garbage(self):
    # line noise, a false SYNC, and a frame with a bad checksum, all before the real reply
    bad = bytearray(ok(Opcode.ARM))
    bad[-1] ^= 0xFF
    scope, _ = client([b"\x00\xFF\x55\x13" + bytes(bad) + ok(Opcode.ARM)])
    scope.arm()

  def test_abort_skips_leftover_burst(self):
    # ABORT lands mid-burst: raw sample bytes (including 0x55s) precede its status frame
    scope, _ = client([b"\x55\x06\x55\x55\x01\x00" + ok(Opcode.ABORT)])
    scope.abort()

  def test_stale_input_is_flushed_before_a_command(self):
    scope, port = client([ok(Opcode.ARM)])
    port.pending += reply(Opcode.ARM, b"\x01") # left over from an earlier exchange
    scope.arm()


class TestControls(unittest.TestCase):

  def test_write(self):
    scope, port = client([INFO_FRAME, ok(Opcode.CONTROL_WRITE)])
    scope.write_control(3, 0xDEADBEEF)
    self.assertEqual(port.written[1], bytes.fromhex("AA 09 00 05 03 DEADBEEF 2D"))

  def test_write_largest_and_smallest(self):
    scope, port = client([INFO_FRAME, ok(Opcode.CONTROL_WRITE), ok(Opcode.CONTROL_WRITE)])
    scope.write_control(7, 0xFFFFFFFF)
    scope.write_control(0, 0)
    self.assertEqual(port.written[1][4:9], bytes.fromhex("07 FFFFFFFF"))
    self.assertEqual(port.written[2][4:9], bytes.fromhex("00 00000000"))

  def test_read(self):
    # the reply scope_tb.v checks byte by byte
    scope, port = client([INFO_FRAME, bytes.fromhex("55 0A 00 05 03 DEADBEEF 2E")])
    self.assertEqual(scope.read_control(3), 0xDEADBEEF)
    self.assertEqual(port.written[1], bytes.fromhex("AA 0A 00 01 03 08"))

  def test_read_all(self):
    replies = [reply(Opcode.CONTROL_READ, bytes([i]) + (i * 1000).to_bytes(4, "big")) for i in range(8)]
    scope, port = client([INFO_FRAME] + replies)
    self.assertEqual(scope.read_controls(), [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000])
    self.assertEqual(len(port.written), 9)

  def test_answer_for_another_control_is_an_error(self):
    scope, _ = client([INFO_FRAME, reply(Opcode.CONTROL_READ, bytes([4]) + bytes(4))])
    with self.assertRaises(ScopeError):
      scope.read_control(3)

  def test_rejected_write(self):
    scope, _ = client([INFO_FRAME, reply(Opcode.CONTROL_WRITE, b"\x01")])
    with self.assertRaises(ScopeRejected):
      scope.write_control(0, 1)

  def test_write_dropped_during_a_burst_times_out(self):
    scope, _ = client([INFO_FRAME, b"\x01\x01\x01"]) # only sample bytes come back
    with self.assertRaises(ScopeTimeout):
      scope.write_control(0, 1)

  def test_out_of_range_is_refused_before_anything_is_sent(self):
    scope, port = client([INFO_FRAME])
    scope.get_info()
    for index, value in [(8, 0), (-1, 0), (0, 0x1_0000_0000), (0, -1)]:
      with self.assertRaises(ValueError):
        scope.write_control(index, value)
    with self.assertRaises(ValueError):
      scope.read_control(8)
    self.assertEqual(len(port.written), 1) # only GET_INFO

  def test_a_core_without_controls_is_not_sent_their_commands(self):
    scope, port = client([OLD_INFO_FRAME])
    self.assertEqual(scope.get_info().num_controls, 0)
    with self.assertRaises(ScopeError):
      scope.write_control(0, 1)
    with self.assertRaises(ScopeError):
      scope.read_control(0)
    self.assertEqual(scope.read_controls(), [])
    self.assertEqual(len(port.written), 1) # only GET_INFO


if __name__ == "__main__":
  unittest.main()
