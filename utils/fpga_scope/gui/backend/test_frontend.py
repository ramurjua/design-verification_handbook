"""Runs the frontend's own tests (../frontend/tests/) in a headless browser:
python -m unittest test_frontend

  unit.html  the display maths in scope_math.js
  e2e.html   the real page, driven against app.py and the simulated device

The pages POST their outcome back here. Needs Chrome, Chromium or Edge; the
tests are skipped if none is found (FPGA_SCOPE_BROWSER names another executable).
"""

import json
import os
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import uvicorn

import app as app_module

BROWSER_NAMES = ["chrome", "google-chrome", "chromium", "chromium-browser", "msedge"]
BROWSER_PATHS = [
  r"C:\Program Files\Google\Chrome\Application\chrome.exe",
  r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
  r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
  r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]


def find_browser():
  chosen = os.environ.get("FPGA_SCOPE_BROWSER")
  if chosen:
    return chosen
  for name in BROWSER_NAMES:
    if shutil.which(name):
      return shutil.which(name)
  return next((path for path in BROWSER_PATHS if Path(path).is_file()), None)


class ReportHandler(BaseHTTPRequestHandler):
  """Receives the one POST a test page makes when it has finished."""

  def do_POST(self):
    body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
    self.server.reports.put(json.loads(body))
    self.send_response(204)
    self.end_headers()

  def log_message(self, *args):
    pass


@unittest.skipUnless(find_browser(), "no Chrome, Chromium or Edge found")
class TestFrontend(unittest.TestCase):

  @classmethod
  def setUpClass(cls):
    cls.tmp = cls.enterClassContext(tempfile.TemporaryDirectory(ignore_cleanup_errors=True))
    # the page saves a configuration: keep it out of the real directory
    cls.enterClassContext(mock.patch.object(app_module, "CONFIG_DIR", Path(cls.tmp) / "configs"))

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    cls.base = f"http://127.0.0.1:{listener.getsockname()[1]}"
    cls.server = uvicorn.Server(uvicorn.Config(app_module.app, log_level="warning"))
    cls.server_thread = threading.Thread(target=cls.server.run, kwargs={"sockets": [listener]}, daemon=True)
    cls.server_thread.start()
    cls.addClassCleanup(cls.stop_server)

    cls.reports = ThreadingHTTPServer(("127.0.0.1", 0), ReportHandler)
    cls.reports.reports = queue.Queue()
    threading.Thread(target=cls.reports.serve_forever, daemon=True).start()
    cls.addClassCleanup(cls.reports.server_close)
    cls.addClassCleanup(cls.reports.shutdown)

  @classmethod
  def stop_server(cls):
    cls.server.should_exit = True
    cls.server_thread.join(timeout=10)

  def run_page(self, page, timeout):
    """Open a test page headless and return what it reported: {"passed", "failed", "failures"}."""
    profile = tempfile.mkdtemp(dir=self.tmp)
    url = f"{self.base}/tests/{page}?report=http://127.0.0.1:{self.reports.server_port}/"
    browser = subprocess.Popen(
      [find_browser(), "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
       f"--user-data-dir={profile}", "--window-size=1500,1100", url],
      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
      return self.reports.reports.get(timeout=timeout)
    except queue.Empty:
      self.fail(f"{page} did not report within {timeout} s")
    finally:
      browser.terminate()
      browser.wait(timeout=10)

  def assertPagePasses(self, report, at_least):
    failures = "\n".join(f"  {f['name']}: {f['error']}" for f in report["failures"])
    self.assertEqual(report["failed"], 0, f"\n{failures}")
    self.assertGreaterEqual(report["passed"], at_least) # a page that silently ran nothing is not a pass

  def test_scope_math(self):
    self.assertPagePasses(self.run_page("unit.html", 30), at_least=48)

  def test_gui_against_the_simulated_device(self):
    self.assertPagePasses(self.run_page("e2e.html", 90), at_least=27)


if __name__ == "__main__":
  unittest.main()
