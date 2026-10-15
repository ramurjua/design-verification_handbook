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
import time

from protocol import ChannelTrigger, Mode, ScopeClient, ScopeError, ScopeState, TriggerConfig, TriggerType
from sim_device import SimDevice

SIM_PORT = "sim"
SIM_OLD_PORT = "sim-v1" # the simulated device as a core built before the controls existed; not listed, for tests
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
    self._io = threading.Lock() # held for one exchange with the device, by the job or by a request handler
    self._urgent = threading.Event() # a request handler is waiting for _io: the job lets it in first
    self._last_state = None
    self.port = None
    self.state = "disconnected"

  # Public API (called from request handlers)

  def connect(self, port, baudrate, timeout=1.0):
    with self._lock:
      self._close()
      if port in (SIM_PORT, SIM_OLD_PORT):
        client = ScopeClient(SimDevice(protocol_version=1 if port == SIM_OLD_PORT else 2), timeout)
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
      "protocol_version": info.protocol_version,
      "num_controls": info.num_controls, # 0 for a core built before the controls existed
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
      if not info.capture_window_fits(pre, post):
        raise ValueError(f"pre + post must be between 1 and {info.max_capture_samples} samples"
                         f" (with post 0, pre at most {info.max_capture_samples - 1})")
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

  def read_controls(self):
    """The value of every control, read from the core. Empty if it has none."""
    with self._lock:
      client = self._require_client()
      return self._call(client.read_controls)

  def write_control(self, index, value):
    """Write one control and return the value the core then reports for it.
    Also works while a capture is armed or a stream is running: it then goes
    in between two of the job's own exchanges, so during a stream it waits
    for the burst in flight to finish."""
    with self._lock:
      client = self._require_client()
      count = client.info.num_controls
      if not count:
        raise ValueError(f"this core has no controls (protocol version {client.info.protocol_version}): "
                         "rebuild it with the current fpga_scope RTL")
      if not 0 <= index < count:
        raise ValueError(f"control {index} out of range 0-{count - 1}")

      def write_and_read_back():
        client.write_control(index, value)
        return client.read_control(index)
      return self._call(write_and_read_back)

  # Jobs (worker thread)

  def _capture_job(self, client, pre, decimation):
    while not self._stop.is_set():
      status = self._job_call(client.get_status)
      if status.state == ScopeState.DONE:
        channels = client.info.split_channels(self._job_call(client.dump))
        self._job_call(client.abort) # a finished capture stays in DONE until aborted
        self._publish({"type": "capture", "channels": channels, "pre": pre, "decimation": decimation})
        self._set_state("idle")
        return
      self._set_state(ScopeState(status.state).name.lower(), status.fill_count)
      self._stop.wait(POLL_SECONDS)

  def _stream_job(self, client, batch, decimation):
    while not self._stop.is_set():
      channels = client.info.split_channels(self._job_call(client.stream, batch))
      self._publish({"type": "stream", "channels": channels, "decimation": decimation})

  def _run_job(self, job, *args):
    try:
      job(*args)
    except (ScopeError, OSError) as e:
      self._publish({"type": "error", "message": str(e)})
      self._set_state("idle")

  # Internals

  def _job_call(self, fn, *args):
    """One exchange with the device on behalf of the running job."""
    while self._urgent.is_set(): # a lock alone would let a stream take it again at once, every time
      time.sleep(0.001)
    with self._io:
      return fn(*args)

  def _call(self, fn, *args):
    """One exchange from a request handler, in between two of the job's if one is running."""
    self._urgent.set()
    try:
      with self._io:
        return fn(*args)
    finally:
      self._urgent.clear()

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
