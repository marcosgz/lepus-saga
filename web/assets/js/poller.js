const STORAGE_KEY = "lepus-saga:poll";

function stored() {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY);
    return value === null ? null : Number(value);
  } catch {
    return null;
  }
}

function remember(seconds) {
  try {
    window.localStorage.setItem(STORAGE_KEY, String(seconds));
    return true;
  } catch {
    return false;
  }
}

export class Poller {
  constructor({ intervals, fallback, onState }) {
    this.intervals = intervals;
    const saved = stored();
    this.interval = intervals.includes(saved) ? saved : fallback;
    this.onState = onState;
    this.task = null;
    this.timer = null;
    this.busy = false;
    this.pending = false;
    this.lastRun = null;
    this.failed = false;
    document.addEventListener("visibilitychange", () => this.visibilityChanged());
  }

  setInterval(seconds) {
    this.interval = seconds;
    remember(seconds);
    this.schedule();
    this.report();
  }

  watch(task) {
    this.task = task;
    this.schedule();
  }

  async runNow() {
    if (this.busy) {
      this.pending = true;
      return;
    }
    this.busy = true;
    do {
      this.pending = false;
      if (this.task) await this.attempt(this.task);
    } while (this.pending);
    this.busy = false;
    this.report();
  }

  async attempt(task) {
    try {
      await task();
      this.failed = false;
      this.lastRun = new Date();
    } catch (error) {
      this.failed = true;
      console.error(error);
    }
  }

  schedule() {
    clearTimeout(this.timer);
    this.timer = null;
    if (!this.task || !this.interval || document.hidden) return;
    this.timer = setTimeout(async () => {
      await this.runNow();
      this.schedule();
    }, this.interval * 1000);
  }

  visibilityChanged() {
    if (document.hidden) {
      clearTimeout(this.timer);
      this.timer = null;
    } else if (this.interval) {
      this.runNow().then(() => this.schedule());
    }
    this.report();
  }

  state() {
    if (!this.interval) return "off";
    if (document.hidden) return "paused";
    return this.failed ? "error" : "live";
  }

  report() {
    this.onState?.(this.state(), this.lastRun);
  }
}

export function serial() {
  let tail = Promise.resolve();
  return (task) => {
    const run = tail.then(task);
    tail = run.catch(() => null);
    return run;
  };
}
