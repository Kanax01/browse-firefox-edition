#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_ARG=""
AGENTS=""
SKIP_PROJECT=0
SKIP_EXTENSION=0
MODIFY_PATH=1
STARTUP=1
PORT_ARG=""
FIREFOX_ARG=""
PROFILE_INDEX=""
SELECTED_NAME=""
SELECTED_PATH=""
SELECTED_RUNNING=""
USER_JS=""
USER_JS_BAK=""
USER_JS_CREATED=0
STARTUP_FILE=""

usage() {
  cat <<'USAGE'
usage: ./setup-full.sh [options]

Installs or updates browse on this computer (the browse CLI and the MCP entry
for your agents) and loads the Firefox build of the extension into a Firefox
profile you pick.

  --profile <name|path>   profile to install into, skipping the picker
  --extension-only        only build and load the extension
  --project-only          only install or update browse for your agents
  --agents <list|none>    agents to configure, e.g. "claude,codex" or none
  --no-modify-path        do not add ~/.local/bin to PATH
  --no-startup            do not make the browse relay start at login
  --port <n>              debugger port to launch Firefox with
  --firefox <path>        Firefox binary to use
  -h, --help              this text

Re-running updates everything: it rebuilds, reinstalls, and loads the add-on
again into the profile you choose.
USAGE
}

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

restore_user_js() {
  if [ -n "$USER_JS" ]; then
    if [ "$USER_JS_CREATED" -eq 1 ]; then rm -f "$USER_JS"; elif [ -n "$USER_JS_BAK" ]; then mv -f "$USER_JS_BAK" "$USER_JS"; fi
  fi
  USER_JS=""
  return 0
}

cleanup() {
  restore_user_js
  if [ -n "$PROFILE_INDEX" ]; then rm -f "$PROFILE_INDEX"; fi
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; PROFILE_ARG="$2"; shift 2 ;;
    --profile=*) PROFILE_ARG="${1#*=}"; shift ;;
    --agents) [ $# -ge 2 ] || die "--agents needs a value"; AGENTS="$2"; shift 2 ;;
    --agents=*) AGENTS="${1#*=}"; shift ;;
    --port) [ $# -ge 2 ] || die "--port needs a value"; PORT_ARG="$2"; shift 2 ;;
    --port=*) PORT_ARG="${1#*=}"; shift ;;
    --firefox) [ $# -ge 2 ] || die "--firefox needs a value"; FIREFOX_ARG="$2"; shift 2 ;;
    --firefox=*) FIREFOX_ARG="${1#*=}"; shift ;;
    --extension-only) SKIP_PROJECT=1; shift ;;
    --project-only) SKIP_EXTENSION=1; shift ;;
    --no-modify-path) MODIFY_PATH=0; shift ;;
    --startup) STARTUP=1; shift ;;
    --no-startup) STARTUP=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

[ -f "$ROOT/package.json" ] && [ -d "$ROOT/cli" ] || die "run this from the browse checkout (no package.json/cli next to $0)"

run_bun() {
  if command -v bun >/dev/null 2>&1; then bun "$@"; else npx --yes bun@1.4.4 "$@"; fi
}

need_node() {
  if ! command -v node >/dev/null 2>&1; then
    die "browse needs Node.js 22 or newer and found no node on PATH
  install one without touching the system Node:
    curl -fsSL https://fnm.vercel.app/install | bash    # then: fnm install 24
  or grab a tarball from https://nodejs.org/en/download and put its bin/ first on PATH"
  fi
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$major" -ge 22 ] || die "browse needs Node.js 22 or newer; found $(node -v) at $(command -v node)
  install a newer Node without touching the system one:
    curl -fsSL https://fnm.vercel.app/install | bash    # then: fnm install 24
  or grab a tarball from https://nodejs.org/en/download and put its bin/ first on PATH"
}

find_firefox() {
  if [ -n "$FIREFOX_ARG" ]; then printf '%s' "$FIREFOX_ARG"; return; fi
  local candidate
  for candidate in "$(command -v firefox 2>/dev/null || true)" /usr/bin/firefox /usr/lib/firefox/firefox /opt/firefox/firefox /Applications/Firefox.app/Contents/MacOS/firefox; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
  done
  die "could not find Firefox; pass --firefox /path/to/firefox"
}

profile_roots() {
  local config="${XDG_CONFIG_HOME:-$HOME/.config}"
  local candidate
  for candidate in "$config/mozilla/firefox" "$HOME/.mozilla/firefox"; do
    [ -d "$candidate" ] && printf '%s\n' "$candidate"
  done
}

list_profiles() {
  local root
  while IFS= read -r root; do
    python3 - "$root" <<'PY'
import glob, os, shutil, sqlite3, sys, tempfile

root = sys.argv[1]
entries = {}


def remember(path, name, is_default=False):
    path = os.path.abspath(os.path.normpath(os.path.expanduser(path)))
    entry = entries.setdefault(path, {"name": name or os.path.basename(path), "order": len(entries), "default": False})
    if name and (not entry["name"] or entry["name"] == os.path.basename(path)):
        entry["name"] = name
    entry["default"] = entry["default"] or is_default


def add(path, name, is_default=False, force=False):
    full = path if path.startswith("/") else os.path.join(root, path)
    remember(full, name, is_default)
    if force and name:
        entries[os.path.abspath(os.path.normpath(os.path.expanduser(full)))]["name"] = name


ini = os.path.join(root, "profiles.ini")
if os.path.exists(ini):
    section = None
    data = {}
    for raw in open(ini, encoding="utf-8", errors="replace"):
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            if section and section.startswith("Profile") and data.get("Path"):
                add(data["Path"], data.get("Name"), data.get("Default") == "1")
            section, data = line[1:-1], {}
            continue
        if "=" in line and section:
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    if section and section.startswith("Profile") and data.get("Path"):
        add(data["Path"], data.get("Name"), data.get("Default") == "1")

for db in glob.glob(os.path.join(root, "Profile Groups", "*.sqlite")):
    tmp = tempfile.mkdtemp(prefix="browse-profiles-")
    copy = os.path.join(tmp, "profiles.sqlite")
    try:
        shutil.copy(db, copy)
        for suffix in ("-wal", "-shm"):
            if os.path.exists(db + suffix):
                shutil.copy(db + suffix, copy + suffix)
        for path, name in sqlite3.connect(copy).execute("select path, name from Profiles"):
            add(path, name, force=True)
    except Exception:
        pass
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

for path, entry in sorted(entries.items(), key=lambda item: item[1]["order"]):
    if not os.path.isdir(path):
        continue
    pid = ""
    lock = os.path.join(path, "lock")
    if os.path.islink(lock):
        target = os.readlink(lock)
        pid = target.rsplit("+", 1)[-1] if "+" in target else ""
    running = bool(pid) and os.path.isdir("/proc/" + pid)
    print("\t".join([entry["name"], path, "1" if entry.get("default") else "0", "1" if running else "0", pid if running else ""]))
PY
  done < <(profile_roots)
}

choose_profile() {
  local name path is_default running pid index=0 mark
  local want lower_name lower_base
  want="${PROFILE_ARG,,}"
  PROFILE_INDEX="$(mktemp "${TMPDIR:-/tmp}/browse-profiles-XXXXXX.tsv")"
  while IFS=$'\t' read -r name path is_default running pid; do
    [ -n "$path" ] || continue
    index=$((index + 1))
    if [ "$running" = "1" ]; then mark="open in Firefox, pid $pid"; else mark="closed"; fi
    if [ -n "$PROFILE_ARG" ]; then
      # Firefox profile names are user-visible labels, so match them case-insensitively; paths stay exact.
      lower_name="${name,,}"
      lower_base="$(basename "$path")"
      lower_base="${lower_base,,}"
      if [ "$PROFILE_ARG" = "$path" ] || [ "$want" = "$lower_name" ] || [ "$want" = "$lower_base" ]; then
        SELECTED_NAME="$name"
        SELECTED_PATH="$path"
        SELECTED_RUNNING="$running"
        return 0
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$index" "$name" "$mark" "$path" >>"$PROFILE_INDEX"
  done < <(list_profiles)

  if [ -n "$PROFILE_ARG" ]; then
    local available=""
    [ -s "$PROFILE_INDEX" ] && available="; available: $(cut -f2 "$PROFILE_INDEX" | paste -sd, -)"
    die "no Firefox profile named ${PROFILE_ARG}${available}"
  fi
  [ -s "$PROFILE_INDEX" ] || die "no Firefox profiles found (start Firefox once, then rerun)"

  say "" >&2
  say "Firefox profiles:" >&2
  while IFS=$'\t' read -r index name mark path; do
    printf '  %s) %-12s %-42s %s\n' "$index" "$name" "$path" "$mark" >&2
  done <"$PROFILE_INDEX"

  local choice selected
  printf 'Which profile should get the browse extension? [1] ' >&2
  read -r choice || true
  [ -n "$choice" ] || choice=1
  selected="$(awk -F '\t' -v c="$choice" '$1 == c { print; exit }' "$PROFILE_INDEX")"
  [ -n "$selected" ] || selected="$(awk -F '\t' -v c="$choice" '$2 == c { print; exit }' "$PROFILE_INDEX")"
  [ -n "$selected" ] || die "no profile $choice"
  SELECTED_NAME="$(cut -f2 - <<<"$selected")"
  SELECTED_PATH="$(cut -f4 - <<<"$selected")"
  SELECTED_RUNNING="$(cut -f3 - <<<"$selected" | grep -c 'open in Firefox' || true)"
}

free_port() {
  local port="${PORT_ARG:-9222}"
  local limit=$((port + 40))
  while [ "$port" -le "$limit" ]; do
    if ! ss -ltn 2>/dev/null | grep -q ":$port "; then printf '%s' "$port"; return; fi
    port=$((port + 1))
  done
  die "no free port near ${PORT_ARG:-9222}; pass --port"
}

relay_status_json() {
  node "$ROOT/cli/dist/cli.mjs" status --json 2>/dev/null || true
}

relay_is_running() {
  # Status exits nonzero for a running relay whose build predates this checkout; the JSON still says it runs.
  relay_status_json | node -e '
    let body = ""
    process.stdin.on("data", (chunk) => (body += chunk)).on("end", () => {
      try { process.exit(JSON.parse(body).relay?.running === true ? 0 : 1) } catch { process.exit(1) }
    })
  '
}

relay_port() {
  local port
  port="$(relay_status_json | node -e '
    let body = ""
    process.stdin.on("data", (chunk) => (body += chunk)).on("end", () => {
      try { process.stdout.write(String(new URL(JSON.parse(body).endpoint).port || 19988)) } catch { process.stdout.write("19988") }
    })
  ')"
  printf '%s' "${port:-19988}"
}

# A fresh one-time code for the build that is about to be loaded: the one bundled earlier may be
# spent, expired, or minted before this profile existed, which makes the add-on wait for pairing.
mint_pairing_for_extension() {
  local dist="$1" port script output
  port="$(relay_port)"
  script="$(mktemp "${TMPDIR:-/tmp}/browse-pairing-XXXXXX.mts")"
  cat >"$script" <<'TS'
import { pathToFileURL } from "node:url"
const module = await import(pathToFileURL(process.env.BROWSE_PAIRING_MODULE).href)
const code = module.mintPairingCode(undefined, { ttlMs: module.bundledPairingCodeTtlMs })
for (const directory of [process.env.BROWSE_DIST, process.env.BROWSE_PUBLIC]) {
  if (directory) module.writeExtensionPairing(directory, code, Number(process.env.BROWSE_PAIRING_PORT))
}
process.stdout.write(code)
TS
  output="$(BROWSE_PAIRING_MODULE="$ROOT/cli/src/relay/browser-pairing.ts" BROWSE_DIST="$dist" \
    BROWSE_PUBLIC="$ROOT/public" BROWSE_PAIRING_PORT="$port" \
    node --experimental-strip-types "$script" 2>/dev/null)" || output=""
  if [ -z "$output" ]; then
    output="$(BROWSE_PAIRING_MODULE="$ROOT/cli/src/relay/browser-pairing.ts" BROWSE_DIST="$dist" \
      BROWSE_PUBLIC="$ROOT/public" BROWSE_PAIRING_PORT="$port" \
      run_bun "$script" 2>/dev/null)" || output=""
  fi
  rm -f "$script"
  if [ -n "$output" ]; then
    say "pairing:  one-time code written for relay port ${port}"
  else
    printf 'warning: could not write a pairing code; load the add-on and run `browse pair`\n' >&2
  fi
}

start_relay_now() {
  relay_is_running && return 0
  local logs="${XDG_STATE_HOME:-$HOME/.local/state}/browse/logs"
  local node_bin attempt=0
  node_bin="$(command -v node)"
  mkdir -p "$logs"
  if command -v setsid >/dev/null 2>&1; then
    OPENCODE_BROWSER_MANAGED_RELAY=1 setsid nohup "$node_bin" "$ROOT/cli/dist/cli.mjs" serve >>"$logs/startup.log" 2>&1 &
  else
    OPENCODE_BROWSER_MANAGED_RELAY=1 nohup "$node_bin" "$ROOT/cli/dist/cli.mjs" serve >>"$logs/startup.log" 2>&1 &
  fi
  disown || true
  while [ "$attempt" -lt 50 ]; do
    relay_is_running && return 0
    sleep 0.2
    attempt=$((attempt + 1))
  done
  return 1
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# `browse mcp` is a stdio proxy that an agent starts, so the thing that runs as a startup app is the
# relay it talks to: the local server the browser add-on connects to (and `browse mcp` starts on demand).
install_startup() {
  local node_bin entry file
  node_bin="$(command -v node)"
  entry="$ROOT/cli/dist/cli.mjs"
  if [ ! -f "$entry" ]; then
    printf 'warning: no %s to start at login; run the full setup first\n' "$entry" >&2
    return 0
  fi
  mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/browse/logs"

  if [ "$(uname -s)" = "Darwin" ]; then
    file="$HOME/Library/LaunchAgents/ai.opencode.browse.relay.plist"
    mkdir -p "$(dirname "$file")"
    cat >"$file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.opencode.browse.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$node_bin")</string>
    <string>$(xml_escape "$entry")</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPENCODE_BROWSER_MANAGED_RELAY</key>
    <string>1</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml_escape "${XDG_STATE_HOME:-$HOME/.local/state}/browse/logs/startup.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "${XDG_STATE_HOME:-$HOME/.local/state}/browse/logs/startup.log")</string>
</dict>
</plist>
EOF
  else
    file="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/browse-relay.desktop"
    mkdir -p "$(dirname "$file")"
    cat >"$file" <<EOF
[Desktop Entry]
Type=Application
Name=browse relay
Comment=Local browse server the browser add-on and MCP clients connect to
Exec=env OPENCODE_BROWSER_MANAGED_RELAY=1 "$node_bin" "$entry" serve
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    chmod 644 "$file"
  fi

  STARTUP_FILE="$file"
  say "startup:  ${file}"
  if start_relay_now; then
    say "relay:    running"
  else
    printf 'warning: the relay did not start; see %s/browse/logs/startup.log\n' "${XDG_STATE_HOME:-$HOME/.local/state}" >&2
  fi
}

remove_startup() {
  local file
  if [ "$(uname -s)" = "Darwin" ]; then
    file="$HOME/Library/LaunchAgents/ai.opencode.browse.relay.plist"
  else
    file="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/browse-relay.desktop"
  fi
  if [ -f "$file" ]; then
    rm -f "$file"
    say "startup:  removed ${file}"
  fi
}

install_extension() {
  local name="$1" path="$2" running="$3"
  local firefox dist port log helper result status=0 browser_pid
  firefox="$(find_firefox)"
  dist="$ROOT/dist-firefox"

  # --extension-only skips the project install, so a fresh checkout has no build tooling yet.
  if [ ! -d "$ROOT/node_modules" ]; then
    step "Installing build dependencies"
    (cd "$ROOT" && run_bun install)
  fi

  step "Building the Firefox add-on"
  run_bun run build:firefox
  [ -f "$dist/manifest.json" ] || die "no $dist/manifest.json after the build"
  node -e 'const m=require(process.argv[1]); if(!m.browser_specific_settings||m.background?.service_worker){console.error("dist-firefox is not the Firefox build");process.exit(1)}' "$dist/manifest.json" \
    || die "dist-firefox is not the Firefox build"

  [ "$running" = "1" ] && die "the ${name} profile is open in Firefox. Quit that Firefox window and run this again (the add-on is temporary: it lasts as long as that window)."
  mint_pairing_for_extension "$dist"

  port="$(free_port)"
  log="${TMPDIR:-/tmp}/browse-setup-firefox-${port}.log"
  USER_JS="$path/user.js"
  USER_JS_BAK=""
  USER_JS_CREATED=0
  if [ -f "$USER_JS" ]; then
    USER_JS_BAK="$(mktemp "${TMPDIR:-/tmp}/browse-user-js-XXXXXX")"
    cp "$USER_JS" "$USER_JS_BAK"
  else
    USER_JS_CREATED=1
  fi
  printf '%s\n' \
    'user_pref("devtools.debugger.remote-enabled", true);' \
    'user_pref("devtools.debugger.prompt-connection", false);' \
    'user_pref("devtools.chrome.enabled", true);' >>"$USER_JS"

  step "Starting Firefox on the ${name} profile"
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$firefox" -no-remote --profile "$path" -start-debugger-server "$port" >"$log" 2>&1 &
  else
    nohup "$firefox" -no-remote --profile "$path" -start-debugger-server "$port" >"$log" 2>&1 &
  fi
  browser_pid=$!
  disown || true

  helper="$(mktemp "${TMPDIR:-/tmp}/browse-devtools-XXXXXX.mjs")"
  cat >"$helper" <<'JS'
import net from 'node:net'

const port = Number(process.argv[2])
const dist = process.argv[3]
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const events = /^(frameUpdate|tabListChanged|target-|resource|resources-|consoleAPI|pageError|documentEvent|networkEvent|propertyChange|styleApplied|newMutations)/

class Client {
  constructor(socket) {
    this.socket = socket
    this.buffer = Buffer.alloc(0)
    this.waiting = []
    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk])
      for (;;) {
        const separator = this.buffer.indexOf(0x3a)
        if (separator < 1) return
        const length = Number.parseInt(this.buffer.slice(0, separator).toString(), 10)
        if (Number.isNaN(length)) return
        if (this.buffer.length - (separator + 1) < length) return
        const message = JSON.parse(this.buffer.slice(separator + 1, separator + 1 + length).toString())
        this.buffer = this.buffer.slice(separator + 1 + length)
        if (message.resultID && !message.type) continue
        if (typeof message.type === 'string' && events.test(message.type)) continue
        const waiting = this.waiting.shift()
        if (waiting) waiting(message)
      }
    })
  }
  request(payload, timeoutMs = 30_000) {
    const data = Buffer.from(JSON.stringify(payload))
    this.socket.write(Buffer.concat([Buffer.from(`${data.length}:`), data]))
    return new Promise((resolve) => {
      this.waiting.push(resolve)
      setTimeout(() => resolve({ timeout: payload.type }), timeoutMs)
    })
  }
}

let client
const deadline = Date.now() + 90_000
while (Date.now() < deadline) {
  try {
    const socket = await new Promise((resolve, reject) => {
      const candidate = net.createConnection({ host: '127.0.0.1', port }, () => resolve(candidate))
      candidate.once('error', reject)
    })
    client = new Client(socket)
    await sleep(400)
    break
  } catch {
    await sleep(400)
  }
}
if (!client) {
  console.log(JSON.stringify({ ok: false, error: `no debugger on 127.0.0.1:${port}` }))
  process.exit(2)
}

async function evaluate(expression) {
  const reply = await client.request({ to: client.consoleActor, type: 'evaluateJSAsync', text: expression })
  if (!reply || reply.timeout) throw new Error('evaluation timed out')
  if (reply.error) throw new Error(`${reply.error}: ${reply.message}`)
  if (reply.hasException) throw new Error(`exception: ${reply.exceptionMessage || JSON.stringify(reply.exception)}`)
  return reply.result
}

async function text(expression) {
  const result = await evaluate(expression)
  return typeof result === 'string' ? result : JSON.stringify(result)
}

try {
  const parent = await client.request({ to: 'root', type: 'getProcess', id: 0 })
  const target = await client.request({ to: parent.processDescriptor.actor, type: 'getTarget' })
  client.consoleActor = target.process.consoleActor

  await evaluate(
    `(() => { try {
      const { AddonManager } = ChromeUtils.importESModule('resource://gre/modules/AddonManager.sys.mjs')
      const { FileUtils } = ChromeUtils.importESModule('resource://gre/modules/FileUtils.sys.mjs')
      globalThis.__browseInstall = 'pending'
      AddonManager.installTemporaryAddon(new FileUtils.File(${JSON.stringify(dist)})).then(
        (addon) => { globalThis.__browseInstall = { ok: true, id: addon.id, version: addon.version } },
        (error) => { globalThis.__browseInstall = { ok: false, error: String(error) } },
      )
      return 'started'
    } catch (error) { globalThis.__browseInstall = { ok: false, error: 'setup: ' + error.message }; return 'setup-failed' } })()`,
  )

  let installed = null
  for (let attempt = 0; attempt < 30; attempt++) {
    await sleep(500)
    const current = JSON.parse(await text('JSON.stringify(globalThis.__browseInstall ?? "undefined")'))
    if (current && current !== 'pending' && current !== 'undefined') {
      installed = current
      break
    }
  }
  if (!installed) installed = { ok: false, error: 'install timed out' }
  if (!installed.ok && /already/i.test(String(installed.error))) installed = { ok: true, already: true, error: String(installed.error) }
  if (!installed.ok) {
    console.log(JSON.stringify({ ok: false, error: installed.error }))
    process.exit(1)
  }

  await sleep(1200)
  const tabs = JSON.parse(
    await text(`JSON.stringify(gBrowser.browsers.map((browser) => browser.currentURI && browser.currentURI.spec).filter(Boolean))`),
  )
  const page = tabs.find((url) => url.includes('onboarding.html')) || tabs.find((url) => url.startsWith('moz-extension://'))

  const reset = JSON.parse(
    await text(`(() => {
      const names = ['devtools.debugger.remote-enabled', 'devtools.debugger.prompt-connection', 'devtools.chrome.enabled']
      const cleared = []
      for (const name of names) {
        try { if (Services.prefs.prefHasUserValue(name)) { Services.prefs.clearUserPref(name); cleared.push(name) } } catch (error) {}
      }
      let saved = 'ok'
      try { Services.prefs.savePrefFile(null) } catch (error) { saved = String(error) }
      const remaining = names.filter((name) => { try { return Services.prefs.prefHasUserValue(name) } catch (error) { return false } })
      return JSON.stringify({ cleared, saved, remaining })
    })()`),
  )

  console.log(JSON.stringify({ ok: true, extension: installed.id, version: installed.version, page, tabs, reset }))
  client.socket.end()
  process.exit(0)
} catch (error) {
  console.log(JSON.stringify({ ok: false, error: String((error && error.message) || error) }))
  client.socket.end()
  process.exit(1)
}
JS

  step "Loading the add-on into ${name}"
  result="$(node "$helper" "$port" "$dist" 2>&1)" || status=$?
  rm -f "$helper"
  restore_user_js

  if [ "$status" -ne 0 ]; then
    say "$result"
    kill "$browser_pid" 2>/dev/null || true
    die "could not load the add-on (Firefox log: $log)"
  fi

  node -e '
    const info = JSON.parse(process.argv[1])
    const lines = [
      `add-on:  ${info.extension} ${info.version}${info.already ? " (already loaded)" : ""}`,
      `page:    ${info.page || "no extension page"} `,
      `prefs:   cleared ${info.reset.cleared.length}, remaining ${info.reset.remaining.length}, saved ${info.reset.saved}`,
    ]
    console.log(lines.join("\n"))
  ' "$result"

  sleep 1
  if grep -q 'user_pref("devtools.debugger.remote-enabled"' "$path/prefs.js" 2>/dev/null; then
    printf 'warning: the debugger pref is still in %s/prefs.js\n' "$path" >&2
  fi
  if pgrep -f -- "--profile $path" >/dev/null 2>&1 || kill -0 "$browser_pid" 2>/dev/null; then
    say "browse is loaded in the ${name} profile; Firefox opened its setup page."
  else
    printf 'warning: Firefox exited; check %s\n' "$log" >&2
  fi
  LAST_PROFILE_NAME="$name"
}

LAST_PROFILE_NAME=""
need_node

if [ "$SKIP_PROJECT" -eq 0 ]; then
  step "Installing browse for your agents"
  (cd "$ROOT" && run_bun install)
  (cd "$ROOT/cli" && run_bun install && run_bun run build)
  cli_args=(install --no-open --no-wait)
  if [ -n "$AGENTS" ]; then
    cli_args+=(-a "$AGENTS")
  else
    cli_args+=(-y)
  fi
  if [ "$MODIFY_PATH" -eq 0 ]; then cli_args+=(--no-modify-path); fi
  install_status=0
  node "$ROOT/cli/dist/cli.mjs" "${cli_args[@]}" || install_status=$?
  if [ "$install_status" -ne 0 ]; then
    say "note: 'browse install' exited ${install_status} because no browser had the extension yet; the Firefox add-on is loaded below."
  fi
fi

if [ "$STARTUP" -eq 1 ]; then
  step "Making the browse relay start at login"
  install_startup
else
  remove_startup
fi

if [ "$SKIP_EXTENSION" -eq 0 ]; then
  choose_profile
  install_extension "$SELECTED_NAME" "$SELECTED_PATH" "$SELECTED_RUNNING"

  step "Done"
  say "profile:  ${SELECTED_NAME} (${SELECTED_PATH})"
  say "add-on:   browse@opencode.ai, loaded for this Firefox window"
  if [ -n "$STARTUP_FILE" ]; then say "startup:  browse relay at login (${STARTUP_FILE})"; fi
  say ""
  say "It disappears when you quit Firefox: Release Firefox only allows an unsigned add-on for one"
  say "session. To load it again:"
  say "  ./setup-full.sh --extension-only --profile \"${SELECTED_NAME}\""
  say ""
  say "The page Firefox opened should connect by itself with the one-time code just written."
  say "If it doesn't: run 'browse pair' and enter the code on that page."
  say "A permanent install needs a signed build: 'web-ext sign --channel unlisted' with AMO API keys."
fi
