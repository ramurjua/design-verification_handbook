/* fpga_scope display maths: everything the plot needs that does not touch the
   page (configuration, scaling, signal combining, axis ticks, zoom, statistics,
   file formats). app.js draws with it; tests/unit.html checks it. */

const ScopeMath = (() => {
  const MAX_CHANNELS = 8;
  const MAX_SIGNAL_BITS = 32; // widest signal that channels can be combined into
  const RANGES = ["full", "auto", "manual"];
  const STYLES = ["step", "line", "bus"];
  const FORMATS = ["dec", "hex", "bin"];
  const HEIGHTS = { auto: null, small: 1, medium: 2.4, large: 4, xlarge: 6 };
  const TRIGGER_TYPES = ["off", "rise", "fall", "high", "low"];
  const MAX_CONTROLS = 8; // 32-bit registers the host writes; a core has all of them or (older builds) none
  const CONTROL_KINDS = ["off", "button", "toggle", "value"];
  const MAX_CONTROL_RAW = 0xFFFFFFFF;

  /* ---- configuration ---- */

  function defaultChannel(c) {
    return {
      name: `ch${c}`, unit: "", visible: true,
      signed: false, frac: 0, gain: 1, offset: 0, // shown = signed(raw) * 2^-frac * gain + offset
      format: "hex", // how the raw value is written in the readout
      range: "full", min: 0, max: 255, // Y axis; min/max only used when range is "manual"
      style: "step", height: "auto",
      bits: false, // also show every bit of the signal in a lane of its own
      high: null, // channel that supplies the bits above this one's, null for none
      lane: null, // channel whose lane this signal is drawn in, null for its own
    };
  }

  /* A control is not used until it is given a kind:
       button  every press writes `value`
       toggle  a switch that writes 1 and 0
       value   a number typed in real units, written as its raw value */
  function defaultControl(i) {
    return {
      name: `control${i}`, kind: "off",
      value: 1, // button: the raw value a press writes
      unit: "", signed: false, frac: 0, gain: 1, offset: 0, // value: typed = signed(raw) * 2^-frac * gain + offset, as for a channel
      min: null, max: null, // value: limits on what may be typed, null for none
    };
  }

  function defaultConfig() {
    return {
      version: 1,
      channels: Array.from({ length: MAX_CHANNELS }, (_, c) => defaultChannel(c)),
      controls: Array.from({ length: MAX_CONTROLS }, (_, i) => defaultControl(i)),
      trigger: { channels: Array.from({ length: MAX_CHANNELS }, (_, c) => ({ type: c === 0 ? "rise" : "off", bit: 0 })), combine: "and" },
      window: { pre: 100, post: 300, decimation: 1 },
      stream: { decimation: 1, batch: 200, window: 2000 },
    };
  }

  const text = (v, fallback, max) => (typeof v === "string" ? v.slice(0, max) : fallback);
  const number = (v, fallback) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);
  const oneOf = (v, options, fallback) => (options.includes(v) ? v : fallback);
  const flag = (v, fallback) => (typeof v === "boolean" ? v : fallback);
  function integer(v, fallback, min, max) {
    return Number.isInteger(v) && v >= min && v <= max ? v : fallback;
  }
  const channelRef = (v, self) => (Number.isInteger(v) && v >= 0 && v < MAX_CHANNELS && v !== self ? v : null);
  const limit = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

  /* a per-channel list in a file: an array in channel order, or an object keyed by channel number */
  const perChannel = (v) => (v && typeof v === "object" ? v : []);

  /* Any value (a parsed file, old browser storage, garbage) to a complete, valid configuration.
     Whatever is missing or unusable gets its default, so a file only needs what it changes. */
  function normalizeConfig(raw) {
    const config = defaultConfig();
    if (!raw || typeof raw !== "object") return config;

    const channels = perChannel(raw.channels);
    config.channels.forEach((d, c) => {
      const r = channels[c];
      if (!r || typeof r !== "object") return;
      d.name = text(r.name, d.name, 24).trim() || d.name;
      d.unit = text(r.unit, d.unit, 12).trim();
      d.visible = flag(r.visible, d.visible);
      d.signed = flag(r.signed, d.signed);
      d.frac = integer(r.frac, d.frac, 0, MAX_SIGNAL_BITS);
      d.gain = number(r.gain, d.gain);
      d.offset = number(r.offset, d.offset);
      d.format = oneOf(r.format, FORMATS, d.format);
      d.range = oneOf(r.range, RANGES, d.range);
      d.min = number(r.min, d.min);
      d.max = number(r.max, d.max);
      d.style = oneOf(r.style, STYLES, d.style);
      d.height = oneOf(r.height, Object.keys(HEIGHTS), d.height);
      d.bits = flag(r.bits, d.bits);
      d.high = channelRef(r.high, c);
      d.lane = channelRef(r.lane, c);
    });

    const controls = perChannel(raw.controls);
    config.controls.forEach((d, i) => {
      const r = controls[i];
      if (!r || typeof r !== "object") return;
      d.name = text(r.name, d.name, 24).trim() || d.name;
      d.kind = oneOf(r.kind, CONTROL_KINDS, d.kind);
      d.value = integer(r.value, d.value, 0, MAX_CONTROL_RAW);
      d.unit = text(r.unit, d.unit, 12).trim();
      d.signed = flag(r.signed, d.signed);
      d.frac = integer(r.frac, d.frac, 0, MAX_SIGNAL_BITS);
      d.gain = number(r.gain, d.gain) || d.gain; // a gain of 0 could not be undone to find the raw value
      d.offset = number(r.offset, d.offset);
      d.min = limit(r.min);
      d.max = limit(r.max);
    });

    const trigger = raw.trigger && typeof raw.trigger === "object" ? raw.trigger : {};
    const triggerChannels = perChannel(trigger.channels);
    config.trigger.channels.forEach((d, c) => {
      const r = triggerChannels[c];
      if (!r || typeof r !== "object") return;
      d.type = oneOf(r.type, TRIGGER_TYPES, d.type);
      d.bit = integer(r.bit, d.bit, 0, 15);
    });
    config.trigger.combine = oneOf(trigger.combine, ["and", "or"], config.trigger.combine);

    const win = raw.window && typeof raw.window === "object" ? raw.window : {};
    config.window.pre = integer(win.pre, config.window.pre, 0, 0xFFFF);
    config.window.post = integer(win.post, config.window.post, 0, 0xFFFF);
    config.window.decimation = integer(win.decimation, config.window.decimation, 1, 0xFFFF);

    const stream = raw.stream && typeof raw.stream === "object" ? raw.stream : {};
    config.stream.decimation = integer(stream.decimation, config.stream.decimation, 1, 0xFFFF);
    config.stream.batch = integer(stream.batch, config.stream.batch, 1, 10000);
    config.stream.window = integer(stream.window, config.stream.window, 10, 100000);
    return config;
  }

  /* The settings of a hand-written configuration that normalizeConfig did not take as written
     (unknown name, wrong type, out of range), as paths like "channels.3.gain". */
  function configProblems(raw, normalized = normalizeConfig(raw)) {
    const problems = [];
    const walk = (given, taken, path) => {
      if (given && typeof given === "object" && taken && typeof taken === "object") {
        for (const key of Object.keys(given)) walk(given[key], taken[key], path ? `${path}.${key}` : key);
      } else if (given !== taken) problems.push(path);
    };
    walk(raw, normalized, "");
    return problems;
  }

  /* ---- signals: one or more channels shown as one value ---- */

  /* The signals to show for a core with these channel widths. A channel named as
     another's `high` becomes that signal's upper bits and has no trace of its own.
     Links that are impossible (missing channel, already taken, a loop, more than
     MAX_SIGNAL_BITS in total) are ignored and the channel stays a signal by itself. */
  function buildSignals(widths, channels) {
    const count = widths.length;
    const owner = new Array(count).fill(null); // owner[h] = channel whose upper bits h is
    for (let c = 0; c < count; c++) {
      const h = channels[c].high;
      if (Number.isInteger(h) && h >= 0 && h < count && h !== c && owner[h] === null) owner[h] = c;
    }

    const used = new Array(count).fill(false);
    const signals = [];
    const follow = (base) => {
      const parts = [base];
      let width = widths[base];
      used[base] = true;
      for (let h = channels[base].high; ; h = channels[h].high) {
        if (!Number.isInteger(h) || h < 0 || h >= count || used[h]) break;
        if (owner[h] !== parts[parts.length - 1] || width + widths[h] > MAX_SIGNAL_BITS) break;
        parts.push(h);
        width += widths[h];
        used[h] = true;
      }
      signals.push({ base, parts, width, cfg: channels[base] });
    };
    for (let c = 0; c < count; c++) if (owner[c] === null) follow(c);
    for (let c = 0; c < count; c++) if (!used[c]) signals.push({ base: c, parts: [c], width: widths[c], cfg: channels[c] });
    return signals.sort((a, b) => a.base - b.base);
  }

  /* Unsigned value of a signal at every sample; parts[0] is the least significant channel. */
  function rawValues(signal, widths, channels) {
    const n = channels[signal.parts[0]].length;
    const out = new Array(n).fill(0);
    let weight = 1;
    for (const part of signal.parts) {
      const values = channels[part];
      for (let i = 0; i < n; i++) out[i] += values[i] * weight;
      weight *= 2 ** widths[part];
    }
    return out;
  }

  function toSigned(raw, width) {
    return raw >= 2 ** (width - 1) ? raw - 2 ** width : raw;
  }

  /* a 1-bit signal has no sign bit to spare */
  const isSigned = (width, cfg) => cfg.signed && width > 1;

  function scaleValue(raw, width, cfg) {
    return (isSigned(width, cfg) ? toSigned(raw, width) : raw) * 2 ** -cfg.frac * cfg.gain + cfg.offset;
  }

  function scaleValues(raw, width, cfg) {
    return raw.map((v) => scaleValue(v, width, cfg));
  }

  const isIdentity = (width, cfg) => !isSigned(width, cfg) && cfg.frac === 0 && cfg.gain === 1 && cfg.offset === 0;

  /* ---- controls: the same scaling, the other way round ---- */

  /* The raw 32 bits to write for a number typed into a "value" control: { raw },
     or { error } saying why it cannot be sent. A negative value goes out in
     two's complement, which the FPGA reads right whatever width it uses. */
  function controlRaw(cfg, shown) {
    if (typeof shown !== "number" || !Number.isFinite(shown)) return { error: "not a number" };
    if (cfg.min !== null && shown < cfg.min) return { error: `below the smallest allowed, ${cfg.min}` };
    if (cfg.max !== null && shown > cfg.max) return { error: `above the largest allowed, ${cfg.max}` };
    const raw = Math.round(((shown - cfg.offset) / cfg.gain) * 2 ** cfg.frac);
    if (!Number.isFinite(raw)) return { error: "not a number" };
    if (raw < 0 && !cfg.signed) return { error: "negative, and this control is not signed" };
    if (raw < -(2 ** 31) || raw > (cfg.signed ? 2 ** 31 - 1 : MAX_CONTROL_RAW)) return { error: "does not fit 32 bits" };
    return { raw: raw >>> 0 };
  }

  /* what a raw value read back from the core means in the control's units */
  const controlShown = (cfg, raw) => scaleValue(raw, 32, cfg);

  /* ---- Y axis ---- */

  const widen = (min, max) => (max > min ? [min, max] : [min - 1, max + 1]);

  /* what the whole raw range of the signal maps to */
  function fullRange(width, cfg) {
    const signed = isSigned(width, cfg);
    const a = scaleValue(signed ? 2 ** (width - 1) : 0, width, cfg);
    const b = scaleValue(signed ? 2 ** (width - 1) - 1 : 2 ** width - 1, width, cfg);
    return widen(Math.min(a, b), Math.max(a, b));
  }

  /* the samples first..last of every list, with a little headroom */
  function autoRange(lists, first, last) {
    let min = Infinity, max = -Infinity;
    for (const values of lists) {
      for (let i = first; i <= last; i++) {
        if (values[i] < min) min = values[i];
        if (values[i] > max) max = values[i];
      }
    }
    if (min > max) return [0, 1];
    if (min === max) return widen(min, max);
    const pad = (max - min) * 0.05;
    return [min - pad, max + pad];
  }

  /* Y range of a lane (see laneGroups), set by its host: every member shares the axis */
  function laneRange(group, first, last) {
    const cfg = group.host.cfg;
    if (cfg.range === "manual" && cfg.max > cfg.min) return [cfg.min, cfg.max];
    if (cfg.range === "auto") return autoRange(group.members.map((s) => s.values), first, last);
    const ranges = group.members.map((s) => fullRange(s.width, s.cfg));
    return [Math.min(...ranges.map((r) => r[0])), Math.max(...ranges.map((r) => r[1]))];
  }

  function niceStep(span, targetTicks) {
    const raw = span / targetTicks;
    const power = 10 ** Math.floor(Math.log10(raw));
    const f = raw / power;
    return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * power;
  }

  function ticks(min, max, targetTicks) {
    if (!(max > min)) return { step: 1, values: [] };
    const step = niceStep(max - min, Math.max(1, targetTicks));
    const values = [];
    for (let k = Math.ceil(min / step - 1e-9); k * step <= max + step * 1e-9; k++) values.push(Number((k * step).toPrecision(12)));
    return { step, values };
  }

  /* ---- text ---- */

  function trim(value) { return String(Number(value.toPrecision(4))); }

  /* a tick label, with the decimals its step calls for */
  function formatTick(value, step) {
    if (value !== 0 && (Math.abs(value) >= 1e7 || Math.abs(value) < 1e-4)) return value.toExponential(2);
    return value.toFixed(Math.min(6, Math.max(0, -Math.floor(Math.log10(step) + 1e-9))));
  }

  function formatValue(value) {
    if (Number.isInteger(value) && Math.abs(value) < 1e15) return String(value);
    return String(Number(value.toPrecision(6)));
  }

  function formatRaw(raw, width, format) {
    if (format === "hex") return "0x" + raw.toString(16).toUpperCase().padStart(Math.ceil(width / 4), "0");
    if (format === "bin") return "0b" + raw.toString(2).padStart(width, "0");
    return String(raw);
  }

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

  const label = (cfg) => (cfg.unit ? `${cfg.name} [${cfg.unit}]` : cfg.name);

  /* ---- X view: the visible span, in (fractional) sample indexes ---- */

  const fullView = (n) => ({ start: 0, end: Math.max(1, n - 1) });

  function clampView(view, n) {
    const whole = fullView(n);
    const span = Math.min(view.end - view.start, whole.end);
    const start = Math.min(Math.max(view.start, 0), whole.end - span);
    return { start, end: start + span };
  }

  /* factor < 1 zooms in; the sample at `anchor` stays where it is on screen */
  function zoomView(view, n, factor, anchor) {
    const whole = fullView(n);
    const span = view.end - view.start;
    const newSpan = Math.min(whole.end, Math.max(Math.min(4, whole.end), span * factor));
    const start = anchor - ((anchor - view.start) * newSpan) / span;
    return clampView({ start, end: start + newSpan }, n);
  }

  function panView(view, n, samples) {
    return clampView({ start: view.start + samples, end: view.end + samples }, n);
  }

  /* first and last sample index inside the view */
  function visibleSamples(view, n) {
    const first = Math.min(n - 1, Math.max(0, Math.ceil(view.start - 1e-9)));
    const last = Math.max(first, Math.min(n - 1, Math.floor(view.end + 1e-9)));
    return [first, last];
  }

  /* ---- measurements ---- */

  function stats(values, first, last) {
    let min = Infinity, max = -Infinity, sum = 0;
    for (let i = first; i <= last; i++) {
      if (values[i] < min) min = values[i];
      if (values[i] > max) max = values[i];
      sum += values[i];
    }
    return { min, max, mean: sum / (last - first + 1), pkpk: max - min };
  }

  /* stretches of samples first..last that hold one value: [{ start, end, value }], end inclusive */
  function busRuns(values, first, last) {
    const runs = [];
    let start = first;
    for (let i = first + 1; i <= last + 1; i++) {
      if (i > last || values[i] !== values[start]) {
        runs.push({ start, end: i - 1, value: values[start] });
        start = i;
      }
    }
    return runs;
  }

  /* ---- lanes ---- */

  /* One 1-bit signal per bit of a signal that has its raw values, most significant first.
     They are marked with `bit` and `parent`, and only exist to be drawn. */
  function bitSignals(signal) {
    const out = [];
    for (let bit = signal.width - 1; bit >= 0; bit--) {
      const raw = signal.raw.map((v) => Math.floor(v / 2 ** bit) % 2);
      const cfg = { ...defaultChannel(signal.base), name: `${signal.cfg.name}[${bit}]`, format: "dec" };
      out.push({ base: signal.base, parts: signal.parts, width: 1, cfg, raw, values: raw, bit, parent: signal });
    }
    return out;
  }

  /* Which visible signals share a lane: [{ host, members }], host first in members.
     A `lane` that points at a hidden or combined-away channel, or round in a loop, is ignored.
     A signal with `bits` set is followed by one lane for each of its bits. */
  function laneGroups(signals) {
    const visible = signals.filter((s) => s.cfg.visible);
    const byBase = new Map(visible.map((s) => [s.base, s]));
    const hostOf = (signal) => {
      const seen = new Set([signal.base]);
      for (let current = signal; ;) {
        const target = current.cfg.lane === null ? undefined : byBase.get(current.cfg.lane);
        if (!target) return current;
        if (seen.has(target.base)) return signal;
        seen.add(target.base);
        current = target;
      }
    };
    const groups = new Map();
    for (const signal of visible) {
      const host = hostOf(signal);
      if (!groups.has(host.base)) groups.set(host.base, { host, members: [host] });
      if (signal !== host) groups.get(host.base).members.push(signal);
    }
    const lanes = [];
    for (const group of [...groups.values()].sort((a, b) => a.host.base - b.host.base)) {
      lanes.push(group);
      for (const signal of group.members) {
        if (signal.cfg.bits && signal.width > 1) for (const bit of bitSignals(signal)) lanes.push({ host: bit, members: [bit] });
      }
    }
    return lanes;
  }

  function laneWeight(group) {
    const chosen = HEIGHTS[group.host.cfg.height];
    if (chosen) return chosen;
    return group.members.every((s) => s.width === 1 || s.cfg.style === "bus") ? HEIGHTS.small : HEIGHTS.medium; // no Y axis to make room for
  }

  /* ---- capture window ---- */

  /* Whether the core captures this window correctly, the same rule as
     protocol.py's capture_window_fits. maxSamples (from GET_INFO) is one short
     of the buffer: a window of the whole buffer comes back with its oldest
     sample overwritten by the newest. The trigger sample is written even with
     post 0, so that still costs one sample. */
  function captureWindowFits(pre, post, maxSamples) {
    return pre + post >= 1 && pre + Math.max(post, 1) <= maxSamples;
  }

  /* ---- files ---- */

  const csvCell = (s) => (/[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);

  /* columns: [{ name, values }]. A capture (pre given) also gets the time relative to the trigger. */
  function csvText(columns, { pre = null, period = 1 } = {}) {
    const isCapture = pre !== null;
    const lines = [(isCapture ? ["sample", "time_s"] : ["sample"]).concat(columns.map((c) => csvCell(c.name))).join(",")];
    const n = columns.length ? columns[0].values.length : 0;
    for (let i = 0; i < n; i++) {
      const head = isCapture ? [i - pre, ((i - pre) * period).toExponential(6)] : [i];
      lines.push(head.concat(columns.map((c) => c.values[i])).join(","));
    }
    return lines.join("\n") + "\n";
  }

  function captureFile(capture, config) {
    return {
      fpga_scope_capture: 1,
      widths: capture.widths, clk_freq_hz: capture.clk_freq_hz,
      pre: capture.pre, decimation: capture.decimation,
      channels: capture.channels,
      config,
    };
  }

  /* the reverse of captureFile, refusing anything that could not be drawn */
  function parseCaptureFile(file) {
    const bad = (why) => { throw new Error(`Not a usable fpga_scope capture file: ${why}`); };
    if (!file || typeof file !== "object" || file.fpga_scope_capture !== 1) bad("wrong file type or version");
    const { widths, channels } = file;
    if (!Array.isArray(widths) || !widths.length || widths.length > MAX_CHANNELS) bad("channel widths missing");
    if (!widths.every((w) => Number.isInteger(w) && w >= 1 && w <= 8)) bad("channel widths out of range");
    if (!Array.isArray(channels) || channels.length !== widths.length) bad("channel count does not match the widths");
    const n = Array.isArray(channels[0]) ? channels[0].length : 0;
    if (!n) bad("no samples");
    channels.forEach((values, c) => {
      if (!Array.isArray(values) || values.length !== n) bad(`channel ${c} has a different length`);
      if (!values.every((v) => Number.isInteger(v) && v >= 0 && v < 2 ** widths[c])) bad(`channel ${c} has values outside its width`);
    });
    if (!Number.isInteger(file.pre) || file.pre < 0 || file.pre > n) bad("trigger position out of range");
    if (!Number.isInteger(file.decimation) || file.decimation < 1) bad("decimation out of range");
    if (!(typeof file.clk_freq_hz === "number" && file.clk_freq_hz > 0)) bad("clock frequency missing");
    return {
      capture: { widths, channels, pre: file.pre, decimation: file.decimation, clk_freq_hz: file.clk_freq_hz },
      config: file.config === undefined ? null : normalizeConfig(file.config),
    };
  }

  return {
    MAX_CHANNELS, MAX_SIGNAL_BITS, RANGES, STYLES, FORMATS, HEIGHTS, TRIGGER_TYPES,
    MAX_CONTROLS, CONTROL_KINDS, MAX_CONTROL_RAW,
    defaultChannel, defaultControl, defaultConfig, normalizeConfig, configProblems,
    controlRaw, controlShown,
    buildSignals, rawValues, toSigned, isSigned, scaleValue, scaleValues, isIdentity,
    fullRange, autoRange, laneRange, niceStep, ticks,
    trim, formatTick, formatValue, formatRaw, formatHz, timeUnit, formatSeconds, label,
    fullView, clampView, zoomView, panView, visibleSamples,
    stats, busRuns, bitSignals, laneGroups, laneWeight,
    captureWindowFits,
    csvText, captureFile, parseCaptureFile,
  };
})();
