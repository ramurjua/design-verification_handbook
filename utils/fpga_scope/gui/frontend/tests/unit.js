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
      trigger: { channels: [{ type: "fall", bit: 3 }, { type: "sideways", bit: 12 }], combine: "or" },
      window: { pre: 7, post: -1, decimation: 0 },
      stream: { decimation: 5, batch: 20000, window: 500 },
    });
    eq(config.channels[0], { name: "gyro_x", unit: "dps", visible: false, signed: true, frac: 4, gain: 0.5, offset: -3, format: "bin",
                             range: "manual", min: -10, max: 10, style: "line", height: "large", bits: true, high: 1, lane: 2 });
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

  /* ---- files ---- */

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
