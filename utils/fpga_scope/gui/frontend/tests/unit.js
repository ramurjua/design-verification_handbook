/* Tests of scope_math.js. See harness.js for how they are run. */

(() => {
  const M = ScopeMath;
  const { test, ok, eq, near, throws } = Harness;

  /* a channel configuration that differs from the default in the given fields */
  const channel = (c, fields = {}) => ({ ...M.defaultChannel(c), ...fields });
  const channels = (overrides = {}) => Array.from({ length: 8 }, (_, c) => channel(c, overrides[c]));
  const bases = (signals) => signals.map((s) => s.base);

  /* ---- signed values and scaling ---- */

  test("toSigned reads the top bit as the sign", () => {
    eq(M.toSigned(0, 8), 0);
    eq(M.toSigned(127, 8), 127);
    eq(M.toSigned(128, 8), -128);
    eq(M.toSigned(255, 8), -1);
    eq(M.toSigned(7, 4), 7);
    eq(M.toSigned(8, 4), -8);
    eq(M.toSigned(0x8000, 16), -32768);
    eq(M.toSigned(0xFFFFFFFF, 32), -1);
  });

  test("an unsigned channel is shown as it is", () => {
    const cfg = channel(0);
    eq(M.scaleValue(200, 8, cfg), 200);
    ok(M.isIdentity(8, cfg), "default configuration is the identity");
  });

  test("signed, fraction bits, gain and offset are applied in that order", () => {
    eq(M.scaleValue(200, 8, channel(0, { signed: true })), -56);
    eq(M.scaleValue(200, 8, channel(0, { frac: 4 })), 12.5);
    eq(M.scaleValue(200, 8, channel(0, { gain: 0.5, offset: 10 })), 110);
    eq(M.scaleValue(0xF0, 8, channel(0, { signed: true, frac: 4, gain: 2, offset: 1 })), -1); // -16 / 16 * 2 + 1
    ok(!M.isIdentity(8, channel(0, { signed: true })), "signed is not the identity");
    ok(!M.isIdentity(8, channel(0, { offset: 1 })), "an offset is not the identity");
  });

  test("a 1-bit signal cannot be signed", () => {
    const cfg = channel(0, { signed: true });
    eq(M.scaleValue(1, 1, cfg), 1);
    ok(M.isIdentity(1, cfg), "still the identity");
    eq(M.fullRange(1, cfg), [0, 1]);
  });

  test("scaleValues maps every sample", () => {
    eq(M.scaleValues([0, 127, 128, 255], 8, channel(0, { signed: true })), [0, 127, -128, -1]);
  });

  /* ---- combining channels ---- */

  test("by default every channel is its own signal", () => {
    const signals = M.buildSignals([1, 1, 4, 8], channels());
    eq(bases(signals), [0, 1, 2, 3]);
    eq(signals.map((s) => s.width), [1, 1, 4, 8]);
    eq(signals.map((s) => s.parts), [[0], [1], [2], [3]]);
  });

  test("a channel named as upper bits joins the signal and loses its own trace", () => {
    const signals = M.buildSignals([8, 8, 1], channels({ 0: { high: 1 } }));
    eq(bases(signals), [0, 2]);
    eq(signals[0].parts, [0, 1]);
    eq(signals[0].width, 16);
  });

  test("the low channel does not have to be the lower numbered one", () => {
    const signals = M.buildSignals([8, 8], channels({ 1: { high: 0 } }));
    eq(bases(signals), [1]);
    eq(signals[0].parts, [1, 0]);
  });

  test("links chain into wider signals", () => {
    const signals = M.buildSignals([8, 8, 8], channels({ 0: { high: 1 }, 1: { high: 2 } }));
    eq(signals.map((s) => [s.parts, s.width]), [[[0, 1, 2], 24]]);
  });

  test("impossible links are ignored", () => {
    eq(bases(M.buildSignals([8, 8], channels({ 0: { high: 1 }, 1: { high: 0 } }))), [0, 1], "a loop");
    eq(bases(M.buildSignals([8, 8], channels({ 0: { high: 5 } }))), [0, 1], "a channel the core does not have");
    eq(bases(M.buildSignals([8, 8], channels({ 0: { high: 0 } }))), [0, 1], "itself");
    const taken = M.buildSignals([8, 8, 8], channels({ 0: { high: 2 }, 1: { high: 2 } }));
    eq(taken.map((s) => s.parts), [[0, 2], [1]], "a channel claimed twice goes to the first");
  });

  test("a signal stops growing at 32 bits", () => {
    const signals = M.buildSignals([8, 8, 8, 8, 8], channels({ 0: { high: 1 }, 1: { high: 2 }, 2: { high: 3 }, 3: { high: 4 } }));
    eq(signals.map((s) => [s.parts, s.width]), [[[0, 1, 2, 3], 32], [[4], 8]]);
  });

  test("rawValues puts the first part at the bottom", () => {
    const widths = [8, 8, 4, 8];
    const data = [[0x34, 0xFF], [0x12, 0xFF], [0xA, 0x0], [0xFF, 0x01]];
    const [word, mixed] = M.buildSignals(widths, channels({ 0: { high: 1 }, 2: { high: 3 } }));
    eq(M.rawValues(word, widths, data), [0x1234, 0xFFFF]);
    eq(M.rawValues(mixed, widths, data), [0xFFA, 0x010], "a 4-bit channel under an 8-bit one");
  });

  test("a combined 16-bit value reads as signed", () => {
    const widths = [8, 8];
    const [signal] = M.buildSignals(widths, channels({ 0: { high: 1, signed: true } }));
    const raw = M.rawValues(signal, widths, [[0xFF, 0x00, 0x18], [0xFF, 0x80, 0xFC]]);
    eq(M.scaleValues(raw, signal.width, signal.cfg), [-1, -32768, -1000]);
  });

  test("32 bits do not overflow", () => {
    const widths = [8, 8, 8, 8];
    const [signal] = M.buildSignals(widths, channels({ 0: { high: 1 }, 1: { high: 2 }, 2: { high: 3 } }));
    eq(M.rawValues(signal, widths, [[0xFF], [0xFF], [0xFF], [0xFF]]), [4294967295]);
    eq(M.scaleValue(4294967295, 32, channel(0, { signed: true })), -1);
  });

  /* ---- Y axis ---- */

  test("fullRange is what the raw range maps to", () => {
    eq(M.fullRange(8, channel(0)), [0, 255]);
    eq(M.fullRange(8, channel(0, { signed: true })), [-128, 127]);
    eq(M.fullRange(4, channel(0, { gain: 2, offset: 1 })), [1, 31]);
    eq(M.fullRange(8, channel(0, { gain: -1 })), [-255, 0], "a negative gain still gives min below max");
    eq(M.fullRange(8, channel(0, { gain: 0, offset: 5 })), [4, 6], "never an empty range");
  });

  test("autoRange fits the visible samples with some headroom", () => {
    const [min, max] = M.autoRange([[0, 10, 20, 1000]], 0, 2);
    near(min, -1);
    near(max, 21);
    eq(M.autoRange([[5, 5, 5]], 0, 2), [4, 6], "a flat signal still gets a range");
    const [low, high] = M.autoRange([[0, 10], [-30, 5]], 0, 1);
    ok(low < -30 && high > 10, "covers every signal in the lane");
  });

  test("laneRange follows the host's range setting", () => {
    const values = [10, 20, 30];
    const group = (cfg) => ({ host: { cfg, width: 8, values }, members: [{ cfg, width: 8, values }] });
    eq(M.laneRange(group(channel(0)), 0, 2), [0, 255]);
    eq(M.laneRange(group(channel(0, { range: "manual", min: -5, max: 5 })), 0, 2), [-5, 5]);
    eq(M.laneRange(group(channel(0, { range: "manual", min: 5, max: 5 })), 0, 2), [0, 255], "an empty manual range falls back to full scale");
    eq(M.laneRange(group(channel(0, { range: "auto" })), 0, 2), [9, 31]);
  });

  test("a shared lane at full scale covers every member", () => {
    const a = { cfg: channel(0), width: 8, values: [] };
    const b = { cfg: channel(1, { signed: true }), width: 8, values: [] };
    eq(M.laneRange({ host: a, members: [a, b] }, 0, 0), [-128, 255]);
  });

  test("ticks land on round values inside the range", () => {
    eq(M.ticks(0, 255, 5), { step: 50, values: [0, 50, 100, 150, 200, 250] });
    eq(M.ticks(-128, 127, 5).values, [-100, -50, 0, 50, 100]);
    eq(M.ticks(0, 1, 5).values, [0, 0.2, 0.4, 0.6, 0.8, 1], "no floating point dust");
    eq(M.ticks(3, 3, 5).values, []);
    ok(M.ticks(0, 255, 0).values.length >= 1, "a tiny lane still gets a tick");
  });

  /* ---- text ---- */

  test("formatTick uses the decimals of the step", () => {
    eq(M.formatTick(50, 50), "50");
    eq(M.formatTick(-100, 50), "-100");
    eq(M.formatTick(0.2, 0.2), "0.2");
    eq(M.formatTick(1, 0.5), "1.0");
    eq(M.formatTick(0, 0.001), "0.000");
    eq(M.formatTick(0.00002, 0.00001), "2.00e-5");
    eq(M.formatTick(20000000, 10000000), "2.00e+7");
  });

  test("formatValue keeps integers whole and trims the rest", () => {
    eq(M.formatValue(3), "3");
    eq(M.formatValue(-56), "-56");
    eq(M.formatValue(0.1 + 0.2), "0.3");
    eq(M.formatValue(-1.25), "-1.25");
    eq(M.formatValue(1234.56789), "1234.57");
  });

  test("formatRaw pads to the width of the signal", () => {
    eq(M.formatRaw(10, 8, "hex"), "0x0A");
    eq(M.formatRaw(300, 12, "hex"), "0x12C");
    eq(M.formatRaw(5, 4, "bin"), "0b0101");
    eq(M.formatRaw(200, 8, "dec"), "200");
  });

  test("frequencies and times pick a readable unit", () => {
    eq(M.formatHz(25e6), "25 MHz");
    eq(M.formatHz(115200), "115.2 kHz");
    eq(M.formatHz(50), "50 Hz");
    eq(M.formatSeconds(0.0000125), "12.5 µs");
    eq(M.formatSeconds(-0.004), "-4 ms");
    eq(M.formatSeconds(2), "2 s");
  });

  test("label adds the unit when there is one", () => {
    eq(M.label(channel(2)), "ch2");
    eq(M.label(channel(2, { name: "gyro_x", unit: "dps" })), "gyro_x [dps]");
  });

  /* ---- zoom and pan ---- */

  test("the full view spans every sample", () => {
    eq(M.fullView(400), { start: 0, end: 399 });
    eq(M.fullView(1), { start: 0, end: 1 }, "one sample still has a span");
  });

  test("zooming in keeps the anchor sample in place", () => {
    const view = M.zoomView(M.fullView(401), 401, 0.5, 100);
    near(view.end - view.start, 200, "span");
    near((100 - view.start) / (view.end - view.start), 100 / 400, "position of the anchor on screen");
  });

  test("zoom stops at 4 samples and at the whole capture", () => {
    let view = M.fullView(401);
    for (let i = 0; i < 50; i++) view = M.zoomView(view, 401, 0.5, 200);
    near(view.end - view.start, 4, "narrowest span");
    for (let i = 0; i < 50; i++) view = M.zoomView(view, 401, 2, 200);
    eq(view, { start: 0, end: 400 });
    eq(M.zoomView(M.fullView(3), 3, 0.5, 1), { start: 0, end: 2 }, "nothing to zoom into");
  });

  test("zooming near an edge stays inside the data", () => {
    const view = M.zoomView({ start: 0, end: 100 }, 401, 2, 100);
    eq(view, { start: 0, end: 200 });
  });

  test("panning stops at both ends", () => {
    const view = { start: 100, end: 200 };
    eq(M.panView(view, 401, 50), { start: 150, end: 250 });
    eq(M.panView(view, 401, -500), { start: 0, end: 100 });
    eq(M.panView(view, 401, 500), { start: 300, end: 400 });
  });

  test("visibleSamples are the whole samples inside the view", () => {
    eq(M.visibleSamples({ start: 0, end: 399 }, 400), [0, 399]);
    eq(M.visibleSamples({ start: 10.2, end: 20.8 }, 400), [11, 20]);
    eq(M.visibleSamples({ start: 10, end: 20 }, 400), [10, 20]);
    eq(M.visibleSamples({ start: 0, end: 1 }, 1), [0, 0]);
  });

  /* ---- measurements ---- */

  test("stats cover only the given window", () => {
    eq(M.stats([100, 1, 2, 3, 6, 100], 1, 4), { min: 1, max: 6, mean: 3, pkpk: 5 });
    eq(M.stats([7], 0, 0), { min: 7, max: 7, mean: 7, pkpk: 0 });
  });

  test("busRuns groups equal neighbours", () => {
    eq(M.busRuns([1, 1, 2, 2, 2, 3], 0, 5), [{ start: 0, end: 1, value: 1 }, { start: 2, end: 4, value: 2 }, { start: 5, end: 5, value: 3 }]);
    eq(M.busRuns([1, 1, 2, 2, 2, 3], 1, 3), [{ start: 1, end: 1, value: 1 }, { start: 2, end: 3, value: 2 }]);
    eq(M.busRuns([4], 0, 0), [{ start: 0, end: 0, value: 4 }]);
  });

  /* ---- lanes ---- */

  const lanesOf = (widths, overrides) => M.laneGroups(M.buildSignals(widths, channels(overrides)))
    .map((g) => g.members.map((s) => s.base));

  test("every visible signal gets a lane", () => {
    eq(lanesOf([1, 1, 4, 8]), [[0], [1], [2], [3]]);
    eq(lanesOf([1, 1, 4, 8], { 1: { visible: false } }), [[0], [2], [3]]);
    eq(lanesOf([1, 1], { 0: { visible: false }, 1: { visible: false } }), []);
  });

  test("signals can share a lane, host first", () => {
    eq(lanesOf([8, 8, 8], { 0: { lane: 2 } }), [[1], [2, 0]]);
    eq(lanesOf([8, 8, 8], { 0: { lane: 1 }, 1: { lane: 2 } }), [[2, 0, 1]], "a chain ends in one lane");
  });

  test("a lane that cannot be shared is ignored", () => {
    eq(lanesOf([8, 8], { 0: { lane: 1 }, 1: { visible: false } }), [[0]], "host hidden");
    eq(lanesOf([8, 8], { 0: { lane: 1 }, 1: { lane: 0 } }), [[0], [1]], "a loop");
    eq(lanesOf([8, 8, 8], { 0: { high: 1 }, 2: { lane: 1 } }), [[0], [2]], "host combined into another signal");
  });

  test("lane height follows the host, digital lanes are small by default", () => {
    const signals = M.buildSignals([1, 8], channels());
    const [digital, analog] = M.laneGroups(signals);
    eq(M.laneWeight(digital), M.HEIGHTS.small);
    eq(M.laneWeight(analog), M.HEIGHTS.medium);
    const [big] = M.laneGroups(M.buildSignals([1], channels({ 0: { height: "xlarge" } })));
    eq(M.laneWeight(big), M.HEIGHTS.xlarge);
    const [bus] = M.laneGroups(M.buildSignals([8], channels({ 0: { style: "bus" } })));
    eq(M.laneWeight(bus), M.HEIGHTS.small, "a bus has no Y axis to make room for");
  });

  test("a signal can be followed by one lane per bit", () => {
    const widths = [4, 1];
    const signals = M.buildSignals(widths, channels({ 0: { bits: true, name: "state" }, 1: { bits: true } }))
      .map((s) => ({ ...s, raw: M.rawValues(s, widths, [[0b1010, 0b0001], [1, 0]]) }));
    const lanes = M.laneGroups(signals);
    eq(lanes.map((g) => g.host.cfg.name), ["state", "state[3]", "state[2]", "state[1]", "state[0]", "ch1"], "a 1-bit signal is not expanded");
    eq(lanes.slice(1, 5).map((g) => g.host.values), [[1, 0], [0, 0], [1, 0], [0, 1]]);
    ok(lanes.slice(1, 5).every((g) => g.host.width === 1 && g.host.parent === signals[0]), "bit lanes are 1 bit wide and know their signal");
  });

  test("the bits of a combined signal come from all its channels", () => {
    const widths = [8, 8];
    const [signal] = M.buildSignals(widths, channels({ 0: { high: 1 } }));
    const bits = M.bitSignals({ ...signal, raw: M.rawValues(signal, widths, [[0x01], [0x80]]) });
    eq(bits.length, 16);
    eq(bits.map((b) => b.values[0]).join(""), "1000000000000001");
  });

  /* ---- configuration ---- */

  test("anything unusable normalizes to the default configuration", () => {
    for (const junk of [null, undefined, 42, "text", [], { channels: "no" }, { channels: [null, 7] }]) {
      eq(M.normalizeConfig(junk), M.defaultConfig(), JSON.stringify(junk));
    }
  });

  test("the default configuration shows raw unsigned values", () => {
    const config = M.defaultConfig();
    eq(config.channels.length, 8);
    ok(config.channels.every((c, i) => c.name === `ch${i}` && M.isIdentity(8, c) && c.visible), "channels");
    eq(config.trigger.channels.map((t) => t.type), ["rise", "off", "off", "off", "off", "off", "off", "off"]);
  });

  test("valid settings survive, invalid ones fall back one by one", () => {
    const config = M.normalizeConfig({
      channels: [
        { name: "  gyro_x ", unit: "dps", signed: true, frac: 4, gain: 0.5, offset: -3, format: "bin", range: "manual", min: -10, max: 10,
          style: "line", height: "large", bits: true, high: 1, lane: 2, visible: false },
        { name: "", signed: "yes", frac: 99, gain: "2", offset: NaN, format: "octal", range: "wide", style: "dots", height: 3, high: 1, lane: 8 },
      ],
      trigger: { channels: [{ type: "fall", bit: 3 }, { type: "sideways", bit: 16 }], combine: "or" },
      window: { pre: 7, post: -1, decimation: 0 },
      stream: { decimation: 5, batch: 20000, window: 500 },
    });
    eq(config.channels[0], { name: "gyro_x", unit: "dps", visible: false, signed: true, frac: 4, gain: 0.5, offset: -3, format: "bin",
                             range: "manual", min: -10, max: 10, style: "line", height: "large", bits: true, high: 1, lane: 2, values: {}, fields: [] });
    eq(config.channels[1], M.defaultChannel(1), "a channel cannot be its own upper bits, and the rest was junk");
    eq(config.trigger, { ...M.defaultConfig().trigger, channels: [{ type: "fall", bit: 3 }, ...M.defaultConfig().trigger.channels.slice(1)], combine: "or" });
    eq(config.window, { pre: 7, post: 300, decimation: 1 });
    eq(config.stream, { decimation: 5, batch: 200, window: 500 });
  });

  test("names and units are cut to a sane length", () => {
    const config = M.normalizeConfig({ channels: [{ name: "n".repeat(100), unit: "u".repeat(100) }] });
    eq(config.channels[0].name.length, 24);
    eq(config.channels[0].unit.length, 12);
  });

  test("a configuration survives being saved and loaded", () => {
    const config = M.normalizeConfig({ channels: [{ name: "a", gain: 1e-3, high: 3 }], window: { pre: 1, post: 2, decimation: 3 } });
    eq(M.normalizeConfig(JSON.parse(JSON.stringify(config))), config);
    ok(M.normalizeConfig(config) !== config && M.normalizeConfig(config).channels[0] !== config.channels[0], "normalizing copies");
  });

  test("a hand-written file only needs what it changes, by channel number", () => {
    const config = M.normalizeConfig({ channels: { 3: { name: "gyro_x", signed: true }, 5: { unit: "V" } }, trigger: { channels: { 3: { type: "fall" } } } });
    const expected = M.defaultConfig();
    Object.assign(expected.channels[3], { name: "gyro_x", signed: true });
    expected.channels[5].unit = "V";
    expected.trigger.channels[3].type = "fall";
    eq(config, expected);
  });

  test("configProblems names what a file asked for and did not get", () => {
    eq(M.configProblems(M.defaultConfig()), []);
    eq(M.configProblems({ channels: { 3: { name: "gyro_x", signed: true } } }), []);
    eq(M.configProblems({ channels: [{ gain: "2", range: "wide", colour: "red" }], window: { pre: -1 }, extra: 1, trigger: { channels: { 9: { type: "rise" } } } }),
       ["channels.0.gain", "channels.0.range", "channels.0.colour", "window.pre", "extra", "trigger.channels.9"]);
  });

  /* ---- named values and bit fields ---- */

  /* the Drone motor case: two state machines packed in one 8-bit channel */
  const MOTOR_STATE = {
    name: "state", style: "bus",
    fields: [
      { name: "card", bits: [7, 4], values: { 0: "IDLE", 1: "RAMP", 2: "RUN", 3: "BRAKE", 4: "FAULT" } },
      { name: "fsm", bits: [3, 0], values: { 0: "START_UP", 2: "READY", "0xA": "FAULT_MOTOR_TELEMETRY" } },
    ],
  };

  test("no named values or fields by default, and old configurations keep working", () => {
    eq(M.defaultChannel(0).values, {});
    eq(M.defaultChannel(0).fields, []);
    eq(M.defaultControl(0).values, {});
    eq(M.configProblems({ channels: { 4: { name: "state", style: "bus", format: "bin" } } }), []);
  });

  test("named values are keyed by the raw value, decimal or hex", () => {
    const cfg = M.normalizeConfig({ channels: { 3: { values: { 0: "IDLE", "0x1": "RESET", " 10 ": "READ" } } } }).channels[3];
    eq(cfg.values, { 0: "IDLE", 1: "RESET", 10: "READ" });
    eq(M.valueName(cfg, 10), "READ");
    eq(M.valueName(cfg, 5), undefined);
    eq(M.namedText(1, 4, cfg), "RESET");
    eq(M.namedText(5, 4, cfg), "0x5", "a value without a name is the number, in the raw format");
    eq(M.namedText(5, 4, { ...cfg, format: "bin" }), "0b0101");
    ok(M.hasNames(cfg) && !M.hasNames(M.defaultChannel(0)));
  });

  test("unusable named values are left out and reported", () => {
    const raw = { channels: { 3: { values: { "-1": "NEG", x: "X", 2: 7, 3: "", 4: "a".repeat(30), 5: "OK" } } } };
    const cfg = M.normalizeConfig(raw).channels[3];
    eq(cfg.values, { 4: "a".repeat(24), 5: "OK" });
    eq(M.configProblems(raw), ["channels.3.values.2", "channels.3.values.3", "channels.3.values.4", "channels.3.values.-1", "channels.3.values.x"]);
    eq(M.normalizeConfig({ channels: { 3: { values: ["A", "B"] } } }).channels[3].values, {}, "a list is not a map");
  });

  test("bit fields: [msb, lsb] or one bit, and the ones without usable bits are kept but not drawn", () => {
    const raw = { channels: { 6: { fields: [{ name: "card", bits: [7, 4] }, { bits: 3 }, { name: "bad", bits: [2, 5] }, { name: "none" }] } } };
    const cfg = M.normalizeConfig(raw).channels[6];
    eq(cfg.fields, [{ name: "card", bits: [7, 4], values: {} }, { name: "f1", bits: [3, 3], values: {} },
                    { name: "bad", bits: null, values: {} }, { name: "none", bits: null, values: {} }]);
    eq(M.configProblems(raw), ["channels.6.fields.2.bits", "channels.6.fields.3.bits"]);
    ok(M.hasFields(cfg) && !M.hasFields({ fields: [{ bits: null }] }));
    eq(M.normalizeConfig({ channels: { 0: { fields: Array.from({ length: 10 }, () => ({ bits: 0 })) } } }).channels[0].fields.length, M.MAX_FIELDS);
    eq(M.configProblems({ channels: [{ fields: [{ bits: 32 }] }] }), ["channels.0.fields.0.bits"]);
  });

  test("named values and fields survive being saved and loaded, with nothing to report", () => {
    const config = M.normalizeConfig({ channels: { 6: MOTOR_STATE }, controls: { 0: { kind: "value", values: { 0: "OFF", 3: "AUTO" } } } });
    eq(M.normalizeConfig(JSON.parse(JSON.stringify(config))), config);
    eq(M.configProblems({ channels: { 6: MOTOR_STATE } }), []);
    eq(M.configProblems(config), []);
    eq(config.controls[0].values, { 0: "OFF", 3: "AUTO" });
  });

  test("a drop-down control: a kind of its own, with entries typed as value=name pairs", () => {
    ok(M.CONTROL_KINDS.includes("select"));
    const cfg = M.normalizeConfig({ controls: { 2: { name: "motor", kind: "select", values: { 0: "MOTOR 0", 1: "MOTOR 1" } } } }).controls[2];
    eq([cfg.kind, cfg.values], ["select", { 0: "MOTOR 0", 1: "MOTOR 1" }]);
    eq(M.valueListText(cfg.values), "0=MOTOR 0; 1=MOTOR 1");
    eq(M.parseValueList("0=MOTOR 0; 1=MOTOR 1"), cfg.values, "and back");
    eq(M.parseValueList(" 0x10 = A ; ; 2=B=C; "), { 2: "B=C", 16: "A" }, "spaces, hex, an empty entry, = in a name");
    eq(M.parseValueList(""), {});
    for (const bad of ["0", "x=A", "-1=A", "1=", "1=A; 2"]) eq(M.parseValueList(bad), null, bad);
  });

  const motorSignals = (samples) => {
    const cfgs = M.normalizeConfig({ channels: { 6: MOTOR_STATE } }).channels;
    return M.buildSignals([1, 1, 1, 1, 1, 1, 8], cfgs).map((s) => {
      const raw = M.rawValues(s, [1, 1, 1, 1, 1, 1, 8], [0, 1, 2, 3, 4, 5].map(() => samples.map(() => 0)).concat([samples]));
      return { ...s, raw, values: M.scaleValues(raw, s.width, s.cfg) };
    });
  };

  test("a field is a bus of its own bits, with its names", () => {
    const [card, fsm] = M.fieldSignals(motorSignals([0x00, 0x22, 0x4A])[6]);
    eq([card.cfg.name, fsm.cfg.name], ["state.card", "state.fsm"]);
    eq(card.raw, [0, 2, 4]);
    eq(fsm.raw, [0, 2, 10]);
    eq([card.width, card.cfg.style, card.field, card.outside], [4, "bus", 0, false]);
    eq(card.raw.map((v) => M.namedText(v, card.width, card.cfg)), ["IDLE", "RUN", "FAULT"]);
    eq(fsm.raw.map((v) => M.namedText(v, fsm.width, fsm.cfg)), ["START_UP", "READY", "FAULT_MOTOR_TELEMETRY"]);
    eq(M.namedText(7, 4, fsm.cfg), "0x7");
  });

  test("a signal with fields is drawn as its fields, in its place", () => {
    const lanes = M.laneGroups(motorSignals([0x22]));
    eq(lanes.map((g) => g.host.cfg.name), ["ch0", "ch1", "ch2", "ch3", "ch4", "ch5", "state.card", "state.fsm"]);
    ok(lanes.slice(6).every((g) => g.members.length === 1 && M.laneWeight(g) === M.HEIGHTS.small), "one small lane each");
    const hidden = M.laneGroups(motorSignals([0x22]).map((s) => (s.base === 6 ? { ...s, cfg: { ...s.cfg, visible: false } } : s)));
    eq(hidden.length, 6, "hiding the channel hides its fields");
    const sharing = M.laneGroups(motorSignals([0x22]).map((s) => (s.base === 0 ? { ...s, cfg: { ...s.cfg, lane: 6 } } : s)));
    eq(sharing.map((g) => g.host.cfg.name)[0], "ch0", "a lane cannot be shared with a signal shown as fields");
  });

  test("a field above the signal's width reads as 0", () => {
    const signal = { base: 0, parts: [0], width: 4, raw: [0xF], cfg: M.normalizeConfig({ channels: [{ fields: [{ bits: [5, 2] }] }] }).channels[0] };
    const [field] = M.fieldSignals(signal);
    eq(field.raw, [3]);
    ok(field.outside);
  });

  test("the CSV has a name column next to a named value, and each field raw and named", () => {
    const [barometer] = M.buildSignals([4], M.normalizeConfig({ channels: [{ name: "baro", values: { 0: "IDLE", 1: "READ" } }] }).channels)
      .map((s) => ({ ...s, raw: [0, 1, 5], values: [0, 1, 5] }));
    eq(M.csvColumns([barometer]).map((c) => [c.name, c.values]), [["baro", [0, 1, 5]], ["baro:name", ["IDLE", "READ", ""]]]);
    const columns = M.csvColumns(motorSignals([0x22, 0x07]).slice(6));
    eq(columns.map((c) => c.name), ["state", "state.card", "state.card:name", "state.fsm", "state.fsm:name"]);
    eq(M.csvText(columns).split("\n")[2], "1,7,0,IDLE,7,", "the packed value is kept as it was");
    eq(M.csvText([{ name: "s:name", values: ["A,B"] }]), 'sample,s:name\n0,"A,B"\n', "a name is quoted when needed");
  });

  /* ---- controls ---- */

  const control =(fields = {}) => ({ ...M.defaultControl(0), ...fields });

  test("no control is in use by default", () => {
    const config = M.defaultConfig();
    eq(config.controls.length, 8);
    ok(config.controls.every((c, i) => c.kind === "off" && c.name === `control${i}`), "all eight not used");
  });

  test("control settings survive, invalid ones fall back one by one", () => {
    const config = M.normalizeConfig({ controls: [
      { name: " run ", kind: "button", value: 0xFFFFFFFF },
      { name: "speed", kind: "value", unit: "rpm", signed: true, frac: 2, gain: 0.5, offset: 10, min: -100, max: 100 },
      { name: "", kind: "slider", value: -1, unit: 5, signed: "yes", frac: 99, gain: 0, offset: "1", min: "low", max: NaN },
      { kind: "button", value: 0x100000000 },
      { kind: "toggle", value: 1.5 },
    ] });
    eq(config.controls[0], { ...M.defaultControl(0), name: "run", kind: "button", value: 0xFFFFFFFF });
    eq(config.controls[1], { name: "speed", kind: "value", value: 1, unit: "rpm", signed: true, frac: 2, gain: 0.5, offset: 10, min: -100, max: 100, values: {} });
    eq(config.controls[2], M.defaultControl(2), "all of it was junk");
    eq(config.controls[3], { ...M.defaultControl(3), kind: "button" }, "a value over 32 bits");
    eq(config.controls[4], { ...M.defaultControl(4), kind: "toggle" }, "a value that is not whole");
    eq(config.controls[5], M.defaultControl(5));
  });

  test("controls can be given by number, and a configuration without them has none in use", () => {
    const config = M.normalizeConfig({ controls: { 6: { name: "mode", kind: "toggle" } } });
    eq(config.controls[6], { ...M.defaultControl(6), name: "mode", kind: "toggle" });
    eq(config.controls.filter((c) => c.kind !== "off").length, 1);
    eq(M.normalizeConfig({ channels: [{ name: "a" }] }).controls, M.defaultConfig().controls, "a file from before the controls");
    eq(M.normalizeConfig({ controls: "none" }).controls, M.defaultConfig().controls);
  });

  test("configProblems covers the controls", () => {
    eq(M.configProblems({ controls: { 1: { name: "speed", kind: "value", min: null, max: 50 } } }), []);
    eq(M.configProblems({ controls: { 1: { kind: "slider", gain: 0, min: "0" }, 8: { kind: "button" } } }),
       ["controls.1.kind", "controls.1.gain", "controls.1.min", "controls.8"]);
  });

  test("a typed value is written as its raw value", () => {
    eq(M.controlRaw(control(), 0), { raw: 0 });
    eq(M.controlRaw(control(), 1234), { raw: 1234 });
    eq(M.controlRaw(control(), 0xFFFFFFFF), { raw: 0xFFFFFFFF });
    eq(M.controlRaw(control({ gain: 0.5 }), 50), { raw: 100 });
    eq(M.controlRaw(control({ gain: 0.5, offset: 10 }), 60), { raw: 100 });
    eq(M.controlRaw(control({ frac: 4 }), 2.5), { raw: 40 });
    eq(M.controlRaw(control({ gain: 3 }), 10), { raw: 3 }, "rounded to the nearest raw value");
  });

  test("a negative value goes out in two's complement", () => {
    eq(M.controlRaw(control({ signed: true }), -1), { raw: 0xFFFFFFFF });
    eq(M.controlRaw(control({ signed: true, gain: 0.5 }), -10), { raw: 0xFFFFFFEC }); // -20
    eq(M.controlRaw(control({ signed: true }), -(2 ** 31)), { raw: 0x80000000 });
    eq(M.controlRaw(control({ signed: true }), 2 ** 31 - 1), { raw: 0x7FFFFFFF });
  });

  test("a value that cannot be written is refused with the reason", () => {
    const error = (cfg, v) => M.controlRaw(cfg, v).error;
    ok(/not a number/.test(error(control(), NaN)), "NaN");
    ok(/not a number/.test(error(control(), Infinity)), "Infinity");
    ok(/not a number/.test(error(control(), "5")), "text");
    ok(/not signed/.test(error(control(), -1)), "negative on an unsigned control");
    ok(/32 bits/.test(error(control(), 2 ** 32)), "too large");
    ok(/32 bits/.test(error(control({ signed: true }), 2 ** 31)), "too large for signed");
    ok(/32 bits/.test(error(control({ signed: true }), -(2 ** 31) - 1)), "too negative");
    ok(/32 bits/.test(error(control({ gain: 1e-6 }), 1e6)), "too large once scaled");
    ok(/smallest allowed, 0/.test(error(control({ signed: true, min: 0, max: 100 }), -1)), "below min");
    ok(/largest allowed, 100/.test(error(control({ min: 0, max: 100 }), 100.5)), "above max");
    eq(M.controlRaw(control({ min: 0, max: 100 }), 100), { raw: 100 }, "the limits themselves are allowed");
    eq(M.controlRaw(control({ min: 0, max: 100 }), 0), { raw: 0 });
  });

  test("what is read back is shown in the control's units, and matches what was typed", () => {
    eq(M.controlShown(control(), 1234), 1234);
    eq(M.controlShown(control(), 0xFFFFFFFF), 0xFFFFFFFF);
    eq(M.controlShown(control({ signed: true }), 0xFFFFFFFF), -1);
    eq(M.controlShown(control({ gain: 0.5, offset: 10 }), 100), 60);
    for (const [cfg, v] of [[control({ signed: true, gain: 0.5 }), -10], [control({ frac: 4 }), 2.5], [control({ signed: true, frac: 8, gain: 2, offset: -3 }), 41.5]]) {
      eq(M.controlShown(cfg, M.controlRaw(cfg, v).raw), v);
    }
  });

  /* ---- files ---- */

  test("a capture window stays one sample short of the buffer, also with post 0", () => {
    ok(M.captureWindowFits(2047, 2048, 4095), "4095 of a 4096-sample buffer");
    ok(!M.captureWindowFits(2048, 2048, 4095), "the whole buffer");
    ok(M.captureWindowFits(4094, 0, 4095), "post 0 leaves room for the trigger sample");
    ok(!M.captureWindowFits(4095, 0, 4095), "post 0 with no room for the trigger sample");
    ok(M.captureWindowFits(0, 1, 4095), "a single sample");
    ok(!M.captureWindowFits(0, 0, 4095), "an empty window");
  });

  test("the CSV of a capture has the time relative to the trigger", () => {
    const text = M.csvText([{ name: "a", values: [1, 2, 3] }, { name: "b [V]", values: [0.5, -1, 0] }], { pre: 1, period: 1e-3 });
    eq(text.split("\n"), ["sample,time_s,a,b [V]", "-1,-1.000000e-3,1,0.5", "0,0.000000e+0,2,-1", "1,1.000000e-3,3,0", ""]);
  });

  test("the CSV of a stream has only the sample number, and names are quoted when needed", () => {
    const text = M.csvText([{ name: 'odd, "name"', values: [7] }]);
    eq(text, 'sample,"odd, ""name"""\n0,7\n');
    eq(M.csvText([]), "sample\n");
  });

  const capture = { widths: [1, 8], channels: [[0, 1, 1], [10, 200, 255]], pre: 2, decimation: 4, clk_freq_hz: 25e6 };

  test("a capture file gives back the capture and its configuration", () => {
    const config = M.normalizeConfig({ channels: [{}, { name: "level", signed: true }] });
    const loaded = M.parseCaptureFile(JSON.parse(JSON.stringify(M.captureFile(capture, config))));
    eq(loaded.capture, capture);
    eq(loaded.config, config);
    const bare = M.captureFile(capture, config);
    delete bare.config;
    eq(M.parseCaptureFile(bare).config, null, "a file without a configuration leaves the current one alone");
  });

  test("a file that could not be drawn is refused", () => {
    const file = (changes) => ({ ...M.captureFile(capture, M.defaultConfig()), ...changes });
    throws(() => M.parseCaptureFile({ some: "json" }), /wrong file type/);
    throws(() => M.parseCaptureFile(null), /wrong file type/);
    throws(() => M.parseCaptureFile(file({ fpga_scope_capture: 2 })), /version/);
    throws(() => M.parseCaptureFile(file({ widths: [1] })), /channel count/);
    throws(() => M.parseCaptureFile(file({ widths: [1, 9] })), /widths out of range/);
    throws(() => M.parseCaptureFile(file({ channels: [[0, 1, 1], [10, 200]] })), /different length/);
    throws(() => M.parseCaptureFile(file({ channels: [[0, 2, 1], [10, 200, 255]] })), /outside its width/);
    throws(() => M.parseCaptureFile(file({ channels: [[], []] })), /no samples/);
    throws(() => M.parseCaptureFile(file({ pre: 4 })), /trigger position/);
    throws(() => M.parseCaptureFile(file({ decimation: 0 })), /decimation/);
    throws(() => M.parseCaptureFile(file({ clk_freq_hz: 0 })), /clock frequency/);
  });

  Harness.finish();
})();
