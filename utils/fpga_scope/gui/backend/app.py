"""fpga_scope web backend: REST for commands, one WebSocket for everything pushed.

  python app.py            then open http://127.0.0.1:8000

  GET  /api/ports          serial ports, plus the simulated device
  GET  /api/state          {"state", "info"}
  POST /api/connect        {"port", "baudrate"} -> info
  POST /api/disconnect
  POST /api/capture        trigger config; arms and reports over the WebSocket
  POST /api/stream         {"decimation", "batch"}; streams batches over the WebSocket
  POST /api/stop           abort the capture / stop the stream
  GET  /api/configs        names of the saved GUI configurations
  GET/PUT/DELETE /api/configs/{name}   one configuration, a JSON file in CONFIG_DIR
  WS   /ws                 messages listed in session.py, preceded by one "hello"
"""

import argparse
import asyncio
import json
import os
import re
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from protocol import ScopeError
from session import NotConnected, ScopeSession, list_ports

FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"
# the GUI's saved configurations, one <name>.json each; their content is the frontend's business
CONFIG_DIR = Path(os.environ.get("FPGA_SCOPE_CONFIG_DIR") or Path(__file__).resolve().parent.parent / "configs")
CONFIG_NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")

sockets = set()
loop = None


async def broadcast(message):
  for ws in list(sockets):
    try:
      await ws.send_json(message)
    except Exception:
      sockets.discard(ws)


def publish(message):
  """Called from the session's worker threads."""
  if loop and not loop.is_closed():
    asyncio.run_coroutine_threadsafe(broadcast(message), loop)


session = ScopeSession(publish)


@asynccontextmanager
async def lifespan(app):
  global loop
  loop = asyncio.get_running_loop()
  yield
  session.disconnect()


app = FastAPI(title="fpga_scope", lifespan=lifespan)


class ConnectBody(BaseModel):
  port: str
  baudrate: int = Field(115200, gt=0)


class ChannelTriggerBody(BaseModel):
  enable: bool = False
  type: Literal["low", "high", "rise", "fall"] = "rise"
  bit_select: int = Field(0, ge=0, le=7)


class CaptureBody(BaseModel):
  channels: list[ChannelTriggerBody]
  combine: Literal["and", "or"] = "and"
  pre: int = Field(ge=0, le=0xFFFF)
  post: int = Field(ge=0, le=0xFFFF)
  decimation: int = Field(1, ge=1, le=0xFFFF)


class StreamBody(BaseModel):
  decimation: int = Field(1, ge=1, le=0xFFFF)
  batch: int = Field(200, ge=1, le=10000)


def call(fn, *args):
  """Run a session method, mapping its failures to HTTP errors."""
  try:
    return fn(*args)
  except NotConnected as e:
    raise HTTPException(409, str(e))
  except ValueError as e:
    raise HTTPException(400, str(e))
  except (ScopeError, OSError) as e:
    raise HTTPException(502, str(e))


# plain `def` handlers: FastAPI runs them in a thread pool, so the blocking serial I/O is fine

@app.get("/api/ports")
def get_ports():
  return list_ports()


@app.get("/api/state")
def get_state():
  return {"state": session.state, "info": session.info()}


@app.post("/api/connect")
def connect(body: ConnectBody):
  return call(session.connect, body.port, body.baudrate)


@app.post("/api/disconnect")
def disconnect():
  call(session.disconnect)
  return {}


@app.post("/api/capture")
def capture(body: CaptureBody):
  call(session.start_capture, [c.model_dump() for c in body.channels], body.combine == "or",
       body.pre, body.post, body.decimation)
  return {}


@app.post("/api/stream")
def stream(body: StreamBody):
  call(session.start_stream, body.decimation, body.batch)
  return {}


@app.post("/api/stop")
def stop():
  call(session.stop)
  return {}


def config_path(name):
  if not CONFIG_NAME.fullmatch(name): # also what keeps the path inside CONFIG_DIR
    raise HTTPException(400, "A configuration name is 1 to 64 letters, digits, '-' or '_'")
  return CONFIG_DIR / f"{name}.json"


@app.get("/api/configs")
def list_configs():
  return sorted(p.stem for p in CONFIG_DIR.glob("*.json") if CONFIG_NAME.fullmatch(p.stem))


@app.get("/api/configs/{name}")
def get_config(name: str):
  try:
    return json.loads(config_path(name).read_text(encoding="utf-8"))
  except FileNotFoundError:
    raise HTTPException(404, f"No saved configuration named '{name}'")
  except (OSError, ValueError) as e:
    raise HTTPException(500, f"Cannot read configuration '{name}': {e}")


@app.put("/api/configs/{name}")
def put_config(name: str, body: dict):
  path = config_path(name)
  try:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")
  except OSError as e:
    raise HTTPException(500, f"Cannot write {path}: {e}")
  return {}


@app.delete("/api/configs/{name}")
def delete_config(name: str):
  try:
    config_path(name).unlink()
  except FileNotFoundError:
    raise HTTPException(404, f"No saved configuration named '{name}'")
  except OSError as e:
    raise HTTPException(500, f"Cannot delete configuration '{name}': {e}")
  return {}


@app.websocket("/ws")
async def websocket(ws: WebSocket):
  await ws.accept()
  await ws.send_json({"type": "hello", "state": session.state, "info": session.info()})
  sockets.add(ws)
  try:
    while True:
      await ws.receive_text() # nothing is expected from the browser; this just notices the disconnect
  except WebSocketDisconnect:
    pass
  finally:
    sockets.discard(ws)


app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")


if __name__ == "__main__":
  import uvicorn
  parser = argparse.ArgumentParser(description="fpga_scope web backend")
  parser.add_argument("--host", default="127.0.0.1")
  parser.add_argument("--port", type=int, default=8000)
  parser.add_argument("--config-dir", type=Path, default=CONFIG_DIR, help="where the GUI's saved configurations are kept (default: %(default)s)")
  args = parser.parse_args()
  CONFIG_DIR = args.config_dir
  uvicorn.run(app, host=args.host, port=args.port)
