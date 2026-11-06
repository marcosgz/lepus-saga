import { h, s, clear, reducedMotion } from "./dom.js";
import { compact } from "./format.js";
import { isLive, now as clock, onLive } from "./live.js";

// Draws saga lines as a transit diagram and moves execution tokens along
// them. A position is a float over the line: -1 is the start terminal, 0..n-1
// are the stations, n is the end terminal. Tokens ride the main line ("fwd")
// or the compensation rail beneath it ("back"). Tokens heading out of the
// same station share up to three lanes; past SEGMENT_SHOWN the rest ride as
// one "+N" pill.

const RAIL_OFFSET = 12;
const LANES = { fwd: [0, -8, -16], back: [RAIL_OFFSET, RAIL_OFFSET + 7, RAIL_OFFSET + 14] };
const LANE_GAP = 26;
const SEGMENT_SHOWN = 8;
const CREEP_MIN = 0.1;
const CREEP_MAX = 0.9;
const CREEP_FRAME_MS = 66;

export class LineMap {
  constructor(host, { mode = "lines", label = "Saga lines" } = {}) {
    this.host = host;
    this.mode = mode;
    this.label = label;
    this.lines = [];
    this.tokens = new Map();
    this.width = 0;
    this.frame = null;
    this.svg = s("svg", { role: "group", "aria-label": label });
    this.tip = h("div", { class: "m-tip", role: "tooltip", hidden: true });
    host.append(this.svg, this.tip);
    this.offLive = onLive(() => this.wake());
    this.observer = new ResizeObserver(() => this.resize());
    this.observer.observe(host);
    this.tickBound = (time) => this.tick(time);
    this.uid = `lm${Math.random().toString(36).slice(2, 8)}`;
  }

  destroy() {
    this.observer.disconnect();
    this.offLive();
    cancelAnimationFrame(this.frame);
    clearTimeout(this.slowTimer);
    this.frame = null;
  }

  // lines: [{name, steps: [{name, compensate}], href(stepIndex), meta, decor: {stepIndex: {...}}}]
  setLines(lines) {
    const shape = JSON.stringify(lines.map((line) => [line.name, line.steps.map((step) => step.name)]));
    this.lines = lines;
    if (shape !== this.shape || !this.layout) {
      this.shape = shape;
      this.render();
    } else {
      this.decorate();
    }
  }

  resize() {
    const width = Math.round(this.host.clientWidth);
    if (width && width !== this.width) {
      this.width = width;
      if (this.lines.length) this.render();
    }
  }

  // spec: {id, line, target, rail, kind, creep?: {from, ms, dir}, leave?}
  // partial: "line|stationIndex" keys whose token list was cut short, where
  // the station counts (decor.moving / undoing) fill in the pill.
  setTokens(specs, partial) {
    this.tokensKnown = true;
    if (partial) this.partial = partial;
    const seen = new Set();
    for (const spec of specs) {
      seen.add(spec.id);
      const token = this.tokens.get(spec.id);
      if (token) {
        Object.assign(token, { leave: false }, spec);
      } else {
        this.tokens.set(spec.id, { pos: spec.from ?? spec.target, opacity: spec.from !== undefined && !reducedMotion.matches ? 0 : 1, ...spec });
      }
    }
    for (const [id, token] of this.tokens) {
      if (!seen.has(id) && !token.leave) token.leave = true;
    }
    this.wake();
  }

  // Replay: put one token exactly where the caller says, no animation.
  place(spec) {
    this.tokens.clear();
    if (spec) this.tokens.set(spec.id, { ...spec, pos: spec.target, opacity: 1, fixed: true });
    this.drawTokens();
  }

  setProgress(progress) {
    this.progress = progress;
    this.drawProgress();
  }

  wake() {
    clearTimeout(this.slowTimer);
    if (this.frame === null) this.frame = requestAnimationFrame(this.tickBound);
  }

  // Geometry

  computeLayout() {
    const width = this.width || Math.round(this.host.clientWidth) || 1000;
    const vertical = width < 700;
    const single = this.mode === "single";
    const lines = [];
    let height = 0;

    if (vertical) {
      const lineX = 26;
      let y = 0;
      for (const line of this.lines) {
        const head = single ? 0 : 52;
        const capTop = y + head + 6;
        const firstY = capTop + 46;
        const gap = 50;
        const stations = line.steps.map((step, index) => ({ x: lineX, y: firstY + index * gap }));
        const lastY = stations.length ? stations[stations.length - 1].y : firstY;
        const capBottom = lastY + 46;
        lines.push({
          line, vertical: true, head: { x: 0, y: y + 20 },
          start: { x: lineX, y: capTop }, end: { x: lineX, y: capBottom }, stations,
          axis: { x: 0, y: 1 }, normal: { x: 1, y: 0 }
        });
        y = capBottom + (single ? 22 : 40);
      }
      height = y;
      return { width, height, vertical, lines, single };
    }

    const wide = !single && width >= 1000;
    const nameCol = wide ? 236 : 0;
    const capL = nameCol + 12;
    const capR = width - 12;
    const inset = single ? 90 : 76;
    const rowH = single ? 140 : wide ? 112 : 138;
    const top = single ? 0 : wide ? 62 : 64;
    const lineDy = single ? 62 : wide ? 58 : 90;
    this.lines.forEach((line, row) => {
      const y = top + row * rowH + lineDy;
      const n = line.steps.length;
      const x0 = capL + inset;
      const x1 = capR - inset;
      const stations = line.steps.map((step, index) => ({ x: n === 1 ? (x0 + x1) / 2 : x0 + ((x1 - x0) * index) / (n - 1), y }));
      lines.push({
        line, vertical: false, wide,
        head: wide ? { x: 0, y } : { x: capL + 26, y: y - 66 },
        start: { x: capL, y }, end: { x: capR, y }, stations,
        axis: { x: 1, y: 0 }, normal: { x: 0, y: 1 }
      });
    });
    height = top + this.lines.length * rowH - (single ? 36 : 6);
    return { width, height, vertical, lines, single, wide, capL, capR, top };
  }

  points(geo) {
    return [geo.start, ...geo.stations, geo.end];
  }

  point(geo, pos, rail = "fwd") {
    const points = this.points(geo);
    const clamped = Math.max(-1, Math.min(geo.stations.length, pos));
    const i = Math.min(points.length - 2, Math.floor(clamped + 1));
    const t = clamped + 1 - i;
    const a = points[i];
    const b = points[i + 1];
    const offset = rail === "back" ? RAIL_OFFSET : 0;
    return {
      x: a.x + (b.x - a.x) * t + geo.normal.x * offset,
      y: a.y + (b.y - a.y) * t + geo.normal.y * offset
    };
  }

  // Static drawing

  render() {
    this.layout = this.computeLayout();
    const { width, height } = this.layout;
    const svg = this.svg;
    clear(svg);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.setAttribute("width", width);
    svg.setAttribute("height", height);

    this.layers = {
      base: s("g"),
      progress: s("g", { "aria-hidden": "true" }),
      stations: s("g"),
      tokens: s("g", { "aria-hidden": "true" })
    };
    svg.append(this.gradients(), this.layers.base, this.layers.progress, this.layers.stations, this.layers.tokens);

    if (!this.layout.vertical && !this.layout.single) {
      this.drawSharedTerminals();
      if (this.terminals) this.setTerminals(this.terminals);
    }
    for (const geo of this.layout.lines) this.drawLine(geo);
    this.decorate();
    this.drawProgress();
    this.drawTokens();
  }

  drawSharedTerminals() {
    const { lines, capL, capR } = this.layout;
    if (!lines.length) return;
    const top = lines[0].start.y - 20;
    const textY = lines[0].wide ? lines[0].start.y - 72 : lines[0].head.y - 24;
    const bottom = lines[lines.length - 1].start.y + 20;
    const base = this.layers.base;
    for (const geo of lines) {
      base.append(s("path", { class: "m-line", d: `M${capL} ${geo.start.y}H${capR}` }));
    }
    this.terminalText = {};
    for (const [key, x, anchor, label] of [["start", capL, "start", "started"], ["end", capR, "end", "completed"]]) {
      base.append(s("rect", { class: "m-cap", x: x - 9, y: top, width: 18, height: bottom - top, rx: 9 }));
      const num = s("tspan", { class: "m-cap-num" }, "0");
      const words = s("tspan", { class: "m-cap-label", dx: 6 }, label);
      const text = s("text", { x: anchor === "start" ? x - 9 : x + 9, y: textY, "text-anchor": anchor }, num, words);
      base.append(text);
      this.terminalText[key] = { num, words };
    }
  }

  setTerminals(values) {
    this.terminals = values;
    if (!this.terminalText) return;
    for (const key of ["start", "end"]) {
      const value = values[key];
      if (!value) continue;
      this.terminalText[key].num.textContent = value.n;
      this.terminalText[key].words.textContent = value.label;
    }
  }

  drawLine(geo) {
    const base = this.layers.base;
    const { line } = geo;
    const own = this.layout.vertical || this.layout.single;

    if (own) {
      base.append(s("path", { class: this.layout.single ? "m-line is-future" : "m-line", d: `M${geo.start.x} ${geo.start.y}L${geo.end.x} ${geo.end.y}` }));
      for (const point of [geo.start, geo.end]) {
        const w = geo.vertical ? 30 : 16;
        const hgt = geo.vertical ? 14 : 34;
        base.append(s("rect", { class: "m-cap", x: point.x - w / 2, y: point.y - hgt / 2, width: w, height: hgt, rx: Math.min(w, hgt) / 2 }));
      }
      if (this.layout.single) {
        const start = geo.vertical ? { x: geo.start.x + 26, y: geo.start.y + 5, a: "start" } : { x: geo.start.x, y: geo.start.y + 38, a: "middle" };
        const end = geo.vertical ? { x: geo.end.x + 26, y: geo.end.y + 5, a: "start" } : { x: geo.end.x, y: geo.end.y + 38, a: "middle" };
        base.append(s("text", { class: "m-cap-label", x: start.x, y: start.y, "text-anchor": start.a }, "Start"));
        base.append(s("text", { class: "m-cap-label", x: end.x, y: end.y, "text-anchor": end.a }, "End"));
      }
    }

    const lastBack = line.steps.reduce((last, step, index) => (step.compensate ? index : last), -1);
    if (lastBack >= 0) {
      const a = this.point(geo, -1, "back");
      const b = this.point(geo, lastBack, "back");
      base.append(s("path", { class: "m-rail", d: `M${a.x} ${a.y}L${b.x} ${b.y}` }));
    }

    if (!this.layout.single) this.drawHead(geo);

    geo.nodes = line.steps.map((step, index) => {
      const p = geo.stations[index];
      const href = line.href ? line.href(index) : null;
      const group = s(href ? "a" : "g", { class: "m-station", href });
      const hit = geo.vertical
        ? s("rect", { class: "m-hit", x: p.x - 16, y: p.y - 18, width: this.layout.width - p.x + 16, height: 36, rx: 6 })
        : s("rect", { class: "m-hit", x: p.x - 62, y: p.y - 58, width: 124, height: 100, rx: 6 });
      const halo = s("circle", { class: "m-halo", cx: p.x, cy: p.y, r: 17 });
      const dot = s("circle", { class: "m-dot", cx: p.x, cy: p.y, r: 7 });
      const label = geo.vertical
        ? s("text", { class: "m-name", x: p.x + 26, y: p.y + 5 }, step.name)
        : s("text", { class: "m-name", x: p.x, y: p.y + 36, "text-anchor": "middle" }, step.name);
      const decor = s("g", { class: "m-decor" });
      const title = s("title");
      group.append(title, hit, halo, dot, label, decor);
      const show = () => this.showTip(geo, index);
      const hide = () => this.hideTip(geo, index);
      group.addEventListener("pointerenter", show);
      group.addEventListener("focus", show);
      group.addEventListener("pointerleave", hide);
      group.addEventListener("blur", hide);
      group.addEventListener("keydown", (event) => { if (event.key === "Escape") hide(); });
      this.layers.stations.append(group);
      return { group, decor, title, dot, label };
    });
  }

  drawHead(geo) {
    const { line } = geo;
    const link = s("a", { class: "m-saga-link", href: line.sagaHref || null });
    const name = s("text", { class: "m-saga", x: geo.head.x, y: geo.wide || geo.vertical ? geo.head.y - (geo.vertical ? 0 : 4) : geo.head.y }, line.name);
    link.append(name);
    const meta = s("text", { class: "m-meta", x: geo.head.x, y: geo.vertical ? geo.head.y + 20 : geo.wide ? geo.head.y + 18 : geo.head.y + 18 });
    geo.meta = meta;
    this.layers.base.append(link, meta);
  }

  decorate() {
    if (!this.layout) return;
    for (const geo of this.layout.lines) {
      const line = this.lines.find((candidate) => candidate.name === geo.line.name) || geo.line;
      geo.line = line;
      if (geo.meta) {
        clear(geo.meta);
        for (const part of line.meta || []) geo.meta.append(s("tspan", { class: part.stop ? "m-meta-stop" : null }, part.text));
      }
      (geo.nodes || []).forEach((node, index) => {
        const decor = (line.decor && line.decor[index]) || {};
        const name = line.steps[index].name;
        clear(node.decor);
        node.group.setAttribute("class", ["m-station", decor.blocks ? "is-stopped" : "", decor.state ? `is-${decor.state}` : ""].join(" ").trim());
        node.title.textContent = decor.tip ? "" : decor.title || name;
        if (node.group.tagName === "a") node.group.setAttribute("aria-label", decor.title || name);
        if (decor.blocks) this.drawBlocks(geo, index, decor.blocks, node.decor);
        if (decor.stalled) this.drawIdle(geo, index, decor.stalled, node.decor);
      });
    }
    if (this.tipAt) this.showTip(this.tipAt.geo, this.tipAt.index);
  }

  // One failure marker per station: its height grows with the log of the
  // count and stops growing at a cap, the exact count lives in the tooltip.
  drawBlocks(geo, index, blocks, into) {
    const p = geo.stations[index];
    const text = compact(blocks);
    const grow = Math.log10(Math.max(1, blocks));
    if (geo.vertical) {
      const right = this.layout.width - 4;
      const size = Math.min(30, 8 + 6 * grow);
      const label = s("text", { class: "m-block-n", x: right, y: p.y + 5, "text-anchor": "end" }, `${text} failed`);
      const textW = (text.length + 7) * 7.2;
      into.append(label, s("rect", { class: "m-block", x: right - textW - 10, y: p.y - size / 2, width: 5, height: size, rx: 1.5 }));
      return;
    }
    const size = Math.min(geo.wide || this.layout.single ? 34 : 24, 8 + 7 * grow);
    const top = p.y - 14 - size;
    into.append(
      s("rect", { class: "m-block", x: p.x - 3, y: top, width: 6, height: size, rx: 2 }),
      s("text", { class: "m-block-n", x: p.x + 8, y: top + 10 }, text));
  }

  drawIdle(geo, index, n, into) {
    const p = geo.stations[index];
    const label = compact(n);
    const w = 16 + label.length * 7;
    const hgt = 16;
    const cx = geo.vertical ? p.x + 26 + w / 2 : p.x - 15 - w / 2;
    const cy = geo.vertical ? p.y - 16 : p.y;
    into.append(
      s("rect", { class: "t-idle", x: cx - w / 2, y: cy - hgt / 2, width: w, height: hgt, rx: hgt / 2 }),
      s("text", { class: "t-idle-n", x: cx, y: cy + 4, "text-anchor": "middle" }, label));
  }

  showTip(geo, index) {
    const decor = (geo.line.decor && geo.line.decor[index]) || {};
    if (!decor.tip) return;
    this.tipAt = { geo, index };
    const [head, ...rest] = decor.tip;
    clear(this.tip).append(h("b", {}, head), ...rest.map((line) => h("span", {}, line)));
    this.tip.hidden = false;
    const p = geo.stations[index];
    const hostW = this.host.clientWidth;
    const tipW = this.tip.offsetWidth;
    const tipH = this.tip.offsetHeight;
    const left = geo.vertical ? Math.min(p.x + 18, hostW - tipW) : Math.max(0, Math.min(hostW - tipW, p.x - tipW / 2));
    const above = p.y - 30 - tipH;
    const top = geo.vertical ? p.y + 20 : above >= -40 ? above : p.y + 44;
    this.tip.style.left = `${Math.round(left)}px`;
    this.tip.style.top = `${Math.round(top)}px`;
  }

  hideTip(geo, index) {
    if (!this.tipAt || this.tipAt.geo.line.name !== geo.line.name || this.tipAt.index !== index) return;
    this.tipAt = null;
    this.tip.hidden = true;
  }

  drawProgress() {
    if (!this.layers || !this.layout) return;
    const layer = this.layers.progress;
    clear(layer);
    if (!this.progress) return;
    const geo = this.layout.lines[0];
    if (!geo) return;
    const { reached, backFrom, backTo } = this.progress;
    if (reached > -1) {
      const a = this.point(geo, -1);
      const b = this.point(geo, reached);
      layer.append(s("path", { class: "m-line", d: `M${a.x} ${a.y}L${b.x} ${b.y}` }));
    }
    if (backFrom !== null && backFrom !== undefined && backTo < backFrom) {
      const a = this.point(geo, backFrom, "back");
      const b = this.point(geo, backTo, "back");
      layer.append(s("path", { class: "m-rail is-solid", d: `M${a.x} ${a.y}L${b.x} ${b.y}` }));
    }
  }

  // Motion

  // A token in a step sits along the segment by how long it has been there
  // against that step's median (creep.ms): just past the station on arrival,
  // halfway at the median, and closing in on the next station after that.
  effectiveTarget(token) {
    let target = token.target;
    const creep = token.creep;
    if (creep && !token.leave) {
      const elapsed = Math.max(0, clock() - creep.from);
      const share = 1 - 2 ** (-elapsed / creep.ms);
      target += creep.dir * (CREEP_MIN + (CREEP_MAX - CREEP_MIN) * share);
    }
    return target;
  }

  tick(now) {
    this.frame = null;
    const dt = Math.min(0.1, (now - (this.lastTime || now)) / 1000);
    this.lastTime = now;
    let busy = false;
    let creeping = false;
    const reduce = reducedMotion.matches;
    const running = isLive();

    for (const [id, token] of this.tokens) {
      if (token.fixed) continue;
      const target = this.effectiveTarget(token);
      const gap = target - token.pos;
      if (reduce) {
        token.pos = target;
      } else if (Math.abs(gap) > 0.004) {
        const speed = Math.max(0.12, Math.min(3, Math.abs(gap) * 2.2));
        token.pos += Math.sign(gap) * Math.min(Math.abs(gap), speed * dt);
        busy = true;
      } else {
        token.pos = target;
      }
      if (token.creep && !token.leave && !reduce && running) creeping = true;

      if (token.leave) {
        const arrived = Math.abs(target - token.pos) < 0.02;
        if (reduce) {
          this.tokens.delete(id);
          continue;
        }
        if (arrived) {
          token.hold = (token.hold || 0) + dt;
          if (token.hold > (token.linger || 0.2)) token.opacity -= dt * 2.2;
        }
        if (token.opacity <= 0) {
          this.tokens.delete(id);
          continue;
        }
        busy = true;
      } else if (token.opacity < 1) {
        token.opacity = reduce ? 1 : Math.min(1, token.opacity + dt * 3);
        busy = true;
      }
    }

    this.drawTokens();
    if (busy) {
      this.frame = requestAnimationFrame(this.tickBound);
    } else if (creeping) {
      this.lastTime = null;
      this.slowTimer = setTimeout(() => this.wake(), CREEP_FRAME_MS);
    } else {
      this.lastTime = null;
    }
  }

  // Tokens leaving the same station on the same rail form a segment group.
  // The group shows its first SEGMENT_SHOWN tokens (stable by id) in up to
  // three lanes and folds the rest, plus any the poll did not list, into a pill.
  groupTokens(byLine) {
    const groups = new Map();
    const loose = [];
    const group = (geo, rail, target) => {
      const key = `${geo.line.name}|${rail}|${target}`;
      if (!groups.has(key)) groups.set(key, { geo, rail, target, tokens: [] });
      return groups.get(key);
    };
    for (const token of this.tokens.values()) {
      const geo = byLine.get(token.line);
      if (!geo) continue;
      if (token.kind === "idle" && !token.leave) continue;
      if (token.fixed || token.leave || this.layout.single) loose.push({ token, geo });
      else group(geo, token.rail, token.target).tokens.push(token);
    }
    if (!this.layout.single && this.tokensKnown) {
      for (const geo of this.layout.lines) {
        for (const [index, decor] of Object.entries(geo.line.decor || {})) {
          if (!this.isPartial(geo, index)) continue;
          if (decor.moving) group(geo, "fwd", Number(index));
          if (decor.undoing) group(geo, "back", Number(index));
        }
      }
    }
    return { groups: [...groups.values()], loose };
  }

  drawTokens() {
    if (!this.layers || !this.layout) return;
    const layer = this.layers.tokens;
    const byLine = new Map(this.layout.lines.map((geo) => [geo.line.name, geo]));
    const { groups, loose } = this.groupTokens(byLine);
    clear(layer);

    for (const { token, geo } of loose) {
      const p = this.point(geo, token.pos, token.rail);
      this.drawToken(layer, geo, token, p, { trail: true });
    }

    for (const { geo, rail, target, tokens } of groups) {
      const sorted = tokens.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
      const shown = sorted.slice(0, SEGMENT_SHOWN);
      const hidden = sorted.slice(SEGMENT_SHOWN);
      const decor = (geo.line.decor || {})[target] || {};
      const known = this.isPartial(geo, target) ? (rail === "back" ? decor.undoing : decor.moving) : 0;

      // Front-most token first. A token that would overlap the one ahead takes
      // the first lane with room; when all three are taken it queues behind
      // the roomiest lane, and one that would back up onto the station folds
      // into the pill instead.
      const dir = rail === "back" ? -1 : 1;
      const ahead = (p) => (p.x * geo.axis.x + p.y * geo.axis.y) * dir;
      const floor = ahead(this.point(geo, target)) + 10;
      const ceiling = Math.max(floor, ahead(this.point(geo, target + dir)) - (geo.vertical ? 22 : 64));
      const candidates = shown.map((token) => {
        const p = this.point(geo, token.pos);
        return { token, p, raw: ahead(p), at: Math.min(ahead(p), ceiling) };
      }).sort((a, b) => b.at - a.at);
      const front = [Infinity, Infinity, Infinity];
      const placed = [];
      let folded = 0;
      for (const item of candidates) {
        let lane = front.findIndex((at) => at - item.at >= LANE_GAP);
        let at = item.at;
        if (lane < 0) {
          lane = front.indexOf(Math.max(...front));
          at = front[lane] - LANE_GAP;
          if (at < floor) {
            folded++;
            continue;
          }
        }
        front[lane] = at;
        const shift = (item.raw - at) * dir;
        item.p = { x: item.p.x - geo.axis.x * shift, y: item.p.y - geo.axis.y * shift };
        item.lane = lane;
        placed.push(item);
      }
      const rest = Math.max(hidden.length, (known || 0) - shown.length) + folded;
      const fanned = placed.some((item) => item.lane > 0);
      for (const { token, p, lane } of placed) {
        const offset = LANES[rail][lane];
        const q = { x: p.x + geo.normal.x * offset, y: p.y + geo.normal.y * offset };
        this.drawToken(layer, geo, token, q, { trail: !fanned, thin: fanned });
      }
      if (rest > 0) this.drawPill(layer, geo, rail, target, rest, hidden);
    }
  }

  isPartial(geo, index) {
    return !this.partial || this.partial.has(`${geo.line.name}|${index}`);
  }

  drawToken(layer, geo, token, p, { trail, thin = false }) {
    const long = token.big ? 24 : thin ? 18 : 20;
    const short = token.big ? 13 : thin ? 6 : 12;
    const w = geo.vertical ? short : long;
    const hgt = geo.vertical ? long : short;
    const opacity = token.opacity < 1 ? Math.max(0, token.opacity).toFixed(3) : null;
    const moving = token.kind === "move" || token.kind === "back";
    if (moving && trail) {
      const dir = token.kind === "back" ? -1 : 1;
      const length = token.big ? 70 : 46;
      const tx = p.x - geo.axis.x * dir * (length / 2 + long / 2 - 4);
      const ty = p.y - geo.axis.y * dir * (length / 2 + long / 2 - 4);
      const tw = geo.vertical ? 4 : length;
      const th = geo.vertical ? length : 4;
      const grad = `${this.uid}-${geo.vertical ? "v" : "h"}-${dir > 0 ? "f" : "b"}-${token.kind}`;
      layer.append(s("rect", { fill: `url(#${grad})`, x: tx - tw / 2, y: ty - th / 2, width: tw, height: th, rx: 2, opacity }));
    }
    const cls = ["t-token", token.kind && token.kind !== "move" ? `is-${token.kind}` : "", thin ? "is-thin" : ""].join(" ").trim();
    layer.append(s("rect", { class: cls, x: p.x - w / 2, y: p.y - hgt / 2, width: w, height: hgt, rx: short / 2, opacity }));
  }

  drawPill(layer, geo, rail, target, rest, hidden) {
    const dir = rail === "back" ? -1 : 1;
    const mean = hidden.length ? hidden.reduce((sum, token) => sum + token.pos, 0) / hidden.length : target + dir * 0.45;
    const pos = target + dir * Math.min(0.85, Math.max(0.12, (mean - target) * dir));
    const p = this.point(geo, pos);
    const text = `+${compact(rest)} ${rail === "back" ? "undoing" : "running"}`;
    const w = Math.round(text.length * 6.6 + 16);
    const hgt = 18;
    let cx;
    let cy;
    if (geo.vertical) {
      const station = geo.stations[target];
      const name = geo.line.steps[target].name;
      cx = station.x + 26 + name.length * 7.2 + 10 + w / 2;
      cy = station.y + 1;
    } else {
      cx = p.x;
      cy = p.y + (rail === "back" ? 48 : -36);
    }
    layer.append(
      s("rect", { class: rail === "back" ? "t-more is-back" : "t-more", x: cx - w / 2, y: cy - hgt / 2, width: w, height: hgt, rx: hgt / 2 }),
      s("text", { class: rail === "back" ? "t-more-n is-back" : "t-more-n", x: cx, y: cy + 4, "text-anchor": "middle" }, text));
  }

  gradients() {
    const defs = s("defs");
    for (const vertical of [false, true]) {
      for (const dir of [1, -1]) {
        for (const kind of ["move", "back"]) {
          const from = dir > 0 ? "0" : "1";
          const to = dir > 0 ? "1" : "0";
          const grad = s("linearGradient", {
            id: `${this.uid}-${vertical ? "v" : "h"}-${dir > 0 ? "f" : "b"}-${kind}`,
            x1: vertical ? 0 : from, x2: vertical ? 0 : to, y1: vertical ? from : 0, y2: vertical ? to : 0
          },
          s("stop", { offset: 0, class: `g-trail-${kind}`, "stop-opacity": 0 }),
          s("stop", { offset: 1, class: `g-trail-${kind}`, "stop-opacity": 0.9 }));
          defs.append(grad);
        }
      }
    }
    return defs;
  }
}
