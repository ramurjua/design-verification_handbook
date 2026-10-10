/* fpga_scope frontend. Commands go to the backend over REST (/api/...), and
   everything the backend reports asynchronously arrives on one WebSocket (/ws).
   See ../backend/app.py and ../backend/session.py for both interfaces. */

const $ = (id) => document.getElementById(id);

const TRIGGER_OPTIONS = [["off", "Off"], ["rise", "Rising edge"], ["fall", "Falling edge"], ["high", "High level"], ["low", "Low level"]];
const STATE_LABELS = { disconnected: "Disconnected", idle: "Idle", armed: "Armed, waiting for trigger", capturing: "Capturing", streaming: "Streaming" };

const app = {
  info: null, // what CMD_GET_INFO reported, null while disconnected
  state: "disconnected",
  fillCount: 0,
  tab: "scope",
  capture: null, // { channels, pre, decimation }
  stream: null, // { channels, decimation }
  hover: null, // sample index under the crosshair
  online: false, // WebSocket to the backend is up
};

/* ---- backend ---- */

async function api(method, path, body) {
  const response = await fetch(path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    let message = response.statusText;
    try {
      const detail = (await response.json()).detail;
      message = typeof detail === "string" ? detail : detail.map((d) => `${d.loc.slice(1).join(".")}: ${d.msg}`).join("; ");
    } catch { /* not JSON, keep the status text */ }
    throw new Error(message);
  }
  return response.json();
}

/* run a command, routing any failure to the error banner */
async function command(fn) {
  try {
    showError(null);
    return await fn();
  } catch (e) {
    showError(e.message);
  }
}

function openSocket() {
  const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  ws.onopen = () => { app.online = true; };
  ws.onmessage = (event) => onMessage(JSON.parse(event.data));
  ws.onclose = () => {
    app.online = false;
    setInfo(null);
    setState("disconnected");
    setTimeout(openSocket, 1000);
  };
}

function onMessage(msg) {
  if (msg.type === "hello") {
    setInfo(msg.info);
    setState(msg.state, 0);
  } else if (msg.type === "state") {
    setState(msg.state, msg.fill_count);
  } else if (msg.type === "capture") {
    app.capture = msg;
    app.hover = null;
    draw();
  } else if (msg.type === "stream") {
    appendStream(msg);
  } else if (msg.type === "error") {
    showError(msg.message);
  }
}

function appendStream(msg) {
  const keep = clampInt($("s-window"), 2000);
  if (!app.stream) app.stream = { channels: msg.channels.map(() => []), decimation: msg.decimation };
  app.stream.decimation = msg.decimation;
  app.stream.channels = app.stream.channels.map((old, c) => old.concat(msg.channels[c]).slice(-keep));
  scheduleDraw();
}

/* ---- UI state ---- */

function showError(message) {
  $("error").hidden = !message;
  $("error-text").textContent = message || "";
}

function setInfo(info) {
  app.info = info;
  if (!info) {
    $("info").textContent = app.online ? "Not connected." : "Backend not reachable. Is app.py running?";
  } else {
    $("info").textContent = `${info.port}: ${info.num_channels} channels, ${info.buffer_depth}-sample buffer `
      + `(captures up to ${info.max_capture_samples} samples), ${formatHz(info.clk_freq_hz)} sample clock`;
    buildTriggerRows(info);
    $("pre").max = $("post").max = info.max_capture_samples;
  }
  updateControls();
}

function setState(state, fillCount = 0) {
  app.state = state;
  app.fillCount = fillCount;
  if (state === "disconnected") app.info = null;
  updateControls();
}

function updateControls() {
  const connected = !!app.info;
  const idle = connected && app.state === "idle";
  const busy = ["armed", "capturing", "streaming"].includes(app.state);

  let label = STATE_LABELS[app.state] || app.state;
  if (app.state === "capturing") label += ` (${app.fillCount} samples)`;
  $("state-label").textContent = label;
  $("status").className = (connected ? "connected" : "") + (busy ? " busy" : "");

  $("connect").textContent = connected ? "Disconnect" : "Connect";
  $("connect").disabled = !app.online;
  $("port").disabled = $("baud").disabled = $("refresh").disabled = connected;
  $("arm").disabled = !idle;
  $("abort").disabled = !(app.state === "armed" || app.state === "capturing");
  $("s-start").disabled = !idle;
  $("s-stop").disabled = app.state !== "streaming";
  updateScopeHint();
}

function buildTriggerRows(info) {
  const box = $("triggers");
  if (box.dataset.widths === info.channel_widths.join(",")) return; // same core as before, keep the user's choices
  box.dataset.widths = info.channel_widths.join(",");
  box.replaceChildren();

  info.channel_widths.forEach((width, c) => {
    const name = document.createElement("span");
    name.className = "ch-name";
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = `var(--series-${c + 1})`;
    const small = document.createElement("small");
    small.textContent = width === 1 ? "1 bit" : `${width} bits`;
    name.append(swatch, `ch${c}`, small);

    const type = document.createElement("select");
    type.id = `trig-type-${c}`;
    type.setAttribute("aria-label", `ch${c} trigger`);
    for (const [value, text] of TRIGGER_OPTIONS) type.add(new Option(text, value));
    type.value = c === 0 ? "rise" : "off";

    const bit = document.createElement("select");
    bit.id = `trig-bit-${c}`;
    bit.setAttribute("aria-label", `ch${c} trigger bit`);
    for (let b = 0; b < width; b++) bit.add(new Option(`bit ${b}`, b));
    bit.style.visibility = width === 1 ? "hidden" : "visible";

    box.append(name, type, bit);
  });
}

function updateScopeHint() {
  if (!app.info) { $("scope-hint").textContent = ""; return; }
  const decim = clampInt($("decim"), 1);
  const total = clampInt($("pre"), 0) + clampInt($("post"), 0);
  const period = decim / app.info.clk_freq_hz;
  $("scope-hint").textContent = `Sample rate ${formatHz(1 / period)}, window ${total} samples = ${formatSeconds(total * period)}`;
}

function clampInt(input, fallback) {
  const value = parseInt(input.value, 10);
  return Number.isFinite(value) ? value : fallback;
}

/* ---- actions ---- */

async function refreshPorts() {
  const ports = await command(() => api("GET", "/api/ports"));
  if (!ports) return;
  const previous = $("port").value;
  $("port").replaceChildren();
  for (const p of ports) {
    const label = p.description && p.description !== p.device ? `${p.device} - ${p.description}` : p.device;
    $("port").add(new Option(label, p.device));
  }
  if ([...$("port").options].some((o) => o.value === previous)) $("port").value = previous;
}

async function toggleConnection(event) {
  event.preventDefault();
  if (app.info) {
    await command(() => api("POST", "/api/disconnect"));
    setInfo(null);
  } else {
    const info = await command(() => api("POST", "/api/connect", { port: $("port").value, baudrate: clampInt($("baud"), 115200) }));
    if (info) setInfo(info);
  }
}

function arm() {
  const channels = app.info.channel_widths.map((_, c) => {
    const type = $(`trig-type-${c}`).value;
    return { enable: type !== "off", type: type === "off" ? "rise" : type, bit_select: parseInt($(`trig-bit-${c}`).value, 10) };
  });
  return command(() => api("POST", "/api/capture", {
    channels,
    combine: $("combine").value,
    pre: clampInt($("pre"), 0),
    post: clampInt($("post"), 0),
    decimation: clampInt($("decim"), 1),
  }));
}

function startStream() {
  app.stream = null;
  app.hover = null;
  draw();
  return command(() => api("POST", "/api/stream", { decimation: clampInt($("s-decim"), 1), batch: clampInt($("s-batch"), 200) }));
}

const stop = () => command(() => api("POST", "/api/stop"));

async function selectTab(tab) {
  if (tab === app.tab) return;
  // the core runs one mode at a time: leaving a tab stops whatever it had running
  if (["armed", "capturing", "streaming"].includes(app.state)) await stop();
  app.tab = tab;
  app.hover = null;
  for (const name of ["scope", "stream"]) {
    $(`tab-${name}`).setAttribute("aria-selected", String(name === tab));
    $(`panel-${name}`).hidden = name !== tab;
  }
  draw();
}

function downloadCsv() {
  const data = currentData();
  if (!data) return;
  const isCapture = app.tab === "scope";
  const period = data.decimation / app.info.clk_freq_hz;
  const names = data.channels.map((_, c) => `ch${c}`);
  const lines = [(isCapture ? ["sample", "time_s"] : ["sample"]).concat(names).join(",")];
  for (let i = 0; i < data.channels[0].length; i++) {
    const head = isCapture ? [i - data.pre, ((i - data.pre) * period).toExponential(6)] : [i];
    lines.push(head.concat(data.channels.map((ch) => ch[i])).join(","));
  }
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([lines.join("\n") + "\n"], { type: "text/csv" }));
  link.download = isCapture ? "fpga_scope_capture.csv" : "fpga_scope_stream.csv";
  link.click();
  URL.revokeObjectURL(link.href);
}

/* ---- formatting ---- */

function trim(value) { return String(Number(value.toPrecision(4))); }

function formatHz(hz) {
  if (hz >= 1e6) return `${trim(hz / 1e6)} MHz`;
  if (hz >= 1e3) return `${trim(hz / 1e3)} kHz`;
  return `${trim(hz)} Hz`;
}

function timeUnit(seconds) {
  const a = Math.abs(seconds);
  if (a >= 1) return [1, "s"];
  if (a >= 1e-3) return [1e-3, "ms"];
  if (a >= 1e-6) return [1e-6, "µs"];
  return [1e-9, "ns"];
}

function formatSeconds(seconds) {
  const [scale, unit] = timeUnit(seconds);
  return `${trim(seconds / scale)} ${unit}`;
}

function niceStep(span, targetTicks) {
  const raw = span / targetTicks;
  const power = 10 ** Math.floor(Math.log10(raw));
  const f = raw / power;
  return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * power;
}

/* ---- plot ---- */

const MARGIN = { left: 70, right: 14, top: 18, bottom: 30 };
const LANE_GAP = 14;
let layout = null; // geometry of the last draw, for the hover handlers
let drawQueued = false;

function currentData() {
  const data = app.tab === "scope" ? app.capture : app.stream;
  return data && data.channels.length && data.channels[0].length ? data : null;
}

function scheduleDraw() {
  if (drawQueued) return;
  drawQueued = true;
  requestAnimationFrame(() => { drawQueued = false; draw(); });
}

function cssColor(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function draw() {
  const canvas = $("plot");
  const box = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(box.width * dpr);
  canvas.height = Math.round(box.height * dpr);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  const ink = { surface: cssColor("--surface-1"), grid: cssColor("--grid"), primary: cssColor("--text-primary"),
                secondary: cssColor("--text-secondary"), muted: cssColor("--text-muted") };
  ctx.fillStyle = ink.surface;
  ctx.fillRect(0, 0, box.width, box.height);
  ctx.font = "12px system-ui, sans-serif";

  const data = currentData();
  $("csv").disabled = !data;
  updateTitle(data);
  if (!data) {
    layout = null;
    $("tooltip").hidden = true;
    ctx.fillStyle = ink.muted;
    ctx.textAlign = "center";
    ctx.fillText(app.tab === "scope" ? "Arm a capture to see it here." : "Start the stream to see samples here.", box.width / 2, box.height / 2);
    return;
  }

  const widths = data.channels.map((_, c) => (app.info ? app.info.channel_widths[c] : null) || bitsNeeded(data.channels[c]));
  const n = data.channels[0].length;
  const plotW = box.width - MARGIN.left - MARGIN.right;
  const plotH = box.height - MARGIN.top - MARGIN.bottom;
  const x = (i) => MARGIN.left + (n > 1 ? (i / (n - 1)) * plotW : plotW / 2);

  // lanes: one per channel, multi-bit channels get more height than 1-bit ones
  const weights = widths.map((w) => (w === 1 ? 1 : 2.4));
  const unit = (plotH - LANE_GAP * (widths.length - 1)) / weights.reduce((a, b) => a + b, 0);
  const lanes = [];
  let top = MARGIN.top;
  weights.forEach((weight, c) => {
    const height = weight * unit;
    const max = 2 ** widths[c] - 1;
    const laneTop = top;
    lanes.push({ top: laneTop, height, max, y: (v) => laneTop + height - (v / max) * height });
    top += height + LANE_GAP;
  });
  layout = { n, plotW, x, lanes, data, widths };

  drawXAxis(ctx, ink, data, n, x, box.height, plotH);

  lanes.forEach((lane, c) => {
    // baseline and labels
    ctx.strokeStyle = ink.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(MARGIN.left, Math.round(lane.top + lane.height) + 0.5);
    ctx.lineTo(MARGIN.left + plotW, Math.round(lane.top + lane.height) + 0.5);
    ctx.stroke();

    const mid = lane.top + lane.height / 2;
    ctx.fillStyle = cssColor(`--series-${c + 1}`);
    ctx.fillRect(8, mid - 9, 3, 18);
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.fillStyle = ink.primary;
    ctx.fillText(`ch${c}`, 17, widths[c] === 1 ? mid : mid - 7);
    if (widths[c] > 1) {
      ctx.fillStyle = ink.muted;
      ctx.fillText(`0-${lane.max}`, 17, mid + 8);
    }

    drawTrace(ctx, data.channels[c], lane, x, n, plotW, cssColor(`--series-${c + 1}`));
  });

  if (app.tab === "scope" && data.pre < n) {
    const tx = Math.round(x(data.pre)) + 0.5;
    ctx.strokeStyle = ink.secondary;
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(tx, MARGIN.top - 4);
    ctx.lineTo(tx, MARGIN.top + plotH);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = ink.secondary;
    ctx.textAlign = "center";
    ctx.textBaseline = "bottom";
    ctx.fillText("trigger", tx, MARGIN.top - 4);
  }

  drawHover(ctx, ink, plotH);
}

function bitsNeeded(values) {
  return Math.max(1, Math.ceil(Math.log2(Math.max(...values) + 1)));
}

function updateTitle(data) {
  if (!data) {
    $("plot-title").textContent = "No data yet";
    $("plot-sub").textContent = "";
  } else if (app.tab === "scope") {
    const period = data.decimation / app.info.clk_freq_hz;
    $("plot-title").textContent = "Captured window";
    $("plot-sub").textContent = `${data.channels[0].length} samples at ${formatHz(1 / period)}, time relative to the trigger`;
  } else {
    $("plot-title").textContent = "Live stream";
    $("plot-sub").textContent = `last ${data.channels[0].length} samples, one every ${data.decimation} clock${data.decimation === 1 ? "" : "s"} at best`;
  }
}

/* stepped trace; when there are more samples than pixels each pixel column shows its min-max span */
function drawTrace(ctx, values, lane, x, n, plotW, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  ctx.beginPath();
  if (n <= plotW) {
    ctx.moveTo(x(0), lane.y(values[0]));
    for (let i = 1; i < n; i++) {
      ctx.lineTo(x(i), lane.y(values[i - 1]));
      ctx.lineTo(x(i), lane.y(values[i]));
    }
  } else {
    const columns = Math.floor(plotW);
    for (let c = 0; c < columns; c++) {
      const i0 = Math.floor((c * n) / columns);
      const i1 = Math.max(i0 + 1, Math.floor(((c + 1) * n) / columns));
      let min = values[i0], max = values[i0];
      for (let i = i0 + 1; i < i1; i++) {
        if (values[i] < min) min = values[i];
        if (values[i] > max) max = values[i];
      }
      const px = MARGIN.left + c;
      if (c === 0) ctx.moveTo(px, lane.y(values[i0]));
      else ctx.lineTo(px, lane.y(values[i0]));
      ctx.lineTo(px, lane.y(min));
      ctx.lineTo(px, lane.y(max));
      ctx.lineTo(px, lane.y(values[i1 - 1]));
    }
  }
  ctx.stroke();
}

function drawXAxis(ctx, ink, data, n, x, height, plotH) {
  const isCapture = app.tab === "scope";
  // axis value of sample i: seconds from the trigger for a capture, samples back from the newest for a stream
  const period = isCapture ? data.decimation / app.info.clk_freq_hz : 1;
  const origin = isCapture ? data.pre : n - 1;
  const first = -origin * period, last = (n - 1 - origin) * period;
  if (last <= first) return;
  const [scale, unitName] = isCapture ? timeUnit(Math.max(Math.abs(first), Math.abs(last))) : [1, "samples"];
  let step = niceStep(last - first, 8);
  if (!isCapture) step = Math.max(1, Math.round(step));

  ctx.textAlign = "center";
  ctx.textBaseline = "top";
  for (let k = Math.ceil(first / step); k * step <= last + step * 1e-9; k++) {
    const value = k * step;
    const px = Math.round(x(value / period + origin)) + 0.5;
    ctx.strokeStyle = ink.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(px, MARGIN.top);
    ctx.lineTo(px, MARGIN.top + plotH);
    ctx.stroke();
    ctx.fillStyle = ink.muted;
    ctx.fillText(trim(value / scale), px, MARGIN.top + plotH + 6);
  }
  ctx.textAlign = "right";
  ctx.fillStyle = ink.muted;
  ctx.fillText(unitName, MARGIN.left - 8, MARGIN.top + plotH + 6);
}

function drawHover(ctx, ink, plotH) {
  const tooltip = $("tooltip");
  if (app.hover === null || !layout) { tooltip.hidden = true; return; }
  const { x, lanes, data, widths, n } = layout;
  const i = Math.min(app.hover, n - 1);
  const px = x(i);

  ctx.strokeStyle = ink.muted;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(Math.round(px) + 0.5, MARGIN.top);
  ctx.lineTo(Math.round(px) + 0.5, MARGIN.top + plotH);
  ctx.stroke();
  lanes.forEach((lane, c) => {
    ctx.beginPath();
    ctx.arc(px, lane.y(data.channels[c][i]), 4, 0, 2 * Math.PI);
    ctx.fillStyle = cssColor(`--series-${c + 1}`);
    ctx.fill();
    ctx.strokeStyle = ink.surface;
    ctx.lineWidth = 2;
    ctx.stroke();
  });

  tooltip.replaceChildren();
  const head = document.createElement("div");
  head.className = "tt-head";
  if (app.tab === "scope") {
    const t = ((i - data.pre) * data.decimation) / app.info.clk_freq_hz;
    head.textContent = `${formatSeconds(t)} (sample ${i - data.pre})`;
  } else {
    head.textContent = i === n - 1 ? "newest sample" : `${n - 1 - i} samples ago`;
  }
  tooltip.append(head);
  data.channels.forEach((values, c) => {
    const row = document.createElement("div");
    row.className = "tt-row";
    const key = document.createElement("span");
    key.className = "tt-key";
    key.style.background = `var(--series-${c + 1})`;
    const value = document.createElement("span");
    value.className = "tt-value";
    value.textContent = widths[c] > 1 ? `${values[i]} (0x${values[i].toString(16).toUpperCase()})` : values[i];
    const name = document.createElement("span");
    name.className = "tt-name";
    name.textContent = `ch${c}`;
    row.append(key, value, name);
    tooltip.append(row);
  });
  tooltip.hidden = false;
  const wrap = $("plot-wrap").getBoundingClientRect();
  const left = px + 14 + tooltip.offsetWidth > wrap.width ? px - 14 - tooltip.offsetWidth : px + 14;
  tooltip.style.left = `${Math.max(0, left)}px`;
  tooltip.style.top = `${MARGIN.top + 4}px`;
}

function hoverAt(clientX) {
  if (!layout) return;
  const rel = clientX - $("plot").getBoundingClientRect().left - MARGIN.left;
  app.hover = Math.max(0, Math.min(layout.n - 1, Math.round((rel / layout.plotW) * (layout.n - 1))));
  draw();
}

/* ---- wiring ---- */

$("conn").addEventListener("submit", toggleConnection);
$("refresh").addEventListener("click", refreshPorts);
$("error-close").addEventListener("click", () => showError(null));
$("tab-scope").addEventListener("click", () => selectTab("scope"));
$("tab-stream").addEventListener("click", () => selectTab("stream"));
$("arm").addEventListener("click", arm);
$("abort").addEventListener("click", stop);
$("s-start").addEventListener("click", startStream);
$("s-stop").addEventListener("click", stop);
$("csv").addEventListener("click", downloadCsv);
for (const id of ["pre", "post", "decim"]) $(id).addEventListener("input", updateScopeHint);

$("plot").addEventListener("pointermove", (e) => hoverAt(e.clientX));
$("plot").addEventListener("pointerleave", () => { app.hover = null; draw(); });
$("plot").addEventListener("keydown", (e) => {
  if (!layout || (e.key !== "ArrowLeft" && e.key !== "ArrowRight")) return;
  e.preventDefault();
  const from = app.hover === null ? (app.tab === "scope" ? layout.data.pre : layout.n - 1) : app.hover;
  app.hover = Math.max(0, Math.min(layout.n - 1, from + (e.key === "ArrowLeft" ? -1 : 1)));
  draw();
});
$("plot").addEventListener("blur", () => { app.hover = null; draw(); });

new ResizeObserver(draw).observe($("plot-wrap"));
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", draw);

refreshPorts();
openSocket();
updateControls();
draw();
