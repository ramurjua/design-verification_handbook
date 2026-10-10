"""One connection to a scope core plus the background job running on it.

Sits between app.py (HTTP/WebSocket) and protocol.py (wire protocol), and has
no web dependency of its own. Everything that happens asynchronously - state
changes, a finished capture, stream batches, errors - is reported through the
`publish` callback as a JSON-ready dict, called from a worker thread:

  {"type": "state",   "state": "idle" | "armed" | "capturing" | "streaming" | "disconnected", "fill_count": n}
  {"type": "capture", "channels": [[...], ...], "pre": n, "decimation": n}
  {"type": "stream",  "channels": [[...], ...], "decimation": n}
  {"type": "error",   "message": "..."}
"""

import threading

from protocol import ChannelTrigger, Mode, ScopeClient, ScopeError, ScopeState, TriggerConfig, TriggerType
from sim_device import SimDevice

SIM_PORT = "sim"
POLL_SECONDS = 0.1

TRIGGER_TYPES = {
  "low": TriggerType.LEVEL_LOW,
  "high": TriggerType.LEVEL_HIGH,
  "rise": TriggerType.EDGE_RISE,
  "fall": TriggerType.EDGE_FALL,
}


class NotConnected(Exception):
  pass


def list_ports():
  from serial.tools import list_ports as lp
  ports = [{"device": SIM_PORT, "description": "Simulated device (no hardware)"}]
  ports += [{"device": p.device, "description": p.description} for p in sorted(lp.comports())]
  return ports


class ScopeSession:

  def __init__(self, publish):
    self._publish = publish
    self._lock = threading.Lock() # serialises the public methods; the job thread owns the client in between
    self._client = None
    self._job = None
    self._stop = threading.Event()
    self._last_state = None
    self.port = None
    self.state = "disconnected"

  # Public API (called from request handlers)

  def connect(self, port, baudrate, timeout=1.0):
    with self._lock:
      self._close()
      if port == SIM_PORT:
        client = ScopeClient(SimDevice(), timeout)
      else:
        client = ScopeClient.open(port, baudrate, timeout)
      try:
        client.get_info()
        client.abort() # known starting point, whatever the core was doing before
      except ScopeError:
        client.close()
        raise
      self._client = client
      self.port = port
      self._set_state("idle")
      return self.info()

  def disconnect(self):
    with self._lock:
      self._close()

  def info(self):
    if not self._client: return None
    info = self._client.info
    return {
      "port": self.port,
      "num_channels": info.num_channels,
      "channel_widths": list(info.channel_widths[:info.num_channels]),
      "buffer_depth": info.buffer_depth,
      "max_capture_samples": info.max_capture_samples,
      "frame_bytes": info.frame_bytes,
      "clk_freq_hz": info.clk_freq_hz,
      "modes": [m.name.lower() for m in Mode if info.supports(m)],
    }

  def start_capture(self, channels, combine_or, pre, post, decimation):
    """channels: one {"enable", "type", "bit_select"} dict per channel, type a TRIGGER_TYPES key."""
    with self._lock:
      client = self._require_client()
      info = client.info
      if len(channels) > info.num_channels:
        raise ValueError(f"{len(channels)} channel triggers for a {info.num_channels}-channel core")
      if not any(c["enable"] for c in channels):
        raise ValueError("no trigger enabled: the capture would never complete")
      if pre + post < 1 or pre + post > info.max_capture_samples:
        raise ValueError(f"pre + post must be between 1 and {info.max_capture_samples} samples")
      config = TriggerConfig(
        [ChannelTrigger(c["enable"], TRIGGER_TYPES[c["type"]], c["bit_select"]) for c in channels],
        combine_or, pre, post, decimation)
      config.pack() # range checks, before touching the device

      self._stop_job()
      client.abort()
      client.set_mode(Mode.SCOPE)
      client.set_trigger(config)
      client.arm()
      self._set_state("armed")
      self._start_job(self._capture_job, client, pre, max(1, decimation))

  def start_stream(self, decimation, batch):
    with self._lock:
      client = self._require_client()
      config = TriggerConfig(decimation=decimation) # decimation lives in the trigger config
      config.pack()
      if batch < 1:
        raise ValueError("batch must be at least 1 sample")

      self._stop_job()
      client.abort()
      client.set_trigger(config)
      client.set_mode(Mode.STREAM)
      self._set_state("streaming")
      self._start_job(self._stream_job, client, batch, max(1, decimation))

  def stop(self):
    with self._lock:
      client = self._require_client()
      self._stop_job()
      client.abort()
      self._set_state("idle")

  # Jobs (worker thread)

  def _capture_job(self, client, pre, decimation):
    while not self._stop.is_set():
      status = client.get_status()
      if status.state == ScopeState.DONE:
        channels = client.info.split_channels(client.dump())
        client.abort() # a finished capture stays in DONE until aborted
        self._publish({"type": "capture", "channels": channels, "pre": pre, "decimation": decimation})
        self._set_state("idle")
        return
      self._set_state(ScopeState(status.state).name.lower(), status.fill_count)
      self._stop.wait(POLL_SECONDS)

  def _stream_job(self, client, batch, decimation):
    while not self._stop.is_set():
      channels = client.info.split_channels(client.stream(batch))
      self._publish({"type": "stream", "channels": channels, "decimation": decimation})

  def _run_job(self, job, *args):
    try:
      job(*args)
    except (ScopeError, OSError) as e:
      self._publish({"type": "error", "message": str(e)})
      self._set_state("idle")

  # Internals

  def _require_client(self):
    if not self._client:
      raise NotConnected("not connected to a scope")
    return self._client

  def _start_job(self, job, *args):
    self._job = threading.Thread(target=self._run_job, args=(job, *args), daemon=True)
    self._job.start()

  def _stop_job(self):
    if self._job:
      self._stop.set()
      self._job.join()
      self._job = None
      self._stop.clear()

  def _close(self):
    self._stop_job()
    if self._client:
      self._client.close()
      self._client = None
      self.port = None
    self._set_state("disconnected")

  def _set_state(self, state, fill_count=0):
    self.state = state
    if (state, fill_count) != self._last_state:
      self._last_state = (state, fill_count)
      self._publish({"type": "state", "state": state, "fill_count": fill_count})
