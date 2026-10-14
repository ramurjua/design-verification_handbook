"""Simulated scope_top core, so the backend and GUI can run without a board.

A SimDevice stands in for the serial port handed to protocol.ScopeClient: frames
written to it are answered the way scope_cmd_if.v answers them, with the reply
bytes released at UART speed. The channels carry synthetic signals (square
waves on 1-bit channels, a ramp or a sine on wider ones).

This is a behavioural stand-in for GUI development, NOT a reference model of
the RTL: a capture resolves in one go at CMD_ARM time and a stream burst cannot
be interrupted half-way, so a control write is never dropped the way the RTL
drops one during a burst. The controls are stored and read back, nothing more:
they do not act on the synthetic signals. Passing against it says nothing
about real hardware.
"""

import math
import time

from protocol import (
  CONTROLS_SINCE_VERSION, NUM_CONTROLS, SYNC_HOST, SYNC_DEV, STATUS_OK, Mode, Opcode, ScopeState, TriggerType,
  checksum, encode_frame,
)

STATUS_ERROR = 0x01
TRIGGER_SEARCH_CYCLES = 200_000 # how far ahead CMD_ARM looks for the trigger condition
CAPTURE_SECONDS = 0.4 # how long a capture stays ARMED before reporting DONE, so the GUI has something to show


class SimDevice:

  def __init__(self, channel_widths=(1, 1, 4, 8), buffer_depth_log2=10, clk_freq_hz=1_000_000,
               baudrate=115200, realtime=True, protocol_version=2):
    self.protocol_version = protocol_version # 1: a core from before the controls, which ignores their opcodes
    self.controls = [0] * NUM_CONTROLS
    self.channel_widths = tuple(channel_widths)
    self.buffer_depth_log2 = buffer_depth_log2
    self.clk_freq_hz = clk_freq_hz
    self.frame_bytes = (sum(self.channel_widths) + 7) // 8
    self.bytes_per_s = baudrate / 10 # 8N1
    self.realtime = realtime # False: replies are available immediately (unit tests)

    self._in = bytearray()
    self._out = bytearray()
    self._out_clock = 0.0 # when the byte at the head of _out started going out

    self.mode = Mode.SCOPE
    self.channel_cfg = bytes(8)
    self.combine_or = False
    self.pre = 0
    self.post = 0
    self.decimation = 1
    self._state = ScopeState.IDLE
    self._done_at = None # wall-clock time the armed capture completes, None = never triggers
    self._capture = []
    self._t = 0 # sample-clock cycle counter

  # Serial port interface

  def write(self, data):
    self._in += data
    while True:
      frame = self._next_frame()
      if frame is None: break
      self._handle(*frame)
    return len(data)

  def read(self, size):
    if self.realtime:
      released = int((time.monotonic() - self._out_clock) * self.bytes_per_s)
      size = min(size, released)
      if size <= 0 or not self._out:
        time.sleep(0.005) # a real port would block for its timeout here
        return b""
      self._out_clock += min(size, len(self._out)) / self.bytes_per_s
    out = bytes(self._out[:size])
    del self._out[:size]
    return out

  def reset_input_buffer(self):
    self._out.clear()

  def close(self):
    pass

  # Signals

  def _channel_value(self, channel, t):
    width = self.channel_widths[channel]
    mask = (1 << width) - 1
    if width == 1:
      return (t // (20 * (channel + 1))) & 1 # square wave, slower on each further channel
    if channel % 2 == 0:
      return (t // 8) & mask # ramp
    return round((math.sin(2 * math.pi * t / 200) + 1) / 2 * mask) # sine

  def _sample(self, t):
    word = 0
    offset = 0
    for channel, width in enumerate(self.channel_widths):
      word |= self._channel_value(channel, t) << offset
      offset += width
    return word

  def _trigger_at(self, t):
    """scope_trigger.v's condition, evaluated on cycle t."""
    conds = []
    for channel in range(len(self.channel_widths)):
      cfg = self.channel_cfg[channel]
      if not cfg & 0x80: continue
      bit = cfg & 0x0F
      now = (self._channel_value(channel, t) >> bit) & 1
      prev = (self._channel_value(channel, t - 1) >> bit) & 1
      kind = (cfg >> 4) & 0x03
      conds.append({
        TriggerType.LEVEL_LOW: not now,
        TriggerType.LEVEL_HIGH: bool(now),
        TriggerType.EDGE_RISE: bool(now and not prev),
        TriggerType.EDGE_FALL: bool(prev and not now),
      }[kind])
    if not conds: return False
    return any(conds) if self.combine_or else all(conds)

  # Commands

  def _next_frame(self):
    """Pop one well-formed host frame off the input, as (cmd, payload)."""
    rx = self._in
    while True:
      start = rx.find(SYNC_HOST)
      del rx[:start if start >= 0 else len(rx)]
      if len(rx) < 4: return None
      plen = int.from_bytes(rx[2:4], "big")
      if len(rx) < 4 + plen + 1: return None
      cmd, payload, chk = rx[1], bytes(rx[4:4 + plen]), rx[4 + plen]
      if checksum(cmd, payload) != chk:
        del rx[:1]
        continue
      del rx[:4 + plen + 1]
      return cmd, payload

  def _send(self, data):
    if not self._out:
      self._out_clock = time.monotonic()
    self._out += data

  def _reply(self, cmd, payload):
    self._send(encode_frame(cmd, payload, sync=SYNC_DEV))

  def _scope_state(self):
    if self._state == ScopeState.ARMED and self._done_at is not None and time.monotonic() >= self._done_at:
      self._state = ScopeState.DONE
    return self._state

  def _idle(self):
    return self.mode == Mode.STREAM or self._scope_state() == ScopeState.IDLE

  def _handle(self, cmd, payload):
    status = lambda accepted: self._reply(cmd, bytes([STATUS_OK if accepted else STATUS_ERROR]))

    if cmd == Opcode.GET_INFO:
      widths = self.channel_widths + (0,) * (8 - len(self.channel_widths))
      self._reply(cmd, bytes([self.protocol_version, 0x03, len(self.channel_widths), *widths, self.buffer_depth_log2, self.frame_bytes])
                  + self.clk_freq_hz.to_bytes(4, "big"))

    elif cmd == Opcode.SET_TRIGGER and len(payload) == 15:
      accepted = self._idle()
      if accepted:
        self.channel_cfg = payload[0:8]
        self.combine_or = bool(payload[8] & 1)
        self.pre = int.from_bytes(payload[9:11], "big")
        self.post = int.from_bytes(payload[11:13], "big")
        self.decimation = max(1, int.from_bytes(payload[13:15], "big"))
      status(accepted)

    elif cmd == Opcode.ARM:
      accepted = self.mode == Mode.SCOPE and self._scope_state() == ScopeState.IDLE
      if accepted: self._arm()
      status(accepted)

    elif cmd == Opcode.GET_STATUS:
      if self.mode == Mode.SCOPE:
        state = self._scope_state()
        fill = len(self._capture) if state == ScopeState.DONE else 0
      else:
        state, fill = 0, 0 # a burst is over by the time anything else can be asked
      self._reply(cmd, bytes([state]) + fill.to_bytes(2, "big"))

    elif cmd == Opcode.DUMP:
      if self.mode == Mode.SCOPE and self._scope_state() == ScopeState.DONE:
        self._reply(cmd, b"".join(s.to_bytes(self.frame_bytes, "big") for s in self._capture))
      # else: ignored without a response, like the RTL

    elif cmd == Opcode.ABORT:
      self._state = ScopeState.IDLE
      status(True)

    elif cmd == Opcode.SET_MODE and len(payload) == 1:
      accepted = self._idle()
      if accepted: self.mode = Mode(payload[0] & 1)
      status(accepted)

    elif cmd == Opcode.STREAM_START and len(payload) == 4:
      accepted = self.mode == Mode.STREAM
      status(accepted)
      if accepted:
        count = int.from_bytes(payload, "big")
        self._send(b"".join(self._sample(self._t + i * self.decimation).to_bytes(self.frame_bytes, "big")
                            for i in range(count)))
        self._t += count * self.decimation

    elif cmd == Opcode.CONTROL_WRITE and self.protocol_version >= CONTROLS_SINCE_VERSION:
      accepted = len(payload) == 5 and payload[0] < NUM_CONTROLS
      if accepted: self.controls[payload[0]] = int.from_bytes(payload[1:], "big")
      status(accepted)

    elif cmd == Opcode.CONTROL_READ and self.protocol_version >= CONTROLS_SINCE_VERSION:
      if len(payload) == 1 and payload[0] < NUM_CONTROLS:
        self._reply(cmd, payload + self.controls[payload[0]].to_bytes(4, "big"))
      # else: ignored without a response, like the RTL

  def _arm(self):
    depth = 1 << self.buffer_depth_log2
    pre = min(self.pre, depth)
    post = min(self.post, depth - pre)

    self._state = ScopeState.ARMED
    self._done_at = None
    start = self._t + pre * self.decimation # let the pre-trigger window fill first
    for t in range(start, start + TRIGGER_SEARCH_CYCLES):
      if self._trigger_at(t):
        self._capture = [self._sample(t + (i - pre) * self.decimation) for i in range(pre + post)]
        self._t = t + post * self.decimation
        self._done_at = time.monotonic() + (CAPTURE_SECONDS if self.realtime else 0)
        return
