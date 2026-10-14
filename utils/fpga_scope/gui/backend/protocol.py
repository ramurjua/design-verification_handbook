"""Host side of the fpga_scope UART protocol.

Independent implementation of ../../docs/protocol.md (the RTL counterpart is
../../source/scope_cmd_if.v). If the wire format changes, change that document,
the RTL and this file together.

Usage:

  scope = ScopeClient.open("COM5", 115200)
  info = scope.get_info()
  scope.set_trigger(TriggerConfig(
    channels=[ChannelTrigger(True, TriggerType.EDGE_RISE)],
    pre_trigger_count=100, post_trigger_count=100))
  scope.arm()
  while scope.get_status().state != ScopeState.DONE:
    time.sleep(0.05)
  channels = info.split_channels(scope.dump())
  scope.abort() # a finished capture stays in DONE until aborted
"""

import time
from dataclasses import dataclass, field
from enum import IntEnum

SYNC_HOST = 0xAA # host -> device
SYNC_DEV = 0x55 # device -> host

STATUS_OK = 0x00

MAX_CHANNELS = 8
MAX_PAYLOAD_LEN = 0xFFFF # LEN is a 16-bit field

GET_INFO_LEN = 17
GET_STATUS_LEN = 3
CONTROL_READ_LEN = 5

NUM_CONTROLS = 8 # 32-bit registers the host writes; every core has all of them...
CONTROLS_SINCE_VERSION = 2 # ...from this protocol_version on


class Opcode(IntEnum):
  GET_INFO = 0x01
  SET_TRIGGER = 0x02
  ARM = 0x03
  GET_STATUS = 0x04
  DUMP = 0x05
  ABORT = 0x06
  SET_MODE = 0x07
  STREAM_START = 0x08
  CONTROL_WRITE = 0x09
  CONTROL_READ = 0x0A


class Mode(IntEnum):
  SCOPE = 0
  STREAM = 1


class TriggerType(IntEnum):
  LEVEL_LOW = 0
  LEVEL_HIGH = 1
  EDGE_RISE = 2
  EDGE_FALL = 3


class ScopeState(IntEnum):
  """GET_STATUS state byte while in Mode.SCOPE."""
  IDLE = 0
  ARMED = 1
  CAPTURING = 2
  DONE = 3


class StreamState(IntEnum):
  """GET_STATUS state byte while in Mode.STREAM."""
  IDLE = 0
  RUNNING = 1


class ScopeError(Exception):
  pass


class ScopeTimeout(ScopeError):
  """No valid response frame arrived. Also what an ignored command looks like
  (e.g. CMD_DUMP while the capture is not done)."""


class ScopeRejected(ScopeError):
  """The device answered with a non-OK status byte."""

  def __init__(self, opcode, status):
    super().__init__(f"{Opcode(opcode).name} rejected by device (status 0x{status:02X})")
    self.opcode = opcode
    self.status = status


# Frames
########

def checksum(cmd, payload):
  """XOR of CMD, LEN_H, LEN_L and every payload byte."""
  chk = cmd ^ (len(payload) >> 8) ^ (len(payload) & 0xFF)
  for b in payload:
    chk ^= b
  return chk


def encode_frame(cmd, payload=b"", sync=SYNC_HOST):
  if len(payload) > MAX_PAYLOAD_LEN:
    raise ValueError(f"payload of {len(payload)} bytes does not fit the 16-bit LEN field")
  return bytes([sync, cmd]) + len(payload).to_bytes(2, "big") + bytes(payload) + bytes([checksum(cmd, payload)])


# Payloads
##########

@dataclass(frozen=True)
class ScopeInfo:
  protocol_version: int
  modes_supported: int # bitmask, bit0 = Mode.SCOPE, bit1 = Mode.STREAM
  num_channels: int
  channel_widths: tuple # 8 entries, bits per channel lane, 0 = lane unused
  buffer_depth_log2: int
  frame_bytes: int # bytes per sample on the wire
  clk_freq_hz: int

  @classmethod
  def unpack(cls, payload):
    if len(payload) != GET_INFO_LEN:
      raise ScopeError(f"GET_INFO payload is {len(payload)} bytes, expected {GET_INFO_LEN}")
    return cls(
      protocol_version=payload[0],
      modes_supported=payload[1],
      num_channels=payload[2],
      channel_widths=tuple(payload[3:11]),
      buffer_depth_log2=payload[11],
      frame_bytes=payload[12],
      clk_freq_hz=int.from_bytes(payload[13:17], "big"),
    )

  @property
  def buffer_depth(self):
    return 1 << self.buffer_depth_log2

  @property
  def max_capture_samples(self):
    """Largest pre+post window: bounded by the buffer and by a dump having to fit LEN."""
    return min(self.buffer_depth, MAX_PAYLOAD_LEN // self.frame_bytes)

  def supports(self, mode):
    return bool(self.modes_supported & (1 << mode))

  @property
  def num_controls(self):
    """Controls this core has: all 8, or none if it was built before they existed."""
    return NUM_CONTROLS if self.protocol_version >= CONTROLS_SINCE_VERSION else 0

  def unpack_samples(self, data):
    """Raw CMD_DUMP / stream bytes -> one integer per sample (MSB of the sample first)."""
    n = self.frame_bytes
    if len(data) % n:
      raise ScopeError(f"{len(data)} sample bytes is not a multiple of frame_bytes={n}")
    return [int.from_bytes(data[i:i + n], "big") for i in range(0, len(data), n)]

  def split_channels(self, samples):
    """Sample words -> one list of values per configured channel (channel 0 is the LSB end)."""
    channels = []
    offset = 0
    for width in self.channel_widths[:self.num_channels]:
      mask = (1 << width) - 1
      channels.append([(s >> offset) & mask for s in samples])
      offset += width
    return channels


@dataclass(frozen=True)
class ChannelTrigger:
  enable: bool = False
  type: TriggerType = TriggerType.LEVEL_LOW
  bit_select: int = 0 # which bit of the channel is the trigger source, 0 = LSB

  def pack(self):
    if not 0 <= self.bit_select <= 15:
      raise ValueError(f"bit_select {self.bit_select} out of range 0-15")
    return (int(bool(self.enable)) << 7) | (TriggerType(self.type) << 4) | self.bit_select


@dataclass(frozen=True)
class TriggerConfig:
  channels: list = field(default_factory=list) # ChannelTrigger for channel 0, 1, ...; missing ones are disabled
  combine_or: bool = False # False = AND all enabled channel conditions, True = OR them
  pre_trigger_count: int = 0
  post_trigger_count: int = 0
  decimation: int = 1 # sample every N clock cycles

  def pack(self):
    if len(self.channels) > MAX_CHANNELS:
      raise ValueError(f"{len(self.channels)} channel triggers, at most {MAX_CHANNELS}")
    for name in ("pre_trigger_count", "post_trigger_count", "decimation"):
      if not 0 <= getattr(self, name) <= 0xFFFF:
        raise ValueError(f"{name} {getattr(self, name)} out of range 0-65535")

    cfg = [c.pack() for c in self.channels] + [0] * (MAX_CHANNELS - len(self.channels))
    return (bytes(cfg) + bytes([int(bool(self.combine_or))])
            + self.pre_trigger_count.to_bytes(2, "big")
            + self.post_trigger_count.to_bytes(2, "big")
            + self.decimation.to_bytes(2, "big"))


@dataclass(frozen=True)
class Status:
  state: int # ScopeState in Mode.SCOPE, StreamState in Mode.STREAM
  fill_count: int # Mode.SCOPE: samples written since arming. Mode.STREAM: samples left in the burst (low 16 bits)

  @classmethod
  def unpack(cls, payload):
    if len(payload) != GET_STATUS_LEN:
      raise ScopeError(f"GET_STATUS payload is {len(payload)} bytes, expected {GET_STATUS_LEN}")
    return cls(state=payload[0], fill_count=int.from_bytes(payload[1:3], "big"))


# Client
########

class ScopeClient:
  """Talks to one scope_top core.

  `port` is anything with pyserial's write(data) / read(size) (returning
  whatever arrived, possibly nothing) and, optionally, reset_input_buffer()
  and close(). `timeout` is how long the link may stay silent, in seconds,
  before a response is given up on - it restarts whenever bytes arrive, so it
  does not need scaling for long dumps.
  """

  def __init__(self, port, timeout=1.0):
    self._port = port
    self._rx = bytearray()
    self.timeout = timeout
    self.info = None # filled by get_info()

  @classmethod
  def open(cls, port_name, baudrate, timeout=1.0):
    import serial
    return cls(serial.Serial(port_name, baudrate, timeout=0.05), timeout)

  def close(self):
    close = getattr(self._port, "close", None)
    if close: close()

  # Commands

  def get_info(self):
    self.info = ScopeInfo.unpack(self._command(Opcode.GET_INFO, length=GET_INFO_LEN))
    return self.info

  def set_trigger(self, config):
    """Only accepted while idle. Its decimation also sets the stream-mode sample rate."""
    self._status_command(Opcode.SET_TRIGGER, config.pack())

  def arm(self):
    """Only accepted in Mode.SCOPE while idle."""
    self._status_command(Opcode.ARM)

  def get_status(self):
    return Status.unpack(self._command(Opcode.GET_STATUS, length=GET_STATUS_LEN))

  def dump(self):
    """Captured window as sample words, oldest first. Only answered once the
    capture is DONE (poll get_status() first); otherwise raises ScopeTimeout.
    The core stays in DONE afterwards, abort() returns it to idle."""
    return self._info().unpack_samples(self._command(Opcode.DUMP))

  def abort(self):
    """Back to idle from any state. Also cuts short a dump or stream burst
    still in flight, whose leftover bytes are skipped while looking for the reply."""
    self._status_command(Opcode.ABORT)

  def set_mode(self, mode):
    """Only accepted while idle."""
    self._status_command(Opcode.SET_MODE, bytes([Mode(mode)]))

  def stream(self, sample_count):
    """One burst of `sample_count` sample words. Only accepted in Mode.STREAM
    while idle. For a continuous view call it again for the next batch."""
    if not 0 <= sample_count <= 0xFFFFFFFF:
      raise ValueError(f"sample_count {sample_count} out of range")
    info = self._info()
    self._status_command(Opcode.STREAM_START, sample_count.to_bytes(4, "big"))

    # raw sample words follow the status frame, no envelope
    nbytes = sample_count * info.frame_bytes
    if not self._wait_for(nbytes):
      raise ScopeTimeout(f"stream burst stalled after {len(self._rx)} of {nbytes} bytes")
    data = bytes(self._rx[:nbytes])
    del self._rx[:nbytes]
    return info.unpack_samples(data)

  def write_control(self, index, value):
    """Set control `index` (0-7) to a 32-bit value. The core's o_controlN
    output takes it in one clock and o_control_update[N] pulses, also when the
    value is the one it already had. Accepted in any mode and capture state,
    but not while a dump or stream burst is in flight: then it is dropped and
    this raises ScopeTimeout."""
    self._check_control(index)
    if not 0 <= value <= 0xFFFFFFFF:
      raise ValueError(f"control value {value} does not fit 32 bits")
    self._status_command(Opcode.CONTROL_WRITE, bytes([index]) + value.to_bytes(4, "big"))

  def read_control(self, index):
    """The value control `index` holds now."""
    self._check_control(index)
    payload = self._command(Opcode.CONTROL_READ, bytes([index]), length=CONTROL_READ_LEN)
    if payload[0] != index:
      raise ScopeError(f"asked for control {index}, the device answered for control {payload[0]}")
    return int.from_bytes(payload[1:], "big")

  def read_controls(self):
    """Every control's value, in order. Empty for a core without controls."""
    return [self.read_control(i) for i in range(self._info().num_controls)]

  # Transport

  def _info(self):
    return self.info or self.get_info()

  def _check_control(self, index):
    if not 0 <= index < NUM_CONTROLS:
      raise ValueError(f"control {index} out of range 0-{NUM_CONTROLS - 1}")
    if not self._info().num_controls:
      raise ScopeError(f"this core has no controls (protocol version {self.info.protocol_version}): "
                       "it was built from RTL older than the controls")

  def _status_command(self, opcode, payload=b""):
    status = self._command(opcode, payload, length=1)[0]
    if status != STATUS_OK:
      raise ScopeRejected(opcode, status)

  def _command(self, opcode, payload=b"", length=None):
    """Send one frame and return the payload of the device's reply to it."""
    self._rx.clear()
    reset = getattr(self._port, "reset_input_buffer", None)
    if reset: reset()
    self._port.write(encode_frame(opcode, payload))
    return self._read_frame(opcode, length)

  def _wait_for(self, n):
    """Buffer at least n received bytes. False if the link went silent first."""
    deadline = time.monotonic() + self.timeout
    while len(self._rx) < n:
      chunk = self._port.read(n - len(self._rx))
      if chunk:
        self._rx += chunk
        deadline = time.monotonic() + self.timeout
      elif time.monotonic() >= deadline:
        return False
    return True

  def _read_frame(self, opcode, length=None):
    """Scan for a well-formed device frame echoing `opcode` (and, when given,
    carrying exactly `length` payload bytes). Anything else is skipped: a bad
    checksum or an unexpected header just means that 0x55 was not a real SYNC."""
    rx = self._rx
    while True:
      start = rx.find(SYNC_DEV)
      del rx[:start if start >= 0 else len(rx)]

      if not self._wait_for(4):
        raise ScopeTimeout(f"no response to {Opcode(opcode).name}")
      if not rx or rx[0] != SYNC_DEV:
        continue

      plen = int.from_bytes(rx[2:4], "big")
      if rx[1] != opcode or (length is not None and plen != length):
        del rx[:1]
        continue

      if not self._wait_for(4 + plen + 1):
        raise ScopeTimeout(f"truncated response to {Opcode(opcode).name}")

      payload = bytes(rx[4:4 + plen])
      if checksum(opcode, payload) != rx[4 + plen]:
        del rx[:1]
        continue

      del rx[:4 + plen + 1]
      return payload
