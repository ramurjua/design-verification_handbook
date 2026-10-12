/* Minimal test harness shared by unit.html and e2e.html: there is no build
   step and no Node here, so the tests are plain pages. Open one in a browser
   to read the results, or let ../../backend/test_frontend.py run it headless:
   with ?report=<url> in the address the outcome is also POSTed there. */

const Harness = (() => {
  const results = [];

  const record = (name, error) => results.push({ name, error: error === undefined ? null : String((error && error.message) || error) });

  function test(name, fn) {
    try { fn(); record(name); } catch (e) { record(name, e); }
  }

  async function step(name, fn) {
    try { await fn(); record(name); } catch (e) { record(name, e); }
  }

  function ok(condition, what) {
    if (!condition) throw new Error(what || "condition is false");
  }

  function eq(actual, expected, what = "value") {
    const a = JSON.stringify(actual), b = JSON.stringify(expected);
    if (a !== b) throw new Error(`${what}: expected ${b}, got ${a}`);
  }

  function near(actual, expected, what = "value", tolerance = 1e-9) {
    if (!(Math.abs(actual - expected) <= tolerance)) throw new Error(`${what}: expected ${expected}, got ${actual}`);
  }

  function throws(fn, pattern, what = "call") {
    try { fn(); } catch (e) {
      if (!pattern.test(e.message)) throw new Error(`${what}: threw "${e.message}", expected ${pattern}`);
      return;
    }
    throw new Error(`${what}: did not throw`);
  }

  /* poll until condition() is truthy; the page under test answers over a socket, not on a schedule */
  async function until(condition, what, timeout = 10000) {
    const deadline = performance.now() + timeout;
    for (;;) {
      const value = condition();
      if (value) return value;
      if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  function finish() {
    const failures = results.filter((r) => r.error !== null);
    const summary = { passed: results.length - failures.length, failed: failures.length, failures };
    document.title = failures.length ? `FAIL (${failures.length})` : `PASS (${summary.passed})`;
    const list = document.getElementById("results");
    document.getElementById("summary").textContent = `${summary.passed} passed, ${summary.failed} failed`;
    for (const r of results) {
      const item = document.createElement("li");
      item.className = r.error === null ? "pass" : "fail";
      item.textContent = r.error === null ? r.name : `${r.name}: ${r.error}`;
      list.append(item);
    }
    const report = new URLSearchParams(location.search).get("report");
    if (report) fetch(report, { method: "POST", mode: "no-cors", body: JSON.stringify(summary) });
    return summary;
  }

  return { test, step, ok, eq, near, throws, until, finish };
})();
