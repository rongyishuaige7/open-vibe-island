"use strict";

// Open Island bridge for PI Desktop.
//
// PI Desktop has no URL scheme, so focusing a specific conversation needs help
// from inside the app. This plugin serves one Unix socket next to the Open
// Island bridge socket and answers `focus` by calling session/open.
//
// It is deliberately tiny: no session content is read or forwarded. Reading
// sessions stays with Open Island's read-only SQLite poller, which needs no
// permission from PI Desktop at all.

const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");

const COMMAND_SOCKET = path.join(
  process.env.HOME || "",
  "Library",
  "Application Support",
  "OpenIsland",
  "pi-desktop-plugin.sock"
);

let server = null;
let logStream = null;

function log(message) {
  try {
    if (!logStream) {
      const directory = path.dirname(COMMAND_SOCKET);
      fs.mkdirSync(directory, { recursive: true });
      logStream = fs.createWriteStream(path.join(directory, "pi-desktop-plugin.log"), { flags: "a" });
    }
    logStream.write(`[${new Date().toISOString()}] ${message}\n`);
  } catch {}
}

async function handle(message) {
  if (!message || typeof message !== "object") {
    return false;
  }
  if (message.command !== "focus") {
    return false;
  }
  const sessionID = typeof message.sessionID === "string" ? message.sessionID.trim() : "";
  if (!sessionID) {
    return false;
  }
  try {
    // session/open takes the id as a bare argument; an object shape returns
    // "Session not found" even for the active conversation.
    await pi.desktop.invoke({ operation: "session/open", args: [sessionID] });
    log(`focused ${sessionID}`);
    return true;
  } catch (error) {
    log(`focus failed for ${sessionID}: ${error?.message ?? error}`);
    return false;
  }
}

function startServer() {
  try {
    fs.mkdirSync(path.dirname(COMMAND_SOCKET), { recursive: true });
  } catch {}
  try {
    fs.unlinkSync(COMMAND_SOCKET);
  } catch {}

  server = net.createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", async (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        let message = null;
        try {
          message = JSON.parse(line);
        } catch {
          message = null;
        }
        const ok = await handle(message);
        try {
          socket.write(JSON.stringify({ ok }) + "\n");
        } catch {}
      }
    });
    socket.on("error", () => {});
  });
  server.on("error", (error) => log(`server error: ${error?.message ?? error}`));
  server.listen(COMMAND_SOCKET, () => log(`listening on ${COMMAND_SOCKET}`));
}

async function onLoad() {
  startServer();
}

async function onUnload() {
  try {
    server?.close();
  } catch {}
  server = null;
  try {
    fs.unlinkSync(COMMAND_SOCKET);
  } catch {}
  try {
    logStream?.end();
  } catch {}
  logStream = null;
}

module.exports = { onLoad, onUnload };
