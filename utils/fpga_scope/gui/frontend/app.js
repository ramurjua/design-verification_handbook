/* fpga_scope frontend. Commands go to the backend over REST (/api/...), and
   everything the backend reports asynchronously arrives on one WebSocket (/ws).
   See ../backend/app.py and ../backend/session.py for both interfaces.
   The display maths (scaling, axes, zoom, file formats) is in scope_math.js. */

const $ = (id) => document.getElementById(id);
const M = ScopeMath;

const TRIGGER_OPTIONS = [["off", "Off"], ["rise", "Rising edge"], ["fall", "Falling edge"], ["high", "High level"], ["low", "Low level"]];
const STATE_LABELS = { disconnected: "Disconnected", idle: "Idle", armed: "Armed, waiting for trigger", capturing: "Capturing", streaming: "Streaming" };
const STORAGE_KEY = "fpga_scope.config";

/* per-channel display settings, in the order they are shown: [key, label, kind, options] */
const CHANNEL_FIELDS = [
  ["name", "Name", "text"],
  ["unit", "Unit", "text"],
  ["signed", "Signed (two's complement)", "check"],
  ["frac", "Fraction bits", "int"],
  ["gain", "Gain", "number"],
  ["offset", "Offset", "number"],
  ["format", "Raw value as", "select", [["hex", "Hex"], ["dec", "Decimal"], ["bin", "Binary"]]],
  ["range", "Y range", "select", [["full", "Full scale"], ["auto", "Fit to visible samples"], ["manual", "Manual"]]],
  ["min", "Y min", "number"],
  ["max", "Y max", "number"],
  ["style", "Trace", "select", [["step", "Steps"], ["line", "Lines"], ["bus", "Bus (values)"]]],
  ["height", "Lane height", "select", [["auto", "Auto"], ["small", "Small"], ["medium", "Medium"], ["large", "Large"], ["xlarge", "Extra large"]]],
  ["bits", "One lane per bit", "check"],
  ["high", "Upper bits from", "channel", "None"],
  ["lane", "Draw in the lane of", "channel", "Its own"],
];

/* settings of a control: [key, label, kind, options, the kinds of control it applies to (all if not given)] */
const CONTROL_FIELDS = [
  ["name", "Name", "text"],
  ["kind", "Shown as", "select", [["off", "Not used"], ["button", "Button"], ["toggle", "Switch (on / off)"], ["value", "Value"], ["select", "Drop-down list"]]],
  ["value", "Value a press writes", "raw", null, ["button"]],
  ["unit", "Unit", "text", null, ["value"]],
  ["signed", "Signed (two's complement)", "check", null, ["value"]],
  ["frac", "Fraction bits", "int", null, ["value"]],
  ["gain", "Gain", "number", null, ["value"]],
  ["offset", "Offset", "number", null, ["value"]],
  ["min", "Smallest allowed", "limit", null, ["value"]],
  ["max", "Largest allowed", "limit", null, ["value"]],
  ["values", "Entries", "list", null, ["select"]],
];
const CONTROL_KIND_NOTES = { off: "not used", button: "button", toggle: "switch", value: "value", select: "drop-down" };

const app = {
  info: null, // what CMD_GET_INFO reported, null while disconnected
  controls: null, // the raw value of every control as last read from the core, null while unknown
  state: "disconnected",
  fillCount: 0,
  tab: "scope",
  capture: null, // { channels, pre, decimation, widths, clk_freq_hz }
  stream: null, // { channels, decimation, widths, clk_freq_hz }
  recording: null, // every burst since Start recording: { channels, burst, bursts, widths }
  reference: null, // an earlier capture, drawn behind the current one
  hover: null, // sample index under the crosshair
  online: false, // WebSocket to the backend is up
  config: loadLocalConfig(), // see ScopeMath.defaultConfig
  view: { scope: null, stream: null }, // visible sample span of each tab, null for everything
  cursors: { scope: { a: null, b: null }, stream: { a: null, b: null } }, // sample indexes
};
let configRev = 0; // bumped on every display setting change
let dataRev = 0; // bumped whenever the samples on screen change

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
    if (app.info) showCapture({ channels: msg.channels, pre: msg.pre, decimation: msg.decimation,
                                widths: app.info.channel_widths, clk_freq_hz: app.info.clk_freq_hz });
  } else if (msg.type === "stream") {
    appendStream(msg);
  } else if (msg.type === "error") {
    showError(msg.message);
  }
}

function showCapture(capture) {
  // a window of another length makes the old zoom meaningless
  if (!app.capture || app.capture.channels[0].length !== capture.channels[0].length) app.view.scope = null;
  app.capture = capture;
  app.hover = null;
  dataRev++;
  buildChannelRows();
  draw();
}

function appendStream(msg) {
  if (!app.info) return;
  const keep = clampInt($("s-window"), 2000);
  if (!app.stream) app.stream = { channels: msg.channels.map(() => []), widths: app.info.channel_widths, clk_freq_hz: app.info.clk_freq_hz };
  app.stream.decimation = msg.decimation;
  app.stream.channels = app.stream.channels.map((old, c) => old.concat(msg.channels[c]).slice(-keep));
  app.view.stream = null; // a running stream always shows its whole window
  record(msg);
  dataRev++;
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
      + `(captures up to ${info.max_capture_samples} samples), ${M.formatHz(info.clk_freq_hz)} sample clock`;
    buildTriggerRows(info);
    $("pre").max = $("post").max = info.max_capture_samples;
  }
  buildChannelRows();
  app.controls = null;
  if (info && info.num_controls) fetchControls();
  renderControls();
  updateControls();
}

function setState(state, fillCount = 0) {
  app.state = state;
  app.fillCount = fillCount;
  if (state === "disconnected") {
    app.info = null;
    if (app.controls) { app.controls = null; renderControls(); } // what the core held says nothing about the next one
  }
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
  $("rec-start").disabled = !connected || !!app.recording;
  $("rec-stop").disabled = !app.recording;
  $("cfg-save").disabled = $("cfg-load").disabled = $("cfg-delete").disabled = !app.online;
  for (const input of $("controls").querySelectorAll("button, input")) input.disabled = !controlsUsable();
  updateScopeHint();
}

function buildTriggerRows(info, force = false) {
  const box = $("triggers");
  if (!force && box.dataset.widths === info.channel_widths.join(",")) return; // same core as before, keep the user's choices
  box.dataset.widths = info.channel_widths.join(",");
  box.replaceChildren();

  info.channel_widths.forEach((width, c) => {
    const saved = app.config.trigger.channels[c];
    const name = document.createElement("span");
    name.className = "ch-name";
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = `var(--series-${c + 1})`;
    const text = document.createElement("span");
    text.id = `trig-name-${c}`;
    text.textContent = app.config.channels[c].name;
    const small = document.createElement("small");
    small.textContent = width === 1 ? "1 bit" : `${width} bits`;
    name.append(swatch, text, small);

    const type = document.createElement("select");
    type.id = `trig-type-${c}`;
    type.setAttribute("aria-label", `ch${c} trigger`);
    for (const [value, label] of TRIGGER_OPTIONS) type.add(new Option(label, value));
    type.value = saved.type;

    const bit = document.createElement("select");
    bit.id = `trig-bit-${c}`;
    bit.setAttribute("aria-label", `ch${c} trigger bit`);
    for (let b = 0; b < width; b++) bit.add(new Option(`bit ${b}`, b));
    bit.value = Math.min(saved.bit, width - 1);
    bit.style.visibility = width === 1 ? "hidden" : "visible";

    box.append(name, type, bit);
  });
}

function updateScopeHint() {
  if (!app.info) { $("scope-hint").textContent = ""; return; }
  const decim = clampInt($("decim"), 1);
  const pre = clampInt($("pre"), 0), post = clampInt($("post"), 0);
  const total = pre + post;
  const period = decim / app.info.clk_freq_hz;
  const max = app.info.max_capture_samples;
  const problem = M.captureWindowFits(pre, post, max) ? ""
    : total < 1 ? " (empty: no samples to capture)"
    : ` (too long: at most ${max} samples, pre at most ${max - 1} with post 0)`;
  $("scope-hint").textContent = `Sample rate ${M.formatHz(1 / period)}, window ${total} samples = ${M.formatSeconds(total * period)}${problem}`;
}

function clampInt(input, fallback) {
  const value = parseInt(input.value, 10);
  return Number.isFinite(value) ? value : fallback;
}

/* ---- channel display settings ---- */

/* the channels on screen: those of the data being shown, else those of the connected core */
function activeWidths() {
  const data = currentData();
  return data ? data.widths : app.info ? app.info.channel_widths : [];
}

function buildChannelRows(force = false) {
  const box = $("channels");
  const widths = activeWidths();
  if (!force && box.dataset.widths === widths.join(",")) return;
  box.dataset.widths = widths.join(",");
  box.replaceChildren();
  $("channels-hint").hidden = widths.length > 0;

  widths.forEach((width, c) => {
    const cfg = app.config.channels[c];
    const details = document.createElement("details");
    details.className = "chan";
    details.id = `chan-${c}`;

    const summary = document.createElement("summary");
    const visible = document.createElement("input");
    visible.type = "checkbox";
    visible.id = `ch${c}-visible`;
    visible.checked = cfg.visible;
    visible.title = "Show this channel";
    visible.setAttribute("aria-label", `Show ch${c}`);
    visible.addEventListener("input", () => setChannel(c, "visible", visible.checked));
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = `var(--series-${c + 1})`;
    const name = document.createElement("span");
    name.id = `chan-name-${c}`;
    const note = document.createElement("small");
    note.id = `chan-note-${c}`;
    summary.append(visible, swatch, name, note);

    const fields = document.createElement("div");
    fields.className = "fields";
    for (const [key, label, kind, options] of CHANNEL_FIELDS) {
      const id = `ch${c}-${key}`;
      const caption = document.createElement("label");
      caption.htmlFor = id;
      caption.textContent = label;
      let input;
      if (kind === "select" || kind === "channel") {
        input = document.createElement("select");
        if (kind === "select") for (const [value, text] of options) input.add(new Option(text, value));
        else {
          input.add(new Option(options, ""));
          widths.forEach((_, other) => { if (other !== c) input.add(new Option(`ch${other}`, other)); });
        }
        input.value = cfg[key] === null ? "" : cfg[key];
        if (input.selectedIndex < 0) input.value = ""; // points at a channel this core does not have
      } else {
        input = document.createElement("input");
        input.type = kind === "check" ? "checkbox" : kind === "text" ? "text" : "number";
        if (kind === "check") input.checked = cfg[key];
        else input.value = cfg[key];
        if (kind === "number") input.step = "any";
        if (kind === "int") { input.min = 0; input.max = M.MAX_SIGNAL_BITS; }
        if (kind === "text") input.maxLength = key === "name" ? 24 : 12;
      }
      input.id = id;
      input.addEventListener("input", () => {
        if (kind === "check") setChannel(c, key, input.checked);
        else if (kind === "text") setChannel(c, key, input.value.trim() || (key === "name" ? `ch${c}` : ""));
        else if (kind === "channel") setChannel(c, key, input.value === "" ? null : Number(input.value));
        else if (kind === "select") setChannel(c, key, input.value);
        else if (kind === "int") setChannel(c, key, Math.min(M.MAX_SIGNAL_BITS, Math.max(0, parseInt(input.value, 10) || 0)));
        else if (Number.isFinite(parseFloat(input.value))) setChannel(c, key, parseFloat(input.value)); // a half-typed number changes nothing
      });
      fields.append(caption, input);
    }
    const names = document.createElement("p"); // named values and bit fields only come from a configuration file
    names.className = "hint";
    names.id = `ch${c}-names`;
    details.append(summary, fields, names);
    box.append(details);
  });
  refreshChannelRows();
}

function setChannel(c, key, value) {
  app.config.channels[c][key] = value;
  configRev++;
  refreshChannelRows();
  saveLocalConfig();
  draw();
}

/* what depends on the settings of other channels: names, notes, and which fields apply */
function refreshChannelRows() {
  const widths = activeWidths();
  const signals = M.buildSignals(widths, app.config.channels);
  widths.forEach((width, c) => {
    const cfg = app.config.channels[c];
    if (!$(`chan-${c}`)) return;
    const own = signals.find((s) => s.base === c);
    const owner = signals.find((s) => s.parts.includes(c));
    $(`chan-name-${c}`).textContent = cfg.name;
    let note = `ch${c}, ${width === 1 ? "1 bit" : `${width} bits`}`;
    if (!own) note += `, upper bits of ${owner.cfg.name}`;
    else if (own.parts.length > 1) note += `, ${own.width} bits with ${own.parts.slice(1).map((p) => `ch${p}`).join(" and ")}`;
    if (own && own.width > 1) note += cfg.signed ? ", signed" : ", unsigned";
    $(`chan-note-${c}`).textContent = note;
    $(`chan-${c}`).classList.toggle("part", !own);
    for (const [key] of CHANNEL_FIELDS) {
      const input = $(`ch${c}-${key}`);
      input.disabled = !own || ((key === "signed" || key === "bits") && own.width === 1);
      const manualOnly = (key === "min" || key === "max") && cfg.range !== "manual";
      input.hidden = input.labels[0].hidden = manualOnly;
    }
    $(`ch${c}-visible`).disabled = !own;
    $(`ch${c}-names`).textContent = own ? namesNote(own) : "";
    $(`ch${c}-names`).hidden = !$(`ch${c}-names`).textContent;
    if ($(`trig-name-${c}`)) $(`trig-name-${c}`).textContent = cfg.name;
  });
}

/* what a signal has of named values and bit fields, which are only set in a configuration file */
function namesNote(signal) {
  const { cfg, width } = signal;
  const count = (values) => Object.keys(values).length;
  const parts = [];
  if (M.hasNames(cfg)) parts.push(`Named values: ${count(cfg.values)}.`);
  const fields = cfg.fields.filter((f) => f.bits);
  if (fields.length) {
    const range = ([msb, lsb]) => (msb === lsb ? `[${msb}]` : `[${msb}:${lsb}]`);
    parts.push(`Fields, each in a lane of its own: ${fields.map((f) => `${f.name} ${range(f.bits)}${count(f.values) ? ` (${count(f.values)} names)` : ""}`).join(", ")}.`);
    const outside = fields.filter((f) => f.bits[0] >= width);
    if (outside.length) parts.push(`${outside.map((f) => f.name).join(", ")} go${outside.length === 1 ? "es" : ""} above the signal's ${width} bits, which read as 0.`);
  }
  return parts.length ? `${parts.join(" ")} Set in the configuration file.` : "";
}

/* ---- controls: values written to the FPGA ---- */

const controlsUsable = () => !!app.info && app.info.num_controls > 0;

/* the settings of the 8 controls, in the side panel */
function buildControlRows() {
  const box = $("control-rows");
  box.replaceChildren();
  app.config.controls.forEach((cfg, i) => {
    const details = document.createElement("details");
    details.className = "ctl";
    details.id = `ctl-${i}`;
    const summary = document.createElement("summary");
    const name = document.createElement("span");
    name.id = `ctl-name-${i}`;
    const note = document.createElement("small");
    note.id = `ctl-note-${i}`;
    summary.append(name, note);

    const fields = document.createElement("div");
    fields.className = "fields";
    for (const [key, label, kind, options] of CONTROL_FIELDS) {
      const id = `ctl${i}-${key}`;
      const caption = document.createElement("label");
      caption.htmlFor = id;
      caption.textContent = label;
      let input;
      if (kind === "select") {
        input = document.createElement("select");
        for (const [value, text] of options) input.add(new Option(text, value));
        input.value = cfg[key];
      } else {
        input = document.createElement("input");
        input.type = kind === "check" ? "checkbox" : kind === "text" || kind === "raw" ? "text" : "number";
        if (kind === "check") input.checked = cfg[key];
        else input.value = cfg[key] === null ? "" : cfg[key];
        if (kind === "number" || kind === "limit") input.step = "any";
        if (kind === "int") { input.min = 0; input.max = M.MAX_SIGNAL_BITS; }
        if (kind === "text") input.maxLength = key === "name" ? 24 : 12;
        if (kind === "raw") input.title = "A whole number from 0 to 4294967295, decimal or 0x...";
        if (kind === "limit") input.placeholder = "none";
        if (kind === "list") {
          input.type = "text";
          input.value = M.valueListText(cfg.values);
          input.placeholder = "0=MOTOR 0; 1=MOTOR 1";
          input.title = "value=name pairs separated by ;, the value a whole number (decimal or 0x...) that picking the name writes";
        }
      }
      input.id = id;
      input.addEventListener("input", () => {
        const typed = input.value.trim();
        if (kind === "check") setControl(i, key, input.checked);
        else if (kind === "text") setControl(i, key, typed || (key === "name" ? `control${i}` : ""));
        else if (kind === "select") setControl(i, key, input.value);
        else if (kind === "int") setControl(i, key, Math.min(M.MAX_SIGNAL_BITS, Math.max(0, parseInt(typed, 10) || 0)));
        else if (kind === "limit") { if (typed === "" || Number.isFinite(Number(typed))) setControl(i, key, typed === "" ? null : Number(typed)); }
        else if (kind === "list") { // applied once it reads as a list; a half-typed entry changes nothing
          const values = M.parseValueList(typed);
          input.setCustomValidity(values ? "" : "Write value=name pairs separated by ;");
          if (values) setControl(i, key, values);
        }
        else if (kind === "raw") { if (typed !== "" && Number.isInteger(Number(typed)) && Number(typed) >= 0 && Number(typed) <= M.MAX_CONTROL_RAW) setControl(i, key, Number(typed)); }
        else if (Number.isFinite(parseFloat(typed)) && !(key === "gain" && parseFloat(typed) === 0)) setControl(i, key, parseFloat(typed)); // a half-typed number changes nothing
      });
      fields.append(caption, input);
    }
    details.append(summary, fields);
    box.append(details);
  });
  refreshControlRows();
}

function setControl(i, key, value) {
  app.config.controls[i][key] = value;
  refreshControlRows();
  saveLocalConfig();
  renderControls();
}

/* names, notes, and which fields apply to the kind of control chosen */
function refreshControlRows() {
  app.config.controls.forEach((cfg, i) => {
    $(`ctl-name-${i}`).textContent = cfg.name;
    const listed = cfg.kind === "select" ? `, ${Object.keys(cfg.values).length} entries` : "";
    $(`ctl-note-${i}`).textContent = `control ${i}, ${CONTROL_KIND_NOTES[cfg.kind]}${listed}`;
    $(`ctl-${i}`).classList.toggle("unused", cfg.kind === "off");
    for (const [key, , , , kinds] of CONTROL_FIELDS) {
      const input = $(`ctl${i}-${key}`);
      input.hidden = input.labels[0].hidden = !!kinds && !kinds.includes(cfg.kind);
    }
  });
}

/* a control's value in its own units, as text */
function controlText(cfg, raw) {
  if (cfg.kind === "select") {
    const name = M.valueName(cfg, raw);
    return name === undefined ? String(raw) : name;
  }
  return M.formatValue(Number(M.controlShown(cfg, raw).toPrecision(9))) + (cfg.unit ? ` ${cfg.unit}` : "");
}

/* the controls in use, at the top of the right-hand panel: a button, a switch, or a number with a Send button */
function renderControls() {
  const bar = $("controls");
  const typed = {}; // what was being typed survives the rebuild
  for (const input of bar.querySelectorAll("input")) typed[input.id] = input.value;
  bar.replaceChildren();
  const used = app.config.controls.map((cfg, i) => [cfg, i]).filter(([cfg]) => cfg.kind !== "off");
  bar.hidden = !used.length;
  $("controls-none").hidden = used.length > 0;

  for (const [cfg, i] of used) {
    const raw = app.controls ? app.controls[i] : null;
    const item = document.createElement("span");
    item.className = "control";
    if (cfg.kind === "value") {
      const label = document.createElement("label");
      label.htmlFor = `ctl-in-${i}`;
      label.textContent = cfg.name;
      const input = document.createElement("input");
      input.type = "number";
      input.step = "any";
      input.id = `ctl-in-${i}`;
      input.value = typed[input.id] || "";
      input.addEventListener("keydown", (event) => { if (event.key === "Enter") sendControlValue(i); });
      const send = document.createElement("button");
      send.type = "button";
      send.id = `ctl-send-${i}`;
      send.textContent = "Send";
      send.addEventListener("click", () => sendControlValue(i));
      const now = document.createElement("small");
      now.id = `ctl-now-${i}`;
      now.textContent = raw === null ? "" : `now ${controlText(cfg, raw)}`;
      item.append(label, input);
      if (cfg.unit) item.append(cfg.unit);
      item.append(send, now);
    } else if (cfg.kind === "select") {
      // shows what the FPGA holds, like a switch; picking an entry writes its value at once
      const label = document.createElement("label");
      label.htmlFor = `ctl-sel-${i}`;
      label.textContent = cfg.name;
      const list = document.createElement("select");
      list.id = `ctl-sel-${i}`;
      const known = raw !== null && M.valueName(cfg, raw) !== undefined;
      if (!known) { // unknown, or a value the list does not have: say so rather than show a wrong entry
        const placeholder = new Option(raw === null ? "?" : `${raw} (not in the list)`, "", true, true);
        placeholder.disabled = true;
        list.add(placeholder);
      }
      for (const [value, text] of Object.entries(cfg.values)) list.add(new Option(text, value));
      if (known) list.value = String(raw);
      list.addEventListener("change", () => { if (list.value !== "") writeControl(i, Number(list.value)); });
      item.append(label, list);
    } else {
      const button = document.createElement("button");
      button.type = "button";
      button.id = `ctl-btn-${i}`;
      if (cfg.kind === "toggle") {
        const on = raw !== null && raw !== 0;
        button.textContent = `${cfg.name}: ${raw === null ? "?" : on ? "on" : "off"}`;
        button.setAttribute("aria-pressed", String(on));
        button.addEventListener("click", () => writeControl(i, on ? 0 : 1));
      } else {
        button.textContent = cfg.name;
        button.title = `Writes ${cfg.value} to control ${i}`;
        button.addEventListener("click", () => writeControl(i, cfg.value));
      }
      item.append(button);
    }
    for (const input of item.querySelectorAll("button, input, select")) input.disabled = !controlsUsable();
    if (cfg.kind === "select" && !Object.keys(cfg.values).length) item.querySelector("select").disabled = true; // nothing to pick yet
    bar.append(item);
  }
  if (app.info && !app.info.num_controls && used.length) {
    $("controls-status").textContent = "The connected core has no controls: it was built from RTL older than them.";
  } else if ($("controls-status").textContent.startsWith("The connected core")) $("controls-status").textContent = "";
}

async function fetchControls() {
  const reply = await command(() => api("GET", "/api/controls"));
  app.controls = reply && reply.values.length ? reply.values : null;
  renderControls();
}

/* write a raw value, then show what the core says it holds */
async function writeControl(i, raw) {
  const reply = await command(() => api("POST", `/api/controls/${i}`, { value: raw }));
  if (!reply) return;
  if (!app.controls) app.controls = new Array(M.MAX_CONTROLS).fill(0);
  app.controls[i] = reply.value;
  const cfg = app.config.controls[i];
  $("controls-status").textContent = `${cfg.name}: wrote ${cfg.kind === "value" || cfg.kind === "select" ? controlText(cfg, reply.value) : reply.value} to control ${i}.`;
  renderControls();
}

function sendControlValue(i) {
  const cfg = app.config.controls[i];
  const typed = $(`ctl-in-${i}`).value.trim();
  const result = typed === "" ? { error: "type a number first" } : M.controlRaw(cfg, Number(typed));
  if (result.error) $("controls-status").textContent = `${cfg.name}: ${result.error}. Nothing was sent.`;
  else return writeControl(i, result.raw);
}

/* ---- configuration: this browser's storage, and named files kept by the backend ---- */

function loadLocalConfig() {
  try {
    return ScopeMath.normalizeConfig(JSON.parse(localStorage.getItem(STORAGE_KEY)));
  } catch {
    return ScopeMath.defaultConfig(); // storage blocked or corrupt
  }
}

/* the configuration as it stands, reading the trigger and window settings off the page */
function collectConfig() {
  const config = M.normalizeConfig(app.config);
  config.trigger.combine = $("combine").value;
  config.trigger.channels.forEach((t, c) => {
    if (!$(`trig-type-${c}`)) return;
    t.type = $(`trig-type-${c}`).value;
    t.bit = parseInt($(`trig-bit-${c}`).value, 10) || 0;
  });
  config.window = { pre: clampInt($("pre"), 100), post: clampInt($("post"), 300), decimation: clampInt($("decim"), 1) };
  config.stream = { decimation: clampInt($("s-decim"), 1), batch: clampInt($("s-batch"), 200), window: clampInt($("s-window"), 2000) };
  return M.normalizeConfig(config);
}

function saveLocalConfig() {
  const config = collectConfig();
  Object.assign(app.config, { trigger: config.trigger, window: config.window, stream: config.stream });
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  } catch { /* storage blocked: the settings just do not outlive the page */ }
}

function writeSettings() {
  const { trigger, window: win, stream } = app.config;
  $("combine").value = trigger.combine;
  $("pre").value = win.pre;
  $("post").value = win.post;
  $("decim").value = win.decimation;
  $("s-decim").value = stream.decimation;
  $("s-batch").value = stream.batch;
  $("s-window").value = stream.window;
}

function applyConfig(config) {
  app.config = M.normalizeConfig(config);
  configRev++;
  writeSettings();
  if (app.info) buildTriggerRows(app.info, true);
  buildChannelRows(true);
  buildControlRows();
  renderControls();
  saveLocalConfig();
  updateScopeHint();
  draw();
}

async function refreshConfigList() {
  const names = await command(() => api("GET", "/api/configs"));
  if (!names) return;
  $("cfg-names").replaceChildren(...names.map((name) => new Option(name, name)));
}

function configName() {
  const name = $("cfg-name").value.trim();
  $("cfg-status").textContent = name ? "" : "Type a name first.";
  return name;
}

async function saveConfig() {
  const name = configName();
  if (!name) return;
  if (!await command(() => api("PUT", `/api/configs/${encodeURIComponent(name)}`, collectConfig()))) return;
  $("cfg-status").textContent = `Saved "${name}".`;
  refreshConfigList();
}

async function loadConfig() {
  const name = configName();
  if (!name) return;
  const config = await command(() => api("GET", `/api/configs/${encodeURIComponent(name)}`));
  if (!config) return;
  applyConfig(config);
  $("cfg-status").textContent = `Loaded "${name}".`;
}

async function deleteConfig() {
  const name = configName();
  if (!name) return;
  if (!await command(() => api("DELETE", `/api/configs/${encodeURIComponent(name)}`))) return;
  $("cfg-status").textContent = `Deleted "${name}".`;
  refreshConfigList();
}

/* a configuration from a JSON file picked on this computer, possibly written by hand */
function loadConfigText(text, fileName) {
  let raw;
  try {
    raw = JSON.parse(text);
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("it does not hold a JSON object");
  } catch (e) {
    showError(`Cannot use ${fileName}: ${e.message}`);
    return;
  }
  showError(null);
  const problems = M.configProblems(raw);
  applyConfig(raw);
  $("cfg-status").textContent = `Loaded ${fileName}.` + (problems.length ? ` Not used, left at the default: ${problems.join(", ")}.` : "");
}

async function openConfigFile() {
  const file = $("cfg-file").files[0];
  $("cfg-file").value = ""; // so that picking the same file again fires "change"
  if (file) loadConfigText(await file.text(), file.name);
}

function exportConfig() {
  download(JSON.stringify(collectConfig(), null, 2) + "\n", `${$("cfg-name").value.trim() || "fpga_scope_config"}.json`, "application/json");
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
  app.view.stream = null;
  app.cursors.stream = { a: null, b: null };
  dataRev++;
  draw();
  return command(() => api("POST", "/api/stream", { decimation: clampInt($("s-decim"), 1), batch: clampInt($("s-batch"), 200) }));
}

const stop = () => command(() => api("POST", "/api/stop"));

/* ---- recording: the whole stream, not only the samples on screen ---- */

const RECORDING_FILE = "fpga_scope_recording.csv";
const recordedText = (rec) => `${rec.burst.length} samples in ${rec.bursts} burst${rec.bursts === 1 ? "" : "s"}`;

function startRecording() {
  const widths = app.info.channel_widths;
  app.recording = { channels: widths.map(() => []), burst: [], bursts: 0, widths };
  $("rec-status").textContent = app.state === "streaming" ? "Recording." : "Recording: waiting for the stream to start.";
  updateControls();
}

function record(msg) {
  const rec = app.recording;
  if (!rec || msg.channels.length !== rec.channels.length) return;
  msg.channels.forEach((samples, c) => { for (const v of samples) rec.channels[c].push(v); });
  for (let i = 0; i < msg.channels[0].length; i++) rec.burst.push(rec.bursts);
  rec.bursts++;
  $("rec-status").textContent = `Recording: ${recordedText(rec)}.`;
}

/* every signal as shown, like csvText(), plus the burst each sample came in: bursts are not contiguous in time */
function recordingCsv() {
  const rec = app.recording;
  const signals = M.buildSignals(rec.widths, app.config.channels).map((s) => {
    const raw = M.rawValues(s, rec.widths, rec.channels);
    return { ...s, raw, values: M.scaleValues(raw, s.width, s.cfg) };
  });
  return M.csvText([{ name: "burst", values: rec.burst }].concat(M.csvColumns(signals)));
}

function stopRecording() {
  const rec = app.recording;
  if (rec.burst.length) download(recordingCsv(), RECORDING_FILE, "text/csv");
  $("rec-status").textContent = rec.burst.length ? `Saved ${recordedText(rec)} as ${RECORDING_FILE}.` : "Nothing was recorded: no samples arrived.";
  app.recording = null;
  updateControls();
}

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
  buildChannelRows();
  draw();
}

function download(text, name, type) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([text], { type }));
  link.download = name;
  link.click();
  URL.revokeObjectURL(link.href);
}

/* every signal as shown (scaled, under its own name), hidden ones included */
function csvText() {
  const data = currentData();
  if (!data) return "";
  return M.csvText(M.csvColumns(derive(data).signals), app.tab === "scope" ? { pre: data.pre, period: data.decimation / data.clk_freq_hz } : {});
}

function downloadCsv() {
  if (currentData()) download(csvText(), app.tab === "scope" ? "fpga_scope_capture.csv" : "fpga_scope_stream.csv", "text/csv");
}

/* a capture file holds the raw samples and the configuration they were looked at with */
function captureFileText() {
  return JSON.stringify(M.captureFile(app.capture, collectConfig()));
}

async function loadCaptureText(text) {
  let loaded;
  try {
    loaded = M.parseCaptureFile(JSON.parse(text));
  } catch (e) {
    showError(e.message);
    return;
  }
  showError(null);
  await selectTab("scope");
  app.view.scope = null;
  app.cursors.scope = { a: null, b: null };
  app.capture = null;
  showCapture(loaded.capture);
  if (loaded.config) applyConfig(loaded.config);
}

async function loadCaptureFile() {
  const file = $("cap-file").files[0];
  $("cap-file").value = ""; // so that picking the same file again fires "change"
  if (file) await loadCaptureText(await file.text());
}

/* ---- plot ---- */

const MARGIN = { left: 70, right: 14, top: 18, bottom: 30 }; // left is a minimum: it grows with the names and tick labels
const LANE_GAP = 14;
const FONT = "12px system-ui, sans-serif";
let layout = null; // geometry of the last draw, for the pointer and key handlers
let drawQueued = false;

function currentData() {
  const data = app.tab === "scope" ? app.capture : app.stream;
  return data && data.channels.length && data.channels[0].length ? data : null;
}

/* the signals of a capture or stream under the current configuration: raw and scaled values, and their lanes */
function derive(data) {
  const cached = data.derived;
  if (cached && cached.rev === configRev && cached.source === data.channels) return cached;
  const signals = M.buildSignals(data.widths, app.config.channels).map((s) => {
    const raw = M.rawValues(s, data.widths, data.channels);
    return { ...s, raw, values: M.scaleValues(raw, s.width, s.cfg) };
  });
  data.derived = { rev: configRev, source: data.channels, signals, groups: M.laneGroups(signals) };
  return data.derived;
}

function currentView(n) {
  const view = app.view[app.tab];
  return view ? M.clampView(view, n) : M.fullView(n);
}

/* zooming a stream only makes sense once it has stopped moving */
const canZoom = () => !(app.tab === "stream" && app.state === "streaming");

function scheduleDraw() {
  if (drawQueued) return;
  drawQueued = true;
  requestAnimationFrame(() => { drawQueued = false; draw(); });
}

function cssColor(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

const seriesColor = (signal) => cssColor(`--series-${signal.base + 1}`);

function draw() {
  const canvas = $("plot");
  const box = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(box.width * dpr);
  canvas.height = Math.round(box.height * dpr);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  const ink = { surface: cssColor("--surface-1"), grid: cssColor("--grid"), primary: cssColor("--text-primary"),
                secondary: cssColor("--text-secondary"), muted: cssColor("--text-muted"), accent: cssColor("--accent") };
  ctx.fillStyle = ink.surface;
  ctx.fillRect(0, 0, box.width, box.height);
  ctx.font = FONT;

  const data = currentData();
  updateToolbar(data);
  updateTitle(data);
  const groups = data ? derive(data).groups : [];
  if (!groups.length) {
    layout = null;
    $("tooltip").hidden = true;
    updateMeasurements();
    ctx.fillStyle = ink.muted;
    ctx.textAlign = "center";
    const message = data ? "Every channel is hidden." : app.tab === "scope" ? "Arm a capture to see it here." : "Start the stream to see samples here.";
    ctx.fillText(message, box.width / 2, box.height / 2);
    return;
  }

  const n = data.channels[0].length;
  const view = currentView(n);
  const [first, last] = M.visibleSamples(view, n);
  const plotH = box.height - MARGIN.top - MARGIN.bottom;

  // lanes: one per group of signals, with its own Y axis
  const weights = groups.map(M.laneWeight);
  const unit = (plotH - LANE_GAP * (groups.length - 1)) / weights.reduce((a, b) => a + b, 0);
  const lanes = [];
  let top = MARGIN.top;
  groups.forEach((group, g) => {
    const height = Math.max(4, weights[g] * unit);
    const [min, max] = M.laneRange(group, first, last);
    const laneTop = top;
    const plain = group.members.every((s) => s.width === 1 || s.cfg.style === "bus"); // nothing to read off a Y axis
    lanes.push({ group, top: laneTop, height, min, max,
                 axis: plain ? { step: 1, values: [] } : M.ticks(min, max, Math.floor(height / 26)),
                 y: (v) => laneTop + height - ((v - min) / (max - min)) * height });
    top += height + LANE_GAP;
  });

  let nameW = 0, tickW = 0;
  for (const lane of lanes) {
    for (const s of lane.group.members) nameW = Math.max(nameW, ctx.measureText(M.label(s.cfg)).width);
    for (const v of lane.axis.values) tickW = Math.max(tickW, ctx.measureText(M.formatTick(v, lane.axis.step)).width);
  }
  const left = Math.min(Math.max(MARGIN.left, 17 + nameW + 12 + tickW + 8), box.width * 0.45);
  const plotW = Math.max(10, box.width - left - MARGIN.right);
  const span = view.end - view.start;
  const x = (i) => left + ((i - view.start) / span) * plotW;
  const sampleAt = (px) => view.start + ((px - left) / plotW) * span;
  layout = { n, left, plotW, plotH, x, sampleAt, lanes, data, view, first, last };

  drawXAxis(ctx, ink, box.height);

  // one sample beyond each edge, so that the traces run off the plot instead of stopping short
  const from = Math.max(0, first - 1), to = Math.min(n - 1, last + 1);
  const reference = app.tab === "scope" && app.reference && app.reference !== data ? app.reference : null;
  lanes.forEach((lane) => {
    const bottom = Math.round(lane.top + lane.height) + 0.5;
    ctx.lineWidth = 1;
    ctx.strokeStyle = ink.grid;
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    ctx.beginPath();
    ctx.moveTo(left, bottom);
    ctx.lineTo(left + plotW, bottom);
    for (const v of lane.axis.values) {
      const py = Math.round(lane.y(v)) + 0.5;
      ctx.moveTo(left - 3, py);
      ctx.lineTo(left + plotW, py);
    }
    ctx.stroke();
    ctx.fillStyle = ink.muted;
    for (const v of lane.axis.values) {
      ctx.fillText(M.formatTick(v, lane.axis.step), left - 6, Math.min(lane.top + lane.height - 5, Math.max(lane.top + 5, lane.y(v))));
    }

    // names, one line per signal in the lane
    const members = lane.group.members;
    const firstLine = lane.top + lane.height / 2 - ((members.length - 1) * 15) / 2;
    ctx.textAlign = "left";
    members.forEach((s, k) => {
      const mid = firstLine + k * 15;
      ctx.fillStyle = seriesColor(s);
      ctx.fillRect(8, mid - 7, 3, 14);
      ctx.fillStyle = ink.primary;
      ctx.fillText(M.label(s.cfg), 17, mid, Math.max(20, left - 17 - tickW - 14));
    });

    ctx.save();
    ctx.beginPath();
    ctx.rect(left, lane.top - 3, plotW, lane.height + 6);
    ctx.clip();
    if (reference) drawReference(ctx, reference, lane);
    for (const s of members) {
      if (s.cfg.style === "bus") drawBus(ctx, ink, s, lane, x, from, to);
      else drawTrace(ctx, s, lane, x, from, to, plotW / span);
    }
    ctx.restore();
  });

  if (app.tab === "scope" && data.pre < n) drawMarker(ctx, data.pre, "trigger", ink.secondary, [4, 4]);
  const cursors = app.cursors[app.tab];
  if (cursors.a !== null) drawMarker(ctx, Math.min(cursors.a, n - 1), "A", ink.accent, []);
  if (cursors.b !== null) drawMarker(ctx, Math.min(cursors.b, n - 1), "B", ink.accent, []);

  drawHover(ctx, ink);
  updateMeasurements();
}

function updateToolbar(data) {
  const isCapture = app.tab === "scope" && !!data;
  const cursors = app.cursors[app.tab];
  $("csv").disabled = !data;
  $("zoom-in").disabled = $("zoom-out").disabled = !data || !canZoom();
  $("zoom-reset").disabled = !data || !app.view[app.tab];
  $("cursors-clear").disabled = cursors.a === null && cursors.b === null;
  $("cap-save").disabled = $("ref-set").disabled = !isCapture;
  $("ref-clear").disabled = !app.reference;
}

function updateTitle(data) {
  if (!data) {
    $("plot-title").textContent = "No data yet";
    $("plot-sub").textContent = "";
  } else if (app.tab === "scope") {
    const period = data.decimation / data.clk_freq_hz;
    $("plot-title").textContent = "Captured window";
    $("plot-sub").textContent = `${data.channels[0].length} samples at ${M.formatHz(1 / period)}, time relative to the trigger`
      + (app.reference && app.reference !== data ? ", reference capture shown faded" : "");
  } else {
    $("plot-title").textContent = "Live stream";
    $("plot-sub").textContent = `last ${data.channels[0].length} samples, one every ${data.decimation} clock${data.decimation === 1 ? "" : "s"} at best`;
  }
}

/* a vertical line across the plot at a sample, named above it */
function drawMarker(ctx, sample, name, color, dash) {
  const px = layout.x(sample);
  if (px < layout.left - 0.5 || px > layout.left + layout.plotW + 0.5) return;
  const line = Math.round(px) + 0.5;
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  ctx.setLineDash(dash);
  ctx.beginPath();
  ctx.moveTo(line, MARGIN.top - 4);
  ctx.lineTo(line, MARGIN.top + layout.plotH);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = color;
  ctx.textAlign = "center";
  ctx.textBaseline = "bottom";
  ctx.fillText(name, line, MARGIN.top - 4);
}

/* Stepped or straight-line trace of samples from..to. With more samples than
   pixels each pixel column shows its min-max span instead. */
function drawPath(ctx, values, y, x, from, to, linear, pxPerSample) {
  ctx.beginPath();
  if (pxPerSample >= 1) {
    ctx.moveTo(x(from), y(values[from]));
    for (let i = from + 1; i <= to; i++) {
      if (!linear) ctx.lineTo(x(i), y(values[i - 1]));
      ctx.lineTo(x(i), y(values[i]));
    }
  } else {
    let column = null, min = 0, max = 0, lastValue = 0;
    const flush = () => {
      ctx.lineTo(column, y(min));
      ctx.lineTo(column, y(max));
      ctx.lineTo(column, y(lastValue));
    };
    for (let i = from; i <= to; i++) {
      const px = Math.floor(x(i));
      const v = values[i];
      if (px !== column) {
        if (column === null) ctx.moveTo(px, y(v));
        else { flush(); ctx.lineTo(px, y(v)); }
        column = px;
        min = max = v;
      } else if (v < min) min = v;
      else if (v > max) max = v;
      lastValue = v;
    }
    flush();
  }
  ctx.stroke();
}

function drawTrace(ctx, signal, lane, x, from, to, pxPerSample) {
  const color = seriesColor(signal);
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.lineJoin = "round";
  drawPath(ctx, signal.values, lane.y, x, from, to, signal.cfg.style === "line", pxPerSample);
  if (pxPerSample < 8 || signal.width === 1) return;
  // zoomed in far enough to tell the samples apart: mark each one
  ctx.fillStyle = color;
  ctx.beginPath();
  for (let i = from; i <= to; i++) {
    ctx.moveTo(x(i) + 2.5, lane.y(signal.values[i]));
    ctx.arc(x(i), lane.y(signal.values[i]), 2.5, 0, 2 * Math.PI);
  }
  ctx.fill();
}

/* the value a bus band is labelled with */
function busText(signal, raw) {
  if (M.hasNames(signal.cfg)) return M.namedText(raw, signal.width, signal.cfg);
  if (signal.cfg.format === "dec") return M.formatValue(M.scaleValue(raw, signal.width, signal.cfg));
  return M.formatRaw(raw, signal.width, signal.cfg.format);
}

/* logic-analyzer style: a band per stretch of equal values, with the value written inside when it fits */
function drawBus(ctx, ink, signal, lane, x, from, to) {
  const color = seriesColor(signal);
  const yTop = lane.top + 2, yBottom = lane.top + lane.height - 2, mid = (yTop + yBottom) / 2;
  const runs = M.busRuns(signal.raw, from, to);
  ctx.beginPath();
  for (const run of runs) {
    const xa = x(run.start), xb = x(run.end + 1);
    const slant = Math.min(3, (xb - xa) / 2);
    ctx.moveTo(xa, mid);
    ctx.lineTo(xa + slant, yTop);
    ctx.lineTo(xb - slant, yTop);
    ctx.lineTo(xb, mid);
    ctx.lineTo(xb - slant, yBottom);
    ctx.lineTo(xa + slant, yBottom);
    ctx.closePath();
  }
  ctx.globalAlpha = 0.15;
  ctx.fillStyle = color;
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.strokeStyle = color;
  ctx.lineWidth = 1.5;
  ctx.lineJoin = "round";
  ctx.stroke();

  ctx.fillStyle = ink.primary;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const run of runs) {
    const xa = Math.max(x(run.start), layout.left), xb = Math.min(x(run.end + 1), layout.left + layout.plotW);
    if (xb - xa < 14) continue;
    const text = busText(signal, run.value);
    if (ctx.measureText(text).width + 8 <= xb - xa) ctx.fillText(text, (xa + xb) / 2, mid);
  }
}

/* an earlier capture behind the current one, lined up on the trigger and on real time */
function drawReference(ctx, reference, lane) {
  const { data, view, plotW } = layout;
  const ratio = (reference.decimation / reference.clk_freq_hz) / (data.decimation / data.clk_freq_hz); // current samples per reference sample
  const count = reference.channels[0].length;
  const xr = (j) => layout.x(data.pre + (j - reference.pre) * ratio);
  const from = Math.max(0, Math.floor(reference.pre + (view.start - data.pre) / ratio) - 1);
  const to = Math.min(count - 1, Math.ceil(reference.pre + (view.end - data.pre) / ratio) + 1);
  if (from > to) return;
  const signals = derive(reference).signals;
  ctx.globalAlpha = 0.35;
  ctx.lineWidth = 1.5;
  for (const s of lane.group.members) {
    const match = signals.find((r) => r.base === s.base && r.width === s.width);
    if (!match || s.cfg.style === "bus") continue;
    ctx.strokeStyle = seriesColor(s);
    drawPath(ctx, match.values, lane.y, xr, from, to, s.cfg.style === "line", (plotW / (view.end - view.start)) * ratio);
  }
  ctx.globalAlpha = 1;
}

function drawXAxis(ctx, ink, height) {
  const { data, n, x, view, left, plotH } = layout;
  const isCapture = app.tab === "scope";
  // axis value of sample i: seconds from the trigger for a capture, samples back from the newest for a stream
  const period = isCapture ? data.decimation / data.clk_freq_hz : 1;
  const origin = isCapture ? data.pre : n - 1;
  const first = (view.start - origin) * period, last = (view.end - origin) * period;
  if (last <= first) return;
  const [scale, unitName] = isCapture ? M.timeUnit(Math.max(Math.abs(first), Math.abs(last))) : [1, "samples"];
  let step = M.niceStep(last - first, 8);
  if (!isCapture) step = Math.max(1, Math.round(step));

  ctx.textAlign = "center";
  ctx.textBaseline = "top";
  for (let k = Math.ceil(first / step - 1e-9); k * step <= last + step * 1e-9; k++) {
    const value = k * step;
    const px = Math.round(x(value / period + origin)) + 0.5;
    ctx.strokeStyle = ink.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(px, MARGIN.top);
    ctx.lineTo(px, MARGIN.top + plotH);
    ctx.stroke();
    ctx.fillStyle = ink.muted;
    ctx.fillText(M.trim(value / scale), px, MARGIN.top + plotH + 6);
  }
  ctx.textAlign = "right";
  ctx.fillStyle = ink.muted;
  ctx.fillText(unitName, left - 22, MARGIN.top + plotH + 6); // clear of a tick label on the plot's left edge
}

/* where sample i is on the X axis, in words */
function positionText(i) {
  const { data, n } = layout;
  if (app.tab === "scope") return `${M.formatSeconds(((i - data.pre) * data.decimation) / data.clk_freq_hz)} (sample ${i - data.pre})`;
  return i === n - 1 ? "newest sample" : `${n - 1 - i} samples ago`;
}

/* a signal's value at sample i as the readouts show it: scaled, with its unit, then the raw value.
   One with named values shows the name, and the raw value alone when it has none. */
function valueText(signal, i) {
  const { cfg, width } = signal;
  if (M.hasNames(cfg)) {
    const name = M.valueName(cfg, signal.raw[i]), raw = M.formatRaw(signal.raw[i], width, cfg.format);
    return name === undefined ? raw : `${name} (${raw})`;
  }
  let text = M.formatValue(signal.values[i]) + (cfg.unit ? ` ${cfg.unit}` : "");
  if (width > 1 && !(cfg.format === "dec" && M.isIdentity(width, cfg))) text += ` (${M.formatRaw(signal.raw[i], width, cfg.format)})`;
  return text;
}

function drawHover(ctx, ink) {
  const tooltip = $("tooltip");
  if (app.hover === null || !layout) { tooltip.hidden = true; return; }
  const { x, lanes, n, left, plotW, plotH } = layout;
  const i = Math.min(app.hover, n - 1);
  const px = x(i);
  if (px < left - 0.5 || px > left + plotW + 0.5) { tooltip.hidden = true; return; }

  ctx.strokeStyle = ink.muted;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(Math.round(px) + 0.5, MARGIN.top);
  ctx.lineTo(Math.round(px) + 0.5, MARGIN.top + plotH);
  ctx.stroke();

  tooltip.replaceChildren();
  const head = document.createElement("div");
  head.className = "tt-head";
  head.textContent = positionText(i);
  tooltip.append(head);
  for (const lane of lanes) {
    for (const s of lane.group.members) {
      if (s.bit !== undefined) continue; // a bit lane: its signal is already in the readout
      const py = lane.y(s.values[i]);
      if (s.cfg.style !== "bus" && py >= lane.top - 3 && py <= lane.top + lane.height + 3) {
        ctx.beginPath();
        ctx.arc(px, py, 4, 0, 2 * Math.PI);
        ctx.fillStyle = seriesColor(s);
        ctx.fill();
        ctx.strokeStyle = ink.surface;
        ctx.lineWidth = 2;
        ctx.stroke();
      }
      const row = document.createElement("div");
      row.className = "tt-row";
      const key = document.createElement("span");
      key.className = "tt-key";
      key.style.background = `var(--series-${s.base + 1})`;
      const value = document.createElement("span");
      value.className = "tt-value";
      value.textContent = valueText(s, i);
      const name = document.createElement("span");
      name.className = "tt-name";
      name.textContent = s.cfg.name;
      row.append(key, value, name);
      tooltip.append(row);
    }
  }
  tooltip.hidden = false;
  const wrap = $("plot-wrap").getBoundingClientRect();
  const leftEdge = px + 14 + tooltip.offsetWidth > wrap.width ? px - 14 - tooltip.offsetWidth : px + 14;
  tooltip.style.left = `${Math.max(0, leftEdge)}px`;
  tooltip.style.top = `${MARGIN.top + 4}px`;
}

/* ---- measurements: statistics of the visible window and the two cursors ---- */

let measureKey = null;

function updateMeasurements() {
  const cursors = app.cursors[app.tab];
  const key = layout ? [dataRev, configRev, app.tab, layout.first, layout.last, cursors.a, cursors.b].join("|") : "";
  if (key === measureKey) return; // draw() runs on every pointer move; the table only changes with these
  measureKey = key;
  $("measure").hidden = !layout;
  $("measure-head").textContent = "";
  if (!layout) return;

  const { data, n, first, last, lanes } = layout;
  const a = cursors.a === null ? null : Math.min(cursors.a, n - 1);
  const b = cursors.b === null ? null : Math.min(cursors.b, n - 1);
  const parts = [`Statistics over the ${last - first + 1} visible samples.`];
  if (a !== null) parts.push(`A: ${positionText(a)}.`);
  if (b !== null) parts.push(`B: ${positionText(b)}.`);
  if (a !== null && b !== null) {
    if (app.tab === "scope") {
      const dt = ((b - a) * data.decimation) / data.clk_freq_hz;
      parts.push(`B - A: ${M.formatSeconds(dt)}${dt ? `, 1/Δt ${M.formatHz(1 / Math.abs(dt))}` : ""}.`);
    } else {
      parts.push(`B - A: ${b - a} samples.`);
    }
  }
  $("measure-head").textContent = parts.join(" ");

  const number = (v) => M.formatValue(Number(v.toPrecision(6)));
  const body = $("measure").tBodies[0];
  body.replaceChildren();
  for (const lane of lanes) {
    for (const s of lane.group.members) {
      if (s.bit !== undefined) continue; // a bit lane: its signal has a row
      const st = M.stats(s.values, first, last);
      const named = M.hasNames(s.cfg); // a state: min, max and mean of it mean nothing
      const row = body.insertRow();
      const name = row.insertCell();
      const swatch = document.createElement("span");
      swatch.className = "swatch";
      swatch.style.background = `var(--series-${s.base + 1})`;
      name.append(swatch, M.label(s.cfg));
      const cells = [...(named ? ["—", "—", "—", "—"] : [number(st.min), number(st.max), number(st.mean), number(st.pkpk)]),
                     a === null ? "" : valueText(s, a), b === null ? "" : valueText(s, b),
                     a === null || b === null ? "" : named ? "—" : number(s.values[b] - s.values[a])];
      for (const text of cells) row.insertCell().textContent = text;
    }
  }
}

/* ---- zoom, pan and cursors ---- */

let drag = null; // pointer held down on the plot: { kind: "pan" | "a" | "b", x, view, moved }
let lastClick = { time: 0, key: "a", previous: null }; // lets a double click undo the cursor its first click placed

const plotX = (event) => event.clientX - $("plot").getBoundingClientRect().left;
const sampleNear = (px) => Math.max(0, Math.min(layout.n - 1, Math.round(layout.sampleAt(px))));

function zoomBy(factor, anchor) {
  if (!layout || !canZoom()) return;
  const { view, n } = layout;
  const zoomed = M.zoomView(view, n, factor, anchor === undefined ? (view.start + view.end) / 2 : anchor);
  const whole = M.fullView(n);
  app.view[app.tab] = zoomed.end - zoomed.start >= whole.end ? null : zoomed;
  draw();
}

function resetZoom() {
  app.view[app.tab] = null;
  draw();
}

function clearCursors() {
  app.cursors[app.tab] = { a: null, b: null };
  draw();
}

function pointerDown(event) {
  if (!layout || event.button !== 0) return;
  const px = plotX(event);
  const cursors = app.cursors[app.tab];
  const grabbed = ["a", "b"].find((k) => cursors[k] !== null && Math.abs(layout.x(cursors[k]) - px) <= 6);
  drag = { kind: grabbed || "pan", x: px, view: layout.view, moved: false };
  try { $("plot").setPointerCapture(event.pointerId); } catch { /* not a live pointer */ }
}

function pointerMove(event) {
  if (!layout) return;
  const px = plotX(event);
  if (drag) {
    if (Math.abs(px - drag.x) > 3) drag.moved = true;
    if (drag.moved && drag.kind !== "pan") app.cursors[app.tab][drag.kind] = sampleNear(px);
    else if (drag.moved && canZoom() && app.view[app.tab]) {
      const samples = ((drag.x - px) / layout.plotW) * (drag.view.end - drag.view.start);
      app.view[app.tab] = M.panView(drag.view, layout.n, samples);
    }
  }
  app.hover = sampleNear(px);
  draw();
}

function pointerUp(event) {
  if (!drag) return;
  const wasClick = !drag.moved;
  drag = null;
  if (!layout || !wasClick) return;
  const key = event.shiftKey ? "b" : "a";
  const cursors = app.cursors[app.tab];
  const now = performance.now();
  if (now - lastClick.time > 500 || lastClick.key !== key) lastClick = { time: now, key, previous: cursors[key] };
  cursors[key] = sampleNear(plotX(event));
  draw();
}

function doubleClick() {
  app.cursors[app.tab][lastClick.key] = lastClick.previous; // the two clicks were not meant as a cursor
  resetZoom();
}

function wheel(event) {
  if (!layout) return;
  event.preventDefault();
  zoomBy(event.deltaY < 0 ? 0.8 : 1.25, layout.sampleAt(plotX(event)));
}

function keyDown(event) {
  if (!layout) return;
  const { n, data, view } = layout;
  const key = event.key.toLowerCase();
  if (key === "arrowleft" || key === "arrowright") {
    const from = app.hover === null ? (app.tab === "scope" ? Math.min(data.pre, n - 1) : n - 1) : app.hover;
    app.hover = Math.max(0, Math.min(n - 1, from + (key === "arrowleft" ? -1 : 1)));
    // keep the crosshair on screen
    if (app.hover < view.start) app.view[app.tab] = M.panView(view, n, app.hover - view.start);
    else if (app.hover > view.end) app.view[app.tab] = M.panView(view, n, app.hover - view.end);
    draw();
  } else if (key === "+" || key === "=") zoomBy(0.8, app.hover === null ? undefined : app.hover);
  else if (key === "-") zoomBy(1.25, app.hover === null ? undefined : app.hover);
  else if (key === "0") resetZoom();
  else if ((key === "a" || key === "b") && app.hover !== null) { app.cursors[app.tab][key] = app.hover; draw(); }
  else return;
  event.preventDefault();
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
$("rec-start").addEventListener("click", startRecording);
$("rec-stop").addEventListener("click", stopRecording);
$("csv").addEventListener("click", downloadCsv);
for (const id of ["pre", "post", "decim"]) $(id).addEventListener("input", updateScopeHint);
for (const id of ["panel-scope", "panel-stream"]) $(id).addEventListener("change", saveLocalConfig);

$("cfg-save").addEventListener("click", saveConfig);
$("cfg-load").addEventListener("click", loadConfig);
$("cfg-delete").addEventListener("click", deleteConfig);
$("cfg-name").addEventListener("focus", refreshConfigList);
$("cfg-open").addEventListener("click", () => $("cfg-file").click());
$("cfg-file").addEventListener("change", openConfigFile);
$("cfg-export").addEventListener("click", exportConfig);

$("zoom-in").addEventListener("click", () => zoomBy(0.5));
$("zoom-out").addEventListener("click", () => zoomBy(2));
$("zoom-reset").addEventListener("click", resetZoom);
$("cursors-clear").addEventListener("click", clearCursors);
$("ref-set").addEventListener("click", () => { app.reference = app.capture; draw(); });
$("ref-clear").addEventListener("click", () => { app.reference = null; draw(); });
$("cap-save").addEventListener("click", () => download(captureFileText(), "fpga_scope_capture.json", "application/json"));
$("cap-load").addEventListener("click", () => $("cap-file").click());
$("cap-file").addEventListener("change", loadCaptureFile);

$("plot").addEventListener("pointerdown", pointerDown);
$("plot").addEventListener("pointermove", pointerMove);
$("plot").addEventListener("pointerup", pointerUp);
$("plot").addEventListener("pointercancel", () => { drag = null; });
$("plot").addEventListener("pointerleave", () => { app.hover = null; draw(); });
$("plot").addEventListener("dblclick", doubleClick);
$("plot").addEventListener("wheel", wheel, { passive: false });
$("plot").addEventListener("keydown", keyDown);
$("plot").addEventListener("blur", () => { app.hover = null; draw(); });

new ResizeObserver(draw).observe($("plot-wrap"));
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", draw);

writeSettings();
buildControlRows();
renderControls();
refreshPorts();
refreshConfigList();
openSocket();
updateControls();
draw();
