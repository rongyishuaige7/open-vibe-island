// Open Island bridge for DeepSeek Harness.
//
// This is a host-only Cordis plugin. It listens to the DSH session store,
// publishes visible session activity, and maintains a local-day token ledger
// from DSH's `tokenUsage` projection. Everything is best-effort: if Open
// Island is not running, the plugin keeps DSH unchanged and retries on the
// next event or snapshot.
import { connect } from "node:net";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";

export const name = "open-island-dsh";
export const inject = ["sessions"];

const SOCKET_PATH =
  process.env.OPEN_ISLAND_SOCKET_PATH ||
  join(process.env.HOME || homedir(), "Library", "Application Support", "OpenIsland", "bridge.sock");
const DSH_HOME = process.env.DSH_HOME || join(process.env.HOME || homedir(), ".dsh");
const LEDGER_PATH = join(DSH_HOME, "open-island-today-tokens.json");
const SNAPSHOT_INTERVAL_MS = 10_000;
const MAX_QUEUE = 100;

let ledger = loadLedger();
const sessionState = new Map();
const titles = new Map();
const queue = [];
let flushing = false;

function localDayKey(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function startOfLocalDay(date = new Date()) {
  const start = new Date(date);
  start.setHours(0, 0, 0, 0);
  return start.getTime();
}

function emptyLedger() {
  return { day: localDayKey(), sessions: {} };
}

function loadLedger() {
  try {
    if (!existsSync(LEDGER_PATH)) return emptyLedger();
    const parsed = JSON.parse(readFileSync(LEDGER_PATH, "utf8"));
    if (!parsed || parsed.day !== localDayKey() || typeof parsed.sessions !== "object" || parsed.sessions === null) {
      return emptyLedger();
    }
    return parsed;
  } catch {
    return emptyLedger();
  }
}

function saveLedger() {
  try {
    mkdirSync(dirname(LEDGER_PATH), { recursive: true });
    const tempPath = `${LEDGER_PATH}.tmp`;
    writeFileSync(tempPath, JSON.stringify(ledger));
    renameSync(tempPath, LEDGER_PATH);
  } catch {
    // Best effort: a read-only DSH home must never break the agent.
  }
}

function ensureDay() {
  if (ledger.day === localDayKey()) return;
  const previous = ledger;
  ledger = emptyLedger();
  // Carry today's already-counted totals only when the clock moved backwards
  // or the session started before midnight; new sessions are seeded from
  // their current cumulative usage when first seen.
  for (const [id, entry] of Object.entries(previous.sessions || {})) {
    if (entry && Number.isFinite(entry.total)) {
      ledger.sessions[id] = { total: 0, cache: 0, lastSeen: entry.total, lastCache: entry.cache || 0 };
    }
  }
  saveLedger();
}

function number(value) {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function usageFromContext(ctx, session) {
  try {
    const projections = (typeof ctx?.get === "function" ? ctx.get("sessionProjections") : undefined)
      ?? ctx?.sessionProjections;
    const rawUsage = projections?.stateOf?.(session, "tokenUsage");
    // Host projection state nests the buckets under `totals`; the wire view
    // is flat. Accept both so the plugin keeps working across DSH versions.
    const usage = rawUsage?.totals ?? rawUsage;
    if (!usage) return null;
    return {
      total: number(usage.uncachedInputTokens) + number(usage.outputTokens)
        + number(usage.cacheReadTokens) + number(usage.cacheWriteTokens),
      cache: number(usage.cacheReadTokens),
    };
  } catch {
    return null;
  }
}

function isSubagent(session) {
  return session?.header?.origin === "subagent";
}

function sessionID(session) {
  return session?.header?.id;
}

function recordUsage(ctx, session) {
  const id = sessionID(session);
  if (!id) return;
  ensureDay();
  const usage = usageFromContext(ctx, session);
  if (!usage) return;

  let entry = ledger.sessions[id];
  if (!entry) {
    const createdAt = Number(session?.header?.createdAt);
    const createdToday = Number.isFinite(createdAt) && createdAt >= startOfLocalDay();
    entry = {
      total: createdToday ? usage.total : 0,
      cache: createdToday ? usage.cache : 0,
      lastSeen: usage.total,
      lastCache: usage.cache,
    };
    ledger.sessions[id] = entry;
    saveLedger();
    return;
  }

  const delta = Math.max(0, usage.total - (Number(entry.lastSeen) || 0));
  const cacheDelta = Math.max(0, usage.cache - (Number(entry.lastCache) || 0));
  if (delta > 0) entry.total = (Number(entry.total) || 0) + delta;
  if (cacheDelta > 0) entry.cache = (Number(entry.cache) || 0) + cacheDelta;
  entry.lastSeen = usage.total;
  entry.lastCache = usage.cache;
  if (delta > 0 || cacheDelta > 0) saveLedger();
}

function todayTotals() {
  ensureDay();
  let totalTokens = 0;
  let cacheReadTokens = 0;
  let sessionCount = 0;
  for (const entry of Object.values(ledger.sessions || {})) {
    if (!entry) continue;
    const total = number(entry.total);
    totalTokens += total;
    cacheReadTokens += number(entry.cache);
    if (total > 0) sessionCount += 1;
  }
  return { totalTokens, cacheReadTokens, sessionCount };
}

function textOfContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join(" ");
}

function clip(value, limit = 160) {
  if (typeof value !== "string") return "";
  const text = value.replace(/\s+/g, " ").trim();
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}

function titleFor(ctx, session) {
  const id = sessionID(session);
  const known = titles.get(id);
  if (known) return known;

  const projections = (typeof ctx?.get === "function" ? ctx.get("sessionProjections") : undefined)
    ?? ctx?.sessionProjections;
  const projectedTitle = projections?.stateOf?.(session, "title");
  const projected = typeof projectedTitle === "string" ? projectedTitle : projectedTitle?.title;
  if (typeof projected === "string" && projected.trim()) return projected.trim();

  const meta = projections?.stateOf?.(session, "sessionListMetadata");
  if (typeof meta?.title === "string" && meta.title.trim()) return meta.title.trim();

  // Do not use the cwd basename as the conversation title: the island already
  // renders the project separately as the workspace, and a project title would
  // read as "project · project".
  return undefined;
}

function summaryFor(id) {
  return sessionState.get(id)?.summary || "Working…";
}

function phaseFor(id) {
  return sessionState.get(id)?.phase || "running";
}

function snapshotOf(ctx, session) {
  const id = sessionID(session);
  const state = sessionState.get(id) || {};
  const title = titleFor(ctx, session);
  return {
    sessionID: id,
    ...(title ? { title } : {}),
    ...(session?.header?.cwd ? { cwd: session.header.cwd } : {}),
    ...(session?.header?.cwd ? { workspaceName: basename(session.header.cwd) } : {}),
    summary: state.summary || "Working…",
    phase: state.phase || "running",
    createdAt: Number.isFinite(session?.header?.createdAt) ? session.header.createdAt : undefined,
    updatedAt: Date.now(),
    ...(session?.header?.parentSession ? { parentSessionID: session.header.parentSession } : {}),
    isSubagent: isSubagent(session),
  };
}

function enqueue(payload) {
  queue.push(payload);
  if (queue.length > MAX_QUEUE) queue.shift();
  void flush();
}

function sendOnce(payload) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve();
    };

    let sock;
    try {
      sock = connect({ path: SOCKET_PATH }, () => {
        const envelope = {
          type: "command",
          command: { type: "processDSHHook", dshHook: payload },
        };
        try {
          sock.end(JSON.stringify(envelope) + "\n");
        } catch {
          finish();
        }
      });
    } catch {
      finish();
      return;
    }

    sock.on("end", finish);
    sock.on("close", finish);
    sock.on("error", finish);
    sock.setTimeout(500, () => {
      try { sock.destroy(); } catch {}
      finish();
    });
  });
}

async function flush() {
  if (flushing) return;
  flushing = true;
  try {
    while (queue.length > 0) {
      const payload = queue.shift();
      await sendOnce(payload);
    }
  } finally {
    flushing = false;
  }
}

function emit(ctx, event, session) {
  recordUsage(ctx, session);
  enqueue({
    event,
    ...(session ? { session: snapshotOf(ctx, session) } : {}),
    todayTokens: todayTotals(),
    timestamp: Date.now(),
  });
}

function emitSnapshot(ctx, sessions) {
  ensureDay();
  for (const session of sessions) recordUsage(ctx, session);
  enqueue({
    event: "snapshot",
    sessions: sessions.map((session) => snapshotOf(ctx, session)),
    todayTokens: todayTotals(),
    timestamp: Date.now(),
  });
}


function hydrateSessionState(ctx, session) {
  const id = sessionID(session);
  if (!id) return;
  const state = { phase: "completed", summary: "Ready", lastAssistant: "" };

  // A generated title is cheap to read and avoids scanning the whole log.
  try {
    const projections = (typeof ctx?.get === "function" ? ctx.get("sessionProjections") : undefined)
      ?? ctx?.sessionProjections;
    const projectedTitle = projections?.stateOf?.(session, "title");
    const title = typeof projectedTitle === "string" ? projectedTitle : projectedTitle?.title;
    if (typeof title === "string" && title.trim()) titles.set(id, title.trim());
  } catch {}

  let events = [];
  try {
    const seq = Number(session?.seq);
    if (Number.isSafeInteger(seq) && seq > 0 && typeof session.eventAt === "function") {
      // Only the tail decides the current phase and summary. Keep boot cost
      // bounded for very long sessions.
      const start = Math.max(0, seq - 500);
      for (let index = start; index < seq; index += 1) {
        const event = session.eventAt(index);
        if (event) events.push(event);
      }
    } else if (typeof session.snapshotEvents === "function") {
      events = session.snapshotEvents();
    } else if (Array.isArray(session.events)) {
      events = session.events;
    }
  } catch {}

  for (const event of events) {
    const type = event?.type;
    const data = event?.data || {};
    if (type === "session/title" && typeof data.title === "string" && data.title.trim()) {
      titles.set(id, data.title.trim());
    } else if (type === "user/message" && data.source?.kind === "user") {
      const text = clip(textOfContent(data.content));
      if (text && !titles.has(id)) titles.set(id, text);
    } else if (type === "turn/start") {
      state.phase = "running";
      state.summary = "Thinking…";
      state.lastAssistant = "";
    } else if (type === "tool/call") {
      state.phase = "running";
      state.summary = data.name ? `Running ${data.name}` : "Running a tool";
    } else if (type === "tool/result") {
      state.phase = "running";
      state.summary = data.error ? "Tool failed" : "Tool finished";
    } else if (type === "assistant/message") {
      const text = clip(textOfContent(data.message?.content));
      if (text) state.lastAssistant = text;
      state.phase = "running";
      state.summary = text || "Replied";
    } else if (type === "turn/end") {
      const kind = data.reason?.kind || "completed";
      state.phase = "completed";
      state.summary = kind === "completed"
        ? (state.lastAssistant || "Turn completed")
        : kind === "aborted" ? "Stopped"
        : kind === "blocked" ? "Blocked"
        : kind === "max-tokens" ? "Reached the output token limit"
        : kind === "error" ? (data.reason?.error?.message ? clip(data.reason.error.message, 120) : "Turn failed")
        : "Turn finished";
    }
  }

  sessionState.set(id, state);
}

function handleEvent(ctx, session, event) {
  if (isSubagent(session)) return;
  const id = sessionID(session);
  if (!id) return;
  recordUsage(ctx, session);
  const state = sessionState.get(id) || { phase: "running", summary: "Working…" };
  const type = event?.type;
  const data = event?.data || {};

  if (type === "session/title" && typeof data.title === "string" && data.title.trim()) {
    titles.set(id, data.title.trim());
    return;
  }

  if (type === "user/message" && data.source?.kind === "user") {
    const text = clip(textOfContent(data.content));
    if (text && !titles.has(id)) titles.set(id, text);
    return;
  }

  if (type === "turn/start") {
    state.phase = "running";
    state.summary = "Thinking…";
    state.lastAssistant = "";
    sessionState.set(id, state);
    emit(ctx, "activity", session);
    return;
  }

  if (type === "tool/call") {
    state.phase = "running";
    state.summary = data.name ? `Running ${data.name}` : "Running a tool";
    sessionState.set(id, state);
    emit(ctx, "activity", session);
    return;
  }

  if (type === "tool/result") {
    state.phase = "running";
    state.summary = data.error ? "Tool failed" : "Tool finished";
    sessionState.set(id, state);
    emit(ctx, "activity", session);
    return;
  }

  if (type === "assistant/message") {
    const text = clip(textOfContent(data.message?.content));
    if (text) state.lastAssistant = text;
    state.phase = "running";
    state.summary = text || "Replied";
    sessionState.set(id, state);
    emit(ctx, "activity", session);
    return;
  }

  if (type === "turn/end") {
    const kind = data.reason?.kind || "completed";
    state.phase = "completed";
    if (kind === "completed") {
      state.summary = state.lastAssistant || "Turn completed";
    } else if (kind === "aborted") {
      state.summary = "Stopped";
    } else if (kind === "blocked") {
      state.summary = "Blocked";
    } else if (kind === "max-tokens") {
      state.summary = "Reached the output token limit";
    } else if (kind === "error") {
      state.summary = data.reason?.error?.message
        ? clip(data.reason.error.message, 120)
        : "Turn failed";
    } else {
      state.summary = "Turn finished";
    }
    sessionState.set(id, state);
    emit(ctx, "activity", session);
  }
}

export function apply(ctx) {
  try {
    for (const session of ctx.sessions.list()) {
      if (isSubagent(session)) continue;
      hydrateSessionState(ctx, session);
      recordUsage(ctx, session);
    }
  } catch {}

  ctx.on("session/created", (session) => {
    if (isSubagent(session)) return;
    const id = sessionID(session);
    sessionState.set(id, { phase: "running", summary: "Started" });
    recordUsage(ctx, session);
    emit(ctx, "sessionStart", session);
  });

  ctx.on("session/event", (session, event) => {
    try {
      handleEvent(ctx, session, event);
    } catch {
      // Fail open: observability must never break the session.
    }
  });

  ctx.on("session/disposed", (session) => {
    if (isSubagent(session)) return;
    const id = sessionID(session);
    recordUsage(ctx, session);
    const state = sessionState.get(id) || { phase: "completed", summary: "Session ended" };
    state.phase = "completed";
    state.summary = state.summary || "Session ended";
    sessionState.set(id, state);
    emit(ctx, "sessionEnd", session);
    sessionState.delete(id);
    titles.delete(id);
  });

  const sendSnapshot = () => {
    try {
      emitSnapshot(ctx, ctx.sessions.list().filter((session) => !isSubagent(session)));
    } catch {}
  };

  if (typeof ctx.effect === "function") {
    ctx.effect(() => {
      sendSnapshot();
      const timer = setInterval(sendSnapshot, SNAPSHOT_INTERVAL_MS);
      timer.unref?.();
      return () => clearInterval(timer);
    }, "open-island-dsh: snapshots");
  } else {
    sendSnapshot();
    const timer = setInterval(sendSnapshot, SNAPSHOT_INTERVAL_MS);
    timer.unref?.();
  }
}
