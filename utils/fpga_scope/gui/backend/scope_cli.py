"""Command-line front end for protocol.py, for bring-up and quick checks.

  python scope_cli.py --port COM5 --baud 115200 info
  python scope_cli.py --port COM5 --baud 115200 capture --trig 0:rise --pre 100 --post 100
  python scope_cli.py --port COM5 --baud 115200 stream 200 --decim 1000
  python scope_cli.py --port COM5 --baud 115200 control 0 1        write control 0
  python scope_cli.py --port COM5 --baud 115200 controls           read all 8

`capture` and `stream` are complete sequences that start by aborting whatever
the core was doing; the remaining commands each send exactly one frame.
"""

import argparse
import sys
import time

from protocol import (
  ChannelTrigger, Mode, ScopeClient, ScopeError, ScopeState, StreamState, TriggerConfig, TriggerType,
)

TRIGGER_TYPES = {
  "low": TriggerType.LEVEL_LOW,
  "high": TriggerType.LEVEL_HIGH,
  "rise": TriggerType.EDGE_RISE,
  "fall": TriggerType.EDGE_FALL,
}


def parse_trig(text):
  """CH:TYPE[:BIT], e.g. 0:rise or 2:high:3"""
  parts = text.split(":")
  try:
    if len(parts) not in (2, 3): raise ValueError
    channel = int(parts[0])
    bit = int(parts[2]) if len(parts) == 3 else 0
    if not (0 <= channel <= 7 and 0 <= bit <= 15): raise ValueError
    return channel, ChannelTrigger(True, TRIGGER_TYPES[parts[1]], bit)
  except (ValueError, KeyError):
    raise argparse.ArgumentTypeError(f"'{text}' is not CH:TYPE[:BIT] with TYPE one of {', '.join(TRIGGER_TYPES)}")


def trigger_config(args):
  channels = [ChannelTrigger()] * 8
  for channel, trig in args.trig:
    channels[channel] = trig
  return TriggerConfig(channels, args.any, args.pre, args.post, args.decim)


def print_info(info):
  widths = ", ".join(f"ch{i}={w}b" for i, w in enumerate(info.channel_widths[:info.num_channels]))
  print(f"protocol version : {info.protocol_version}")
  print(f"modes            : {', '.join(m.name for m in Mode if info.supports(m))}")
  print(f"channels         : {info.num_channels} ({widths})")
  print(f"buffer depth     : {info.buffer_depth} samples (largest capture window {info.max_capture_samples})")
  print(f"frame bytes      : {info.frame_bytes}")
  print(f"clock            : {info.clk_freq_hz} Hz")
  print(f"controls         : {info.num_controls or 'none (core built before they existed)'}")


def print_samples(info, samples, csv_path):
  channels = info.split_channels(samples)
  print(f"{len(samples)} samples")
  for i, values in enumerate(channels):
    print(f"ch{i}: " + " ".join(str(v) for v in values))
  if csv_path:
    with open(csv_path, "w") as f:
      f.write(",".join(f"ch{i}" for i in range(len(channels))) + "\n")
      for row in zip(*channels):
        f.write(",".join(str(v) for v in row) + "\n")
    print(f"saved to {csv_path}")


def run_capture(scope, args):
  info = scope.get_info()
  if not info.capture_window_fits(args.pre, args.post):
    print(f"pre + post must be between 1 and {info.max_capture_samples} samples"
          f" (with post 0, pre at most {info.max_capture_samples - 1})", file=sys.stderr)
    return 1
  scope.abort()
  scope.set_mode(Mode.SCOPE)
  scope.set_trigger(trigger_config(args))
  scope.arm()
  print("armed, waiting for trigger...")

  deadline = time.monotonic() + args.wait
  while scope.get_status().state != ScopeState.DONE:
    if time.monotonic() >= deadline:
      status = scope.get_status()
      scope.abort()
      print(f"no complete capture after {args.wait} s (state {ScopeState(status.state).name}, "
            f"{status.fill_count} samples written), aborted")
      return 1
    time.sleep(0.05)

  print_samples(info, scope.dump(), args.csv)
  scope.abort()
  return 0


def run_stream(scope, args):
  info = scope.get_info()
  scope.abort()
  if args.decim is not None:
    scope.set_trigger(TriggerConfig(decimation=args.decim)) # decimation lives in the trigger config
  scope.set_mode(Mode.STREAM)
  print_samples(info, scope.stream(args.count), args.csv)
  return 0


def run(scope, args):
  if args.command == "info":
    print_info(scope.get_info())
  elif args.command == "status":
    status = scope.get_status()
    # the state byte is mode-dependent and the mode cannot be read back, so show both readings
    stream_state = StreamState(status.state).name if status.state <= 1 else "-"
    print(f"state {status.state} (scope mode: {ScopeState(status.state).name}, stream mode: {stream_state}), "
          f"count {status.fill_count}")
  elif args.command == "trigger":
    scope.set_trigger(trigger_config(args))
  elif args.command == "arm":
    scope.arm()
  elif args.command == "dump":
    print_samples(scope.get_info(), scope.dump(), args.csv)
  elif args.command == "abort":
    scope.abort()
  elif args.command == "mode":
    scope.set_mode(Mode[args.mode.upper()])
  elif args.command == "control":
    scope.write_control(args.index, args.value)
    print(f"control {args.index} = {scope.read_control(args.index)}")
  elif args.command == "controls":
    values = scope.read_controls()
    if not values:
      print("this core has no controls")
    for i, value in enumerate(values):
      print(f"control {i} = {value} (0x{value:08X})")
  elif args.command == "capture":
    return run_capture(scope, args)
  elif args.command == "stream":
    return run_stream(scope, args)
  if args.command in ("trigger", "arm", "abort", "mode"):
    print("OK")
  return 0


def build_parser():
  parser = argparse.ArgumentParser(description="fpga_scope command-line client")
  parser.add_argument("--port", required=True, help="serial port, e.g. COM5")
  parser.add_argument("--baud", required=True, type=int, help="baud rate the core was built for")
  parser.add_argument("--timeout", type=float, default=1.0, help="seconds of silence before giving up on a response")
  sub = parser.add_subparsers(dest="command", required=True)

  def add_trigger_args(p):
    p.add_argument("--trig", action="append", default=[], type=parse_trig, metavar="CH:TYPE[:BIT]",
                   help="trigger condition on one channel, TYPE = low|high|rise|fall; repeatable")
    p.add_argument("--any", action="store_true", help="OR the channel conditions instead of AND")
    p.add_argument("--pre", type=int, default=0, help="samples kept before the trigger")
    p.add_argument("--post", type=int, default=0, help="samples captured from the trigger on")
    p.add_argument("--decim", type=int, default=1, help="sample every N clock cycles")

  sub.add_parser("info", help="CMD_GET_INFO")
  sub.add_parser("status", help="CMD_GET_STATUS")
  add_trigger_args(sub.add_parser("trigger", help="CMD_SET_TRIGGER"))
  sub.add_parser("arm", help="CMD_ARM")
  sub.add_parser("dump", help="CMD_DUMP").add_argument("--csv", help="also save the samples to this file")
  sub.add_parser("abort", help="CMD_ABORT")
  sub.add_parser("mode", help="CMD_SET_MODE").add_argument("mode", choices=["scope", "stream"])

  control = sub.add_parser("control", help="CMD_CONTROL_WRITE, then read it back")
  control.add_argument("index", type=int, help="control number, 0-7")
  control.add_argument("value", type=lambda text: int(text, 0), help="raw 32-bit value, decimal or 0x...")
  sub.add_parser("controls", help="CMD_CONTROL_READ of every control")

  capture = sub.add_parser("capture", help="abort, set trigger, arm, wait for the trigger, dump, abort")
  add_trigger_args(capture)
  capture.add_argument("--wait", type=float, default=10.0, help="seconds to wait for the capture to finish")
  capture.add_argument("--csv", help="also save the samples to this file")

  stream = sub.add_parser("stream", help="abort, switch to stream mode, read one burst")
  stream.add_argument("count", type=int, help="number of samples")
  stream.add_argument("--decim", type=int, help="sample every N clock cycles (overwrites the trigger config)")
  stream.add_argument("--csv", help="also save the samples to this file")
  return parser


def main(argv=None, scope=None):
  args = build_parser().parse_args(argv)
  try:
    scope = scope or ScopeClient.open(args.port, args.baud, args.timeout)
    try:
      return run(scope, args)
    finally:
      scope.close()
  except (ScopeError, ValueError, OSError) as e:
    print(f"[ERROR] {e}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  sys.exit(main())
