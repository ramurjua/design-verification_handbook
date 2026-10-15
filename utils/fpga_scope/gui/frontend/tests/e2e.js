/* End-to-end test of the GUI: the real index.html in an iframe, talking to the
   real backend and its simulated device (1, 1, 4 and 8-bit channels). Each step
   uses the page the way a person would (inputs, clicks, wheel, keys) and then
   looks at what the page worked out. See harness.js for how it is run. */

(async () => {
  const { step, ok, eq, near, until } = Harness;
  const STORAGE_KEY = "fpga_scope.config";
  const CONFIG_NAME = "e2e_test_config";

  // start from the default settings, and give the browser back its own afterwards
  const savedSettings = localStorage.getItem(STORAGE_KEY);
  localStorage.removeItem(STORAGE_KEY);

  const frame = document.getElementById("app");
  await new Promise((resolve) => { frame.addEventListener("load", resolve, { once: true }); frame.src = "../index.html"; });
  const w = frame.contentWindow, d = w.document;
  const q = (id) => d.getElementById(id);
  const js = (code) => w.eval(code); // the page's own top-level state: app, layout, ...

  let savedConfig = null; // what the backend wrote to disk, reused as a file to open

  const errors = [];
  w.addEventListener("error", (e) => errors.push(e.message));
  w.addEventListener("unhandledrejection", (e) => errors.push(String(e.reason)));

  /* ---- acting on the page ---- */

  function set(id, value) {
    const input = q(id);
    if (input.type === "checkbox") input.checked = value;
    else input.value = value;
    input.dispatchEvent(new w.Event("input", { bubbles: true }));
    input.dispatchEvent(new w.Event("change", { bubbles: true }));
  }

  /* page coordinates of a sample (or of a pixel offset into the plot area) */
  const plot = () => q("plot").getBoundingClientRect();
  const atSample = (i) => ({ clientX: plot().left + js("layout").x(i), clientY: plot().top + 100 });
  const atFraction = (f) => ({ clientX: plot().left + js("layout").left + js("layout").plotW * f, clientY: plot().top + 100 });

  const pointer = (type, where, more = {}) => q("plot").dispatchEvent(
    new w.PointerEvent(type, { bubbles: true, cancelable: true, button: 0, pointerId: 1, ...where, ...more }));
  function click(where, more) {
    pointer("pointerdown", where, more);
    pointer("pointerup", where, more);
  }
  function dragBy(where, dx) {
    pointer("pointerdown", where);
    pointer("pointermove", { ...where, clientX: where.clientX + dx / 2 });
    pointer("pointermove", { ...where, clientX: where.clientX + dx });
    pointer("pointerup", { ...where, clientX: where.clientX + dx });
  }
  const wheel = (where, deltaY) => q("plot").dispatchEvent(new w.WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY, ...where }));
  const key = (k) => q("plot").dispatchEvent(new w.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: k }));

  /* ---- looking at the page ---- */

  const lanes = () => js("layout").lanes;
  const laneNames = () => lanes().map((lane) => lane.group.members.map((s) => s.cfg.name).join("+"));
  const signals = () => js("derive(currentData()).signals");
  const view = () => js("app.view[app.tab]");
  const span = () => js("layout.view.end - layout.view.start");

  /* the canvas shows something other than its background */
  function painted() {
    const canvas = q("plot");
    const pixels = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
    const colours = new Set();
    for (let i = 0; i < pixels.length && colours.size < 4; i += 4 * 7) colours.add((pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2]);
    return colours.size >= 3;
  }

  async function capture() {
    const before = js("dataRev");
    q("arm").click();
    await until(() => js("dataRev") > before && q("state-label").textContent === "Idle", "a capture");
  }

  /* ---- the steps ---- */

  await step("the page loads and reaches the backend", async () => {
    await until(() => [...q("port").options].some((o) => o.value === "sim"), "the simulated port in the list");
    await until(() => !q("connect").disabled, "the WebSocket");
    ok(q("measure").hidden, "no measurements without data");
  });

  await step("connecting builds one settings block per channel", async () => {
    q("port").value = "sim";
    q("connect").click();
    await until(() => q("state-label").textContent === "Idle", "the connection");
    eq(d.querySelectorAll(".chan").length, 4);
    eq(q("chan-note-3").textContent, "ch3, 8 bits, unsigned");
    eq(q("chan-note-0").textContent, "ch0, 1 bit");
    ok(q("ch0-signed").disabled && !q("ch3-signed").disabled, "only multi-bit channels can be signed");
  });

  await step("the window hint says when pre + post is more than the core captures correctly", async () => {
    const before = [q("pre").value, q("post").value];
    eq(js("app.info.max_capture_samples"), 1023); // the simulated core has a 1024-sample buffer
    set("pre", 512); set("post", 511);
    ok(!q("scope-hint").textContent.includes("too long"), "1023 samples fit");
    set("post", 512);
    ok(q("scope-hint").textContent.includes("too long: at most 1023"), "the whole buffer does not");
    set("pre", 1023); set("post", 0);
    ok(q("scope-hint").textContent.includes("too long"), "post 0 still needs room for the trigger sample");
    set("pre", before[0]); set("post", before[1]);
    ok(!q("scope-hint").textContent.includes("("), "back to a plain hint");
  });

  await step("a long channel name does not push the trigger settings out of the panel", async () => {
    const inside = () => [0, 1, 2, 3].every((c) => q(`trig-bit-${c}`).getBoundingClientRect().right <= q("triggers").getBoundingClientRect().right + 0.5
                                                 && q(`trig-type-${c}`).getBoundingClientRect().right <= q("triggers").getBoundingClientRect().right + 0.5);
    ok(inside(), "with the default names");
    set("ch3-name", "spi miso,mosi,sck,cs_n");
    eq(q("trig-name-3").textContent, "spi miso,mosi,sck,cs_n");
    ok(inside(), "with a name of 22 characters");
    set("ch3-name", "W".repeat(24));
    ok(inside(), "with the longest name there can be, and no space to wrap at");
    ok(q("trig-type-3").getBoundingClientRect().width > 60, "and the selects keep their size");
    set("ch3-name", "ch3");
  });

  await step("no control is shown until one is configured", async () => {
    eq(d.querySelectorAll(".ctl").length, 8, "eight controls to set up");
    ok(q("controls").hidden && !q("controls-none").hidden, "none in use, and the panel says so");
    ok(q("panel-controls").getBoundingClientRect().left > q("plot").getBoundingClientRect().right, "the controls have their own panel, right of the plot");
    ok(q("panel-controls").contains(q("control-rows")) && q("panel-controls").contains(q("controls")), "with both their settings and the controls themselves");
    eq(q("ctl-note-0").textContent, "control 0, not used");
    ok(q("ctl0-value").hidden && q("ctl0-gain").hidden && !q("ctl0-kind").hidden, "only the fields of the chosen kind");
    await until(() => js("app.controls"), "the controls read from the core");
    eq(js("app.controls"), [0, 0, 0, 0, 0, 0, 0, 0]);
  });

  await step("a capture is drawn with a Y axis on the multi-bit lanes", async () => {
    await capture();
    eq(q("plot-title").textContent, "Captured window");
    eq(laneNames(), ["ch0", "ch1", "ch2", "ch3"]);
    eq([lanes()[3].min, lanes()[3].max], [0, 255]);
    eq(lanes()[3].axis.values, [0, 50, 100, 150, 200, 250].filter((v) => lanes()[3].axis.values.includes(v)), "round tick values");
    ok(lanes()[3].axis.values.length >= 3, "several ticks on the 8-bit lane");
    eq(lanes()[0].axis.values, [], "no ticks on a 1-bit lane");
    ok(js("layout.left") >= 70, "room for the tick labels");
    ok(painted(), "something is drawn");
    ok(!q("measure").hidden && q("measure").tBodies[0].rows.length === 4, "one measurement row per signal");
  });

  await step("signed: the same samples read as two's complement", async () => {
    const unsigned = signals()[3].values.slice();
    ok(unsigned.some((v) => v >= 128), "the simulated signal uses the top bit");
    set("ch3-signed", true);
    eq([lanes()[3].min, lanes()[3].max], [-128, 127]);
    eq(signals()[3].values, unsigned.map((v) => (v >= 128 ? v - 256 : v)));
    ok(lanes()[3].axis.values.includes(0) && lanes()[3].axis.values.some((v) => v < 0), "the axis shows negative values");
    eq(q("chan-note-3").textContent, "ch3, 8 bits, signed");
  });

  await step("gain, offset, fraction bits, name and unit reach every readout", async () => {
    const signed = signals()[3].values.slice();
    set("ch3-gain", "0.5");
    set("ch3-offset", "10");
    set("ch3-name", "temp");
    set("ch3-unit", "degC");
    eq(signals()[3].values, signed.map((v) => v * 0.5 + 10));
    eq([lanes()[3].min, lanes()[3].max], [-54, 73.5]);
    set("ch3-frac", "1");
    eq(signals()[3].values, signed.map((v) => v * 0.25 + 10));
    set("ch3-frac", "0");
    eq(q("chan-name-3").textContent, "temp");
    eq(q("trig-name-3").textContent, "temp");
    ok(q("measure").textContent.includes("temp [degC]"), "measurement table");
    ok(js("csvText()").split("\n")[0].endsWith(",temp [degC]"), "CSV header");
    eq(js("csvText()").split("\n")[1].split(",").pop(), String(signals()[3].values[0]), "CSV holds the scaled value");
    pointer("pointermove", atSample(10));
    ok(!q("tooltip").hidden && /temp/.test(q("tooltip").textContent) && /degC \(0x[0-9A-F]{2}\)/.test(q("tooltip").textContent), "hover readout: " + q("tooltip").textContent);
    set("ch3-gain", "abc");
    eq(js("app.config.channels[3].gain"), 0.5, "a half-typed number is not applied");
    set("ch3-gain", "0.5");
  });

  await step("Y range: fit to the visible samples, or manual", async () => {
    ok(q("ch3-min").hidden && q("ch3-max").hidden, "manual limits hidden until asked for");
    set("ch3-range", "auto");
    const values = signals()[3].values;
    ok(lanes()[3].min < Math.min(...values) && lanes()[3].max > Math.max(...values), "covers the data");
    ok(lanes()[3].max - lanes()[3].min < 1.2 * (Math.max(...values) - Math.min(...values)), "and not much more");
    set("ch3-range", "manual");
    ok(!q("ch3-min").hidden && !q("ch3-max").hidden, "manual limits shown");
    set("ch3-min", "-10");
    set("ch3-max", "30");
    eq([lanes()[3].min, lanes()[3].max], [-10, 30]);
    ok(painted(), "a trace that leaves the lane is still drawn");
    set("ch3-range", "full");
  });

  await step("wheel zooms around the pointer, drag pans, double click shows everything", async () => {
    eq(view(), null);
    const n = js("layout.n");
    const anchor = js("layout").sampleAt(atFraction(0.25).clientX - plot().left);
    wheel(atFraction(0.25), -100);
    near(span(), (n - 1) * 0.8, "span after one notch", 1e-6);
    // the browser rounds a wheel event's position to a whole pixel
    near(js("layout").sampleAt(atFraction(0.25).clientX - plot().left), anchor, "sample under the pointer", n / js("layout.plotW"));
    for (let i = 0; i < 6; i++) wheel(atFraction(0.5), -100);
    ok(span() < n / 3, "zoomed in");
    ok(!q("zoom-reset").disabled, "reset available");
    ok(painted(), "zoomed view drawn");

    const before = view().start;
    dragBy(atFraction(0.5), -120);
    ok(view().start > before, "dragging left moves later samples in");
    eq(js("app.cursors.scope"), { a: null, b: null }, "a drag is not a click");

    for (let i = 0; i < 40; i++) wheel(atFraction(0.5), -100);
    near(span(), 4, "the zoom stops at 4 samples");
    ok(painted(), "sample markers drawn");

    click(atFraction(0.5));
    click(atFraction(0.5));
    q("plot").dispatchEvent(new w.MouseEvent("dblclick", { bubbles: true }));
    eq(view(), null, "double click resets the zoom");
    eq(js("app.cursors.scope.a"), null, "and does not leave a cursor behind");
    q("zoom-in").click();
    near(span(), (n - 1) / 2, "zoom in button");
    q("zoom-out").click();
    eq(view(), null, "zoom out button back to everything");
  });

  await step("the X axis follows the zoom", async () => {
    q("zoom-in").click();
    const first = js("layout.first"), last = js("layout.last");
    ok(first > 0 && last < js("layout.n") - 1, "a window in the middle");
    ok(q("measure-head").textContent.includes(`${last - first + 1} visible samples`), q("measure-head").textContent);
    q("zoom-reset").click();
  });

  await step("cursors measure time and value differences", async () => {
    const pre = js("app.capture.pre");
    click(atSample(pre + 20));
    eq(js("app.cursors.scope"), { a: pre + 20, b: null });
    click(atSample(pre + 120), { shiftKey: true });
    eq(js("app.cursors.scope"), { a: pre + 20, b: pre + 120 });
    // the simulated core samples at 1 MHz: 100 samples are 100 µs, 10 kHz
    ok(/B - A: 100 µs, 1\/Δt 10 kHz/.test(q("measure-head").textContent), q("measure-head").textContent);
    const row = [...q("measure").tBodies[0].rows].find((r) => r.cells[0].textContent.includes("temp"));
    const values = signals()[3].values;
    eq(row.cells[7].textContent, String(Number((values[pre + 120] - values[pre + 20]).toPrecision(6))), "B - A of the scaled signal");
    ok(row.cells[5].textContent.includes("degC"), "value at A has its unit");

    dragBy(atSample(pre + 20), 60);
    ok(js("app.cursors.scope.a") > pre + 20, "a cursor can be dragged");
    eq(view(), null, "dragging a cursor does not pan");
    q("cursors-clear").click();
    eq(js("app.cursors.scope"), { a: null, b: null });
    ok(q("cursors-clear").disabled, "nothing left to clear");
  });

  await step("the keyboard reads values, zooms and places cursors", async () => {
    pointer("pointerleave", atFraction(0.5)); // no crosshair: the keys start from the trigger
    q("plot").focus();
    key("ArrowRight");
    eq(js("app.hover"), js("app.capture.pre") + 1);
    key("a");
    key("ArrowRight");
    key("b");
    eq(js("app.cursors.scope"), { a: js("app.capture.pre") + 1, b: js("app.capture.pre") + 2 });
    key("+");
    ok(view() !== null, "plus zooms in");
    key("0");
    eq(view(), null, "zero shows everything");
    q("cursors-clear").click();
  });

  await step("two channels combine into one wider signal", async () => {
    set("ch2-high", "3");
    eq(laneNames(), ["ch0", "ch1", "ch2"]);
    eq(signals()[2].width, 12);
    const { channels } = js("app.capture");
    eq(signals()[2].raw, channels[2].map((low, i) => low + channels[3][i] * 16));
    ok(q("chan-3").classList.contains("part") && q("ch3-gain").disabled, "the upper channel has no settings of its own");
    eq(q("chan-note-2").textContent, "ch2, 4 bits, 12 bits with ch3, unsigned");
    eq(q("chan-note-3").textContent, "ch3, 8 bits, upper bits of ch2");
    eq([lanes()[2].min, lanes()[2].max], [0, 4095]);
    set("ch2-signed", true);
    eq([lanes()[2].min, lanes()[2].max], [-2048, 2047], "signed over the combined width");
    set("ch2-signed", false);
    set("ch2-high", "");
    eq(laneNames(), ["ch0", "ch1", "ch2", "temp"]);
  });

  await step("one lane per bit", async () => {
    ok(q("ch0-bits").disabled, "nothing to expand on a 1-bit channel");
    set("ch2-bits", true);
    eq(laneNames(), ["ch0", "ch1", "ch2", "ch2[3]", "ch2[2]", "ch2[1]", "ch2[0]", "temp"]);
    const raw = js("app.capture.channels[2]");
    eq(lanes()[3].group.host.values, raw.map((v) => (v >> 3) & 1));
    eq(lanes()[6].group.host.values, raw.map((v) => v & 1));
    eq(q("measure").tBodies[0].rows.length, 4, "the bits stay out of the measurements");
    ok(painted(), "drawn");
    set("ch2-bits", false);
    eq(lanes().length, 4);
  });

  await step("signals can share a lane and its Y axis", async () => {
    set("ch2-lane", "3");
    eq(laneNames(), ["ch0", "ch1", "temp+ch2"]);
    eq([lanes()[2].min, lanes()[2].max], [-54, 73.5], "full scale of both: -54..73.5 and 0..15");
    set("ch2-lane", "");
    eq(lanes().length, 4);
  });

  await step("trace styles, lane height and hiding channels", async () => {
    for (const style of ["line", "bus", "step"]) {
      set("ch3-style", style);
      set("ch2-style", style);
      ok(painted(), `${style} drawn`);
    }
    set("ch2-style", "bus");
    eq(lanes()[2].axis.values, [], "a bus lane has no Y axis");
    for (let i = 0; i < 8; i++) wheel(atFraction(0.5), -100);
    ok(painted(), "bus drawn zoomed in, with room for its values");
    q("zoom-reset").click();
    set("ch2-style", "step");

    const normal = lanes()[3].height;
    set("ch3-height", "xlarge");
    ok(lanes()[3].height > normal * 1.3, "a taller lane");
    set("ch3-height", "auto");

    set("ch1-visible", false);
    eq(laneNames(), ["ch0", "ch2", "temp"]);
    ok(js("csvText()").split("\n")[0].includes("ch1"), "a hidden channel is still exported");
    for (const c of [0, 2, 3]) set(`ch${c}-visible`, false);
    eq(js("layout"), null, "nothing to lay out");
    ok(q("measure").hidden, "no measurements either");
    for (const c of [0, 1, 2, 3]) set(`ch${c}-visible`, true);
    eq(lanes().length, 4);
  });

  await step("the settings are remembered by the browser", async () => {
    set("pre", "60");
    set("trig-type-1", "fall");
    const stored = JSON.parse(w.localStorage.getItem(STORAGE_KEY));
    eq([stored.channels[3].name, stored.channels[3].signed, stored.channels[3].gain], ["temp", true, 0.5]);
    eq([stored.window.pre, stored.trigger.channels[1].type], [60, "fall"]);
  });

  await step("a configuration is saved to disk, loaded back and deleted", async () => {
    set("cfg-name", "");
    q("cfg-save").click();
    eq(q("cfg-status").textContent, "Type a name first.");
    set("cfg-name", CONFIG_NAME);
    q("cfg-save").click();
    await until(() => q("cfg-status").textContent.startsWith("Saved"), "the save");
    const onDisk = await (await fetch(`/api/configs/${CONFIG_NAME}`)).json();
    eq([onDisk.channels[3].name, onDisk.channels[3].unit, onDisk.channels[3].signed, onDisk.window.pre], ["temp", "degC", true, 60]);
    await until(() => [...q("cfg-names").options].some((o) => o.value === CONFIG_NAME), "the name in the list");

    set("ch3-name", "changed");
    set("ch3-signed", false);
    set("ch0-visible", false);
    set("pre", "5");
    set("trig-type-1", "off");
    q("cfg-load").click();
    await until(() => q("cfg-status").textContent.startsWith("Loaded"), "the load");
    eq([q("ch3-name").value, q("ch3-signed").checked, q("ch0-visible").checked], ["temp", true, true]);
    eq([q("pre").value, q("trig-type-1").value], ["60", "fall"]);
    eq(laneNames(), ["ch0", "ch1", "ch2", "temp"]);
    eq([lanes()[3].min, lanes()[3].max], [-54, 73.5], "the plot follows the loaded configuration");

    savedConfig = onDisk;
    q("cfg-delete").click();
    await until(() => q("cfg-status").textContent.startsWith("Deleted"), "the delete");
    eq((await fetch(`/api/configs/${CONFIG_NAME}`)).status, 404);
    q("cfg-load").click();
    await until(() => !q("error").hidden, "the error for a missing configuration");
    q("error-close").click();
    set("pre", "100");
    set("trig-type-1", "off");
  });

  await step("a configuration file written by hand can be opened", async () => {
    js("loadConfigText")('{"channels": {"2": {"name": "state", "style": "bus", "format": "bin"}, "3": {"signed": true, "gain": "big"}}, "window": {"post": 250}}', "mine.json");
    eq([q("ch2-name").value, q("ch2-style").value, q("ch3-name").value, q("ch3-signed").checked], ["state", "bus", "ch3", true], "what is not in the file is back at its default");
    eq(q("post").value, "250");
    eq(laneNames(), ["ch0", "ch1", "state", "ch3"]);
    eq(q("cfg-status").textContent, "Loaded mine.json. Not used, left at the default: channels.3.gain.");
    js("loadConfigText")("{not json", "broken.json");
    ok(!q("error").hidden && q("error-text").textContent.startsWith("Cannot use broken.json"), q("error-text").textContent);
    eq(q("ch2-name").value, "state", "a file that cannot be read changes nothing");
    q("error-close").click();
    js("loadConfigText")(JSON.stringify(savedConfig), "saved.json");
    eq(q("cfg-status").textContent, "Loaded saved.json.");
    eq([q("ch2-name").value, q("ch3-name").value, q("post").value], ["ch2", "temp", "300"]);
    eq(q("trig-type-1").value, "fall", "the trigger came back with it");
    set("trig-type-1", "off"); // ch0 rising and ch1 falling on the same sample never happens
  });

  await step("a capture is saved, loaded back and kept as a reference", async () => {
    const original = js("app.capture.channels");
    const text = js("captureFileText()");
    eq(JSON.parse(text).config.channels[3].name, "temp", "the file carries the configuration");

    q("ref-set").click();
    await capture();
    ok(js("app.reference !== app.capture"), "a new capture does not replace the reference");
    ok(q("plot-sub").textContent.includes("reference"), q("plot-sub").textContent);
    ok(painted(), "drawn with the reference behind");
    q("ref-clear").click();
    ok(q("ref-clear").disabled && !q("plot-sub").textContent.includes("reference"), "reference gone");

    set("ch3-name", "other");
    await js("loadCaptureText")(text);
    eq(js("app.capture.channels"), original);
    eq(q("ch3-name").value, "temp", "its configuration came with it");

    await js("loadCaptureText")('{"some": "other json"}');
    ok(!q("error").hidden && q("error-text").textContent.includes("capture file"), "a wrong file is refused with a message");
    eq(js("app.capture.channels"), original, "and the capture on screen stays");
    q("error-close").click();
  });

  await step("the stream tab shows live samples with the same settings", async () => {
    q("tab-stream").click();
    await until(() => !q("panel-stream").hidden, "the stream tab");
    eq(js("layout"), null, "nothing streamed yet");
    q("s-start").click();
    await until(() => js("app.stream") && js("app.stream.channels[0].length") >= 400, "two bursts of samples");
    eq(view(), null);
    wheel(atFraction(0.5), -100);
    eq(view(), null, "no zoom while the stream is running");
    q("s-stop").click();
    await until(() => q("state-label").textContent === "Idle", "the stream to stop");
    eq(laneNames(), ["ch0", "ch1", "ch2", "temp"]);
    eq([lanes()[3].min, lanes()[3].max], [-54, 73.5]);
    wheel(atFraction(0.5), -100);
    ok(view() !== null, "a stopped stream can be zoomed");
    click(atFraction(0.3));
    click(atFraction(0.6), { shiftKey: true });
    ok(/B - A: \d+ samples/.test(q("measure-head").textContent), q("measure-head").textContent);
    eq(js("csvText()").split("\n")[0], "sample,ch0,ch1,ch2,temp [degC]");
    ok(painted(), "drawn");
    q("tab-scope").click();
    await until(() => !q("panel-scope").hidden, "the scope tab");
  });

  await step("a recording keeps every burst, beyond the samples on screen", async () => {
    const saved = [];
    w.download = (text, name) => saved.push({ text, name }); // instead of a file in the downloads folder
    q("tab-stream").click();
    await until(() => !q("panel-stream").hidden, "the stream tab");
    ok(!q("rec-start").disabled && q("rec-stop").disabled, "nothing being recorded yet");
    set("s-window", "300");
    q("rec-start").click();
    ok(q("rec-start").disabled && !q("rec-stop").disabled, "recording");
    ok(q("rec-status").textContent.includes("waiting"), q("rec-status").textContent);
    q("s-start").click();
    await until(() => js("app.recording.bursts") >= 3, "three bursts");
    q("s-stop").click();
    await until(() => q("state-label").textContent === "Idle", "the stream to stop");
    const bursts = js("app.recording.bursts");
    eq(js("app.stream.channels[0].length"), 300, "the plot holds its window only");
    q("rec-stop").click();
    eq(saved.length, 1);
    eq(saved[0].name, "fpga_scope_recording.csv");
    const lines = saved[0].text.trimEnd().split("\n");
    eq(lines[0], "sample,burst,ch0,ch1,ch2,temp [degC]");
    eq(lines.length - 1, bursts * 200, "every sample of every burst");
    eq(lines[1].split(",").slice(0, 2), ["0", "0"]);
    eq(lines[lines.length - 1].split(",").slice(0, 2), [String(bursts * 200 - 1), String(bursts - 1)]);
    eq(lines[lines.length - 1].split(",").pop(), String(signals()[3].values[299]), "scaled like the plot");
    ok(q("rec-status").textContent.startsWith(`Saved ${bursts * 200} samples in ${bursts} bursts`), q("rec-status").textContent);
    ok(!q("rec-start").disabled && q("rec-stop").disabled, "ready for another one");

    q("rec-start").click();
    q("rec-stop").click();
    eq(saved.length, 1, "an empty recording is not saved");
    ok(q("rec-status").textContent.startsWith("Nothing was recorded"), q("rec-status").textContent);
    set("s-window", "2000");
    q("tab-scope").click();
    await until(() => !q("panel-scope").hidden, "the scope tab");
  });

  const coreControls = async () => (await (await fetch("/api/controls")).json()).values;

  await step("a button writes its value to the FPGA", async () => {
    set("ctl0-kind", "button");
    set("ctl0-name", "run");
    ok(!q("controls").hidden && q("controls-none").hidden, "the control appears in the panel");
    ok(!q("ctl0-value").hidden && q("ctl0-gain").hidden, "a button only has the value it writes");
    eq(q("ctl-note-0").textContent, "control 0, button");
    eq(q("ctl-btn-0").textContent, "run");
    ok(!q("ctl-btn-0").disabled, "usable while connected");
    q("ctl-btn-0").click();
    await until(() => q("controls-status").textContent.startsWith("run: wrote 1 to control 0"), "the write");
    eq(await coreControls(), [1, 0, 0, 0, 0, 0, 0, 0]);
    set("ctl0-value", "0x2A");
    q("ctl-btn-0").click();
    await until(() => js("app.controls[0]") === 42, "the new value");
    eq((await coreControls())[0], 42);
    set("ctl0-value", "-3");
    set("ctl0-value", "4294967296");
    set("ctl0-value", "1.5");
    eq(js("app.config.controls[0].value"), 42, "a value that is not 32 unsigned bits is not taken");
  });

  await step("a switch turns a control on and off", async () => {
    set("ctl5-kind", "toggle");
    set("ctl5-name", "enable");
    eq(q("ctl-btn-5").textContent, "enable: off");
    eq(q("ctl-btn-5").getAttribute("aria-pressed"), "false");
    q("ctl-btn-5").click();
    await until(() => q("ctl-btn-5").getAttribute("aria-pressed") === "true", "on");
    eq(q("ctl-btn-5").textContent, "enable: on");
    eq((await coreControls())[5], 1);
    q("ctl-btn-5").click();
    await until(() => q("ctl-btn-5").getAttribute("aria-pressed") === "false", "off");
    eq((await coreControls())[5], 0);
  });

  await step("a value is typed in its units, within its limits", async () => {
    set("ctl2-kind", "value");
    set("ctl2-name", "speed");
    set("ctl2-unit", "rpm");
    set("ctl2-gain", "0.5");
    set("ctl2-min", "0");
    set("ctl2-max", "100");
    ok(q("ctl2-value").hidden && !q("ctl2-gain").hidden, "a value has scaling, not a fixed value");
    eq(q("ctl-now-2").textContent, "now 0 rpm");

    set("ctl-in-2", "50");
    q("ctl-send-2").click();
    await until(() => js("app.controls[2]") === 100, "50 rpm written as 100");
    eq((await coreControls())[2], 100);
    eq(q("ctl-now-2").textContent, "now 50 rpm");
    eq(q("ctl-in-2").value, "50", "what was typed stays");

    set("ctl-in-2", "150");
    q("ctl-send-2").click();
    ok(/speed: above the largest allowed, 100\. Nothing was sent/.test(q("controls-status").textContent), q("controls-status").textContent);
    set("ctl-in-2", "-1");
    q("ctl-send-2").click();
    ok(/below the smallest allowed, 0/.test(q("controls-status").textContent), q("controls-status").textContent);
    set("ctl-in-2", "");
    q("ctl-send-2").click();
    ok(/type a number first/.test(q("controls-status").textContent), q("controls-status").textContent);
    eq((await coreControls())[2], 100, "none of those reached the core");

    set("ctl2-min", "");
    eq(js("app.config.controls[2].min"), null, "an empty limit is no limit");
    set("ctl-in-2", "-10");
    q("ctl-send-2").click();
    ok(/not signed/.test(q("controls-status").textContent), q("controls-status").textContent);
    set("ctl2-signed", true);
    q("ctl-in-2").dispatchEvent(new w.KeyboardEvent("keydown", { bubbles: true, key: "Enter" }));
    await until(() => js("app.controls[2]") === 0xFFFFFFEC, "-10 rpm written as -20 in two's complement");
    eq((await coreControls())[2], 0xFFFFFFEC);
    eq(q("ctl-now-2").textContent, "now -10 rpm");
    set("ctl2-gain", "0");
    eq(js("app.config.controls[2].gain"), 0.5, "a gain of zero is not taken");
  });

  await step("controls work while the stream is running", async () => {
    q("tab-stream").click();
    await until(() => !q("panel-stream").hidden, "the stream tab");
    q("s-start").click();
    await until(() => q("state-label").textContent === "Streaming" && js("app.stream"), "the stream");
    const before = js("dataRev");
    q("ctl-btn-0").click();
    await until(() => q("controls-status").textContent.startsWith("run: wrote 42"), "the write during the stream");
    q("ctl-btn-5").click();
    await until(() => q("ctl-btn-5").getAttribute("aria-pressed") === "true", "the switch during the stream");
    await until(() => js("dataRev") > before + 2, "the stream to carry on");
    eq(q("state-label").textContent, "Streaming");
    ok(q("error").hidden, `error banner: ${q("error-text").textContent}`);
    q("s-stop").click();
    await until(() => q("state-label").textContent === "Idle", "the stream to stop");
    eq((await coreControls())[5], 1);
    q("tab-scope").click();
    await until(() => !q("panel-scope").hidden, "the scope tab");
  });

  await step("the controls are part of the configuration", async () => {
    const stored = JSON.parse(w.localStorage.getItem(STORAGE_KEY));
    eq([stored.controls[0].name, stored.controls[0].kind, stored.controls[0].value], ["run", "button", 42]);
    eq([stored.controls[2].kind, stored.controls[2].unit, stored.controls[2].gain, stored.controls[2].max], ["value", "rpm", 0.5, 100]);
    eq(stored.controls[7].kind, "off");
    const kept = JSON.stringify(js("collectConfig()"));

    js("loadConfigText")('{"controls": {"3": {"name": "mode", "kind": "button", "value": 7}, "4": {"kind": "knob"}}}', "controls.json");
    eq(q("cfg-status").textContent, "Loaded controls.json. Not used, left at the default: controls.4.kind.");
    eq([...q("controls").querySelectorAll("button")].map((b) => b.textContent), ["mode"], "only the control the file sets up");
    eq(q("ctl3-value").value, "7");
    eq(q("ctl-note-0").textContent, "control 0, not used");

    js("loadConfigText")('{"channels": {"0": {"name": "clk"}}}', "none.json");
    ok(q("controls").hidden, "a configuration without controls shows none");

    js("loadConfigText")(kept, "kept.json");
    eq([...q("controls").querySelectorAll("button")].map((b) => b.textContent), ["run", "Send", "enable: on"]);
    eq(q("ctl-now-2").textContent, "now -10 rpm", "the core's values were not touched by loading files");
  });

  await step("a core built before the controls shows them disabled", async () => {
    q("connect").click();
    await until(() => q("state-label").textContent === "Disconnected", "the disconnect");
    ok(q("ctl-btn-0").disabled && q("ctl-send-2").disabled && q("ctl-in-2").disabled, "nothing to write to while disconnected");
    eq(q("ctl-btn-5").textContent, "enable: ?", "and nothing known about their state");

    q("port").add(new w.Option("sim-v1", "sim-v1"));
    q("port").value = "sim-v1";
    q("connect").click();
    await until(() => q("state-label").textContent === "Idle", "the connection to the old core");
    eq(js("app.info.num_controls"), 0);
    ok(q("ctl-btn-0").disabled && q("ctl-send-2").disabled, "still disabled");
    ok(q("controls-status").textContent.startsWith("The connected core has no controls"), q("controls-status").textContent);
    await capture();
    ok(painted(), "the rest of the GUI works against it");

    q("connect").click();
    await until(() => q("state-label").textContent === "Disconnected", "the disconnect");
    eq(q("controls-status").textContent, "", "the note goes with the core");
    q("port").value = "sim";
    q("connect").click();
    await until(() => q("state-label").textContent === "Idle" && js("app.controls"), "the connection to a current core");
    ok(!q("ctl-btn-0").disabled, "usable again");
    eq(q("ctl-btn-5").textContent, "enable: off", "the state shown is what this core holds");
    for (const i of [0, 2, 5]) set(`ctl${i}-kind`, "off");
    ok(q("controls").hidden, "all back to not used");
  });

  await step("nothing went wrong along the way", async () => {
    q("connect").click();
    await until(() => q("state-label").textContent === "Disconnected", "the disconnect");
    ok(js("layout") !== null, "the last capture stays on screen after disconnecting");
    eq(errors, [], "uncaught errors in the page");
    ok(q("error").hidden, `error banner: ${q("error-text").textContent}`);
  });

  if (savedSettings === null) localStorage.removeItem(STORAGE_KEY);
  else localStorage.setItem(STORAGE_KEY, savedSettings);
  Harness.finish();
})();
