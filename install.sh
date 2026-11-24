#!/usr/bin/env bash
# bolt-deploy.sh — detect OS/arch, ensure Docker, pull pinned bolt image, launch bolt,
# mint a pairing code, open a local control panel (falling back to /health).
#
# Usage: sudo ./bolt-deploy.sh [--port N] [--name NAME] [--token HEX]
#
# Image: ghcr.io/cyberstrikeus/bolt:93bcf2c (digest-pinned per platform)

set -Eeuo pipefail

IMAGE_REPO="ghcr.io/cyberstrikeus/bolt"
IMAGE_TAG="93bcf2c"
DIGEST_AMD64="sha256:b5ddb610ea214656fd97223ed790d3bb50a3d44ae188dc937e64c87a83cc4459"
DIGEST_ARM64="sha256:acd4e9a60154b97ffb1e82e662185eb6e8785d9910c9acf845d4765917f1d88f"
DIGEST_INDEX="sha256:5796405aa94dfd737349ec2d81ebb31bb342a9e128f35e9ccb52bfdc651648ad"

BOLT_PORT="${BOLT_PORT:-3001}"
BOLT_NAME="${BOLT_NAME:-bolt}"
BOLT_NO_BROWSER="${BOLT_NO_BROWSER:-0}"
BOLT_NO_START="${BOLT_NO_START:-0}"
BOLT_NO_PAIR="${BOLT_NO_PAIR:-0}"
HEALTH_FIRST="${HEALTH_FIRST:-0}"
CLI_TOKEN=""
PAIR_CODE=""

log()  { printf '\033[1;34m[bolt]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bolt]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bolt]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "aborted at line ${LINENO}"' ERR

usage() {
  cat <<'EOF'
bolt-deploy.sh — install Docker if needed, then run bolt.

  -p, --port N       host port to publish (default 3001)
  -n, --name NAME    container and volume name (default bolt)
  -t, --token HEX    admin token (default: reuse saved, else generate)
      --browser-health try /health before the panel (default: panel, then /health)
      --no-browser   launch without opening anything
      --no-pair      skip minting a pairing code
      --no-start     install Docker and pull the image only
  -h, --help         this text

Env equivalents: BOLT_PORT, BOLT_NAME, BOLT_NO_BROWSER, BOLT_NO_START,
BOLT_NO_PAIR, HEALTH_FIRST. Flags win over env.

bolt has no web UI. The panel is a generated local HTML file with live status,
a mint button and copy buttons; the pairing code is what you paste into the
CyberStrike TUI (/bolt, press a). If the panel cannot be opened, /health is
opened instead.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)        BOLT_PORT="${2:?--port needs a value}";  shift 2 ;;
    -n|--name)        BOLT_NAME="${2:?--name needs a value}";  shift 2 ;;
    -t|--token)       CLI_TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --browser-health) HEALTH_FIRST=1; shift ;;
    --no-browser)     BOLT_NO_BROWSER=1; shift ;;
    --no-pair)        BOLT_NO_PAIR=1; shift ;;
    --no-start)       BOLT_NO_START=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ "$BOLT_PORT" =~ ^[0-9]+$ ]] && (( BOLT_PORT >= 1 && BOLT_PORT <= 65535 )) \
  || die "invalid port: $BOLT_PORT"
[[ "$BOLT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "invalid container name: $BOLT_NAME"

VOLUME="${BOLT_NAME}-data"
BASE_URL="http://localhost:${BOLT_PORT}/"
HEALTH_URL="${BASE_URL}health"

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "not root and sudo not available"
  SUDO="sudo"
fi

dkr() { if docker info >/dev/null 2>&1; then docker "$@"; else $SUDO docker "$@"; fi; }

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# ---------------------------------------------------------------- 1. OS detect
OS_FAMILY="unknown"; DISTRO_ID="unknown"; DISTRO_VER=""
case "$(uname -s)" in
  Darwin) OS_FAMILY="macos" ;;
  Linux)
    OS_FAMILY="linux"
    if [[ -r /etc/os-release ]]; then
      . /etc/os-release
      DISTRO_ID="${ID:-unknown}"
      DISTRO_VER="${VERSION_ID:-}"
    fi
    grep -qi microsoft /proc/version 2>/dev/null && OS_FAMILY="wsl"
    ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac
log "host: ${OS_FAMILY} / ${DISTRO_ID} ${DISTRO_VER}"

# ------------------------------------------------------- 2. arch + image pick
MACHINE="$(uname -m)"
case "$MACHINE" in
  x86_64|amd64)   PLATFORM="linux/amd64"; IMAGE="${IMAGE_REPO}:${IMAGE_TAG}@${DIGEST_AMD64}" ;;
  aarch64|arm64)  PLATFORM="linux/arm64"; IMAGE="${IMAGE_REPO}:${IMAGE_TAG}@${DIGEST_ARM64}" ;;
  *)
    PLATFORM="unknown"
    IMAGE="${IMAGE_REPO}:${IMAGE_TAG}@${DIGEST_INDEX}"
    warn "unrecognized arch '${MACHINE}' — using index digest, will fall back to tag if needed"
    ;;
esac
log "arch: ${MACHINE} -> ${PLATFORM}"

# ------------------------------------------------------------- 3. ensure curl
ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  log "installing curl"
  for pm in apt-get dnf yum zypper pacman apk; do
    command -v "$pm" >/dev/null 2>&1 || continue
    case "$pm" in
      apt-get) $SUDO apt-get update -qq && $SUDO apt-get install -y curl ca-certificates ;;
      dnf|yum) $SUDO "$pm" install -y curl ca-certificates ;;
      zypper)  $SUDO zypper -n install curl ca-certificates ;;
      pacman)  $SUDO pacman -Sy --noconfirm curl ca-certificates ;;
      apk)     $SUDO apk add --no-cache curl ca-certificates ;;
    esac
    break
  done
  command -v curl >/dev/null 2>&1 || die "curl unavailable and could not be installed"
}

# ------------------------------------------------------------ 4. install docker
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker already present ($(docker --version 2>/dev/null || echo 'unknown version'))"
    return 0
  fi

  case "$OS_FAMILY" in
    macos)
      command -v brew >/dev/null 2>&1 || die "install Homebrew (https://brew.sh) or Docker Desktop first"
      log "installing Docker Desktop via Homebrew"
      brew install --cask docker
      ;;
    *)
      log "no docker found — installing"
      ensure_curl
      if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        $SUDO sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
      else
        warn "get.docker.com unreachable — falling back to distro packages"
        case "$DISTRO_ID" in
          arch|manjaro|endeavouros) $SUDO pacman -Sy --noconfirm docker docker-compose ;;
          alpine)                   $SUDO apk add --no-cache docker docker-cli-compose ;;
          opensuse*|sles)           $SUDO zypper -n install docker ;;
          *)  $SUDO apt-get update -qq && $SUDO apt-get install -y docker.io \
                || $SUDO dnf install -y docker \
                || $SUDO yum install -y docker \
                || die "could not install docker" ;;
        esac
      fi
      ;;
  esac

  command -v docker >/dev/null 2>&1 || die "docker installation finished but binary is missing"
  log "docker installed"
}

# --------------------------------------------------------------- 5. start daemon
start_docker() {
  dkr info >/dev/null 2>&1 && return 0

  case "$OS_FAMILY" in
    macos)
      log "starting Docker Desktop"
      open -a Docker 2>/dev/null || open -a "Docker Desktop" 2>/dev/null || true
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl enable --now docker 2>/dev/null || $SUDO systemctl start docker 2>/dev/null || true
      elif command -v rc-service >/dev/null 2>&1; then
        $SUDO rc-update add docker default 2>/dev/null || true
        $SUDO rc-service docker start 2>/dev/null || true
      elif command -v service >/dev/null 2>&1; then
        $SUDO service docker start 2>/dev/null || true
      else
        $SUDO sh -c 'dockerd >/var/log/dockerd.log 2>&1 &'
      fi
      ;;
  esac

  log "waiting for the docker daemon"
  for _ in $(seq 1 60); do
    dkr info >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "docker daemon did not come up — check the service (systemctl status docker / Docker Desktop)"
}

# ---------------------------------------------------------- 6. token persistence
if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
  REAL_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  REAL_HOME="${REAL_HOME:-$HOME}"
else
  REAL_HOME="$HOME"
fi
STATE_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/bolt"
TOKEN_FILE="${STATE_DIR}/admin-token"
PANEL_FILE="${STATE_DIR}/bolt-panel.html"

resolve_token() {
  if [[ -n "$CLI_TOKEN" ]]; then printf '%s' "$CLI_TOKEN"; return; fi
  if dkr ps -a --format '{{.Names}}' | grep -qx "$BOLT_NAME"; then
    local t
    t="$(dkr inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BOLT_NAME" 2>/dev/null \
         | sed -n 's/^MCP_ADMIN_TOKEN=//p' | head -n1)"
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
  fi
  if [[ -r "$TOKEN_FILE" ]]; then
    local t; t="$(head -n1 "$TOKEN_FILE")"
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
  fi
  openssl rand -hex 32 2>/dev/null \
    || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# --------------------------------------------------------------- 7. port free?
port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :${p}" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

# ------------------------------------------------------------- 8. mint pair code
# POST /pair with the admin bearer token -> {code,expiresIn,serverFingerprint}, 300s TTL.
pair_now() {
  local resp code
  resp="$(curl -sS --max-time 10 -X POST \
            -H "Authorization: Bearer ${TOKEN}" \
            "${BASE_URL}pair" 2>/dev/null || true)"
  [[ -n "$resp" ]] || { warn "POST /pair got no response"; return 1; }
  code="$(printf '%s' "$resp" \
    | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [[ -z "$code" ]]; then
    warn "unexpected /pair response: ${resp}"
    return 1
  fi
  PAIR_CODE="$code"
  log "pairing code minted (valid 5 minutes)"
}

# ---------------------------------------------------------------- 9. write panel
write_panel() {
  mkdir -p "$STATE_DIR" 2>/dev/null || $SUDO mkdir -p "$STATE_DIR"

  local esc_base esc_name esc_token esc_code
  esc_base="$(html_escape "$BASE_URL")"
  esc_name="$(html_escape "$BOLT_NAME")"
  esc_token="$(html_escape "$TOKEN")"
  esc_code="$(html_escape "$PAIR_CODE")"

  cat > "${PANEL_FILE}.tmp" <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>bolt — control panel</title>
<style>
  :root{--bg:#0c0d10;--fg:#e6e7ea;--dim:#8b8f9a;--line:#22242b;--acc:#7cc4ff;--ok:#4ec9a0;--bad:#ff6b6b}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;padding:32px}
  .wrap{max-width:760px;margin:0 auto}
  h1{font-size:15px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim);margin:0 0 20px}
  h1 b{color:var(--fg);letter-spacing:.02em}
  .row{border-top:1px solid var(--line);padding:16px 0;display:flex;gap:14px;
       align-items:baseline;justify-content:space-between;flex-wrap:wrap}
  .row:last-of-type{border-bottom:1px solid var(--line)}
  .k{color:var(--dim);font-size:11px;letter-spacing:.12em;text-transform:uppercase;min-width:120px}
  .v{flex:1;word-break:break-all;text-align:right}
  code{font:inherit;color:var(--acc)}
  .pill{display:inline-flex;align-items:center;gap:7px;font-size:11px;letter-spacing:.1em;
        text-transform:uppercase;color:var(--dim)}
  .dot{width:8px;height:8px;border-radius:50%;background:var(--dim)}
  .pill.up{color:var(--ok)} .pill.up .dot{background:var(--ok)}
  .pill.down{color:var(--bad)} .pill.down .dot{background:var(--bad)}
  .code{font-size:30px;letter-spacing:.16em;color:var(--fg)}
  .code.stale{color:var(--dim);text-decoration:line-through}
  button{font:inherit;font-size:11px;letter-spacing:.1em;text-transform:uppercase;
         background:transparent;color:var(--fg);border:1px solid var(--line);
         padding:6px 12px;border-radius:3px;cursor:pointer}
  button:hover{border-color:var(--acc);color:var(--acc)}
  button:disabled{opacity:.4;cursor:default;border-color:var(--line);color:var(--dim)}
  #msg{font-size:11px;color:var(--dim);min-height:16px;margin-top:6px}
  #msg.ok{color:var(--ok)} #msg.bad{color:var(--bad)}
  .steps{margin:26px 0 0;padding:16px;border:1px solid var(--line);border-radius:3px;
         color:var(--dim);font-size:12px;line-height:1.9}
  .steps b{color:var(--fg);font-weight:400}
  a{color:var(--acc);text-decoration:none} a:hover{text-decoration:underline}
  .foot{margin-top:22px;font-size:11px;color:var(--dim);line-height:1.9}
</style></head><body><div class="wrap">

<h1>bolt <b>control panel</b></h1>

<div class="row">
  <span class="k">status</span>
  <span class="pill" id="pill"><span class="dot"></span><span id="pill-txt">checking</span></span>
</div>

<div class="row">
  <span class="k">endpoint</span>
  <span class="v"><code id="base">__BASE__</code></span>
</div>

<div class="row">
  <span class="k">container</span>
  <span class="v"><code>__NAME__</code></span>
</div>

<div class="row" style="align-items:center">
  <span class="k">pairing code</span>
  <span class="v">
    <span class="code" id="code">__CODE__</span>
    <div id="ttl" style="font-size:11px;color:var(--dim);margin-top:4px"></div>
  </span>
  <span style="display:flex;gap:8px">
    <button id="mint">mint</button>
    <button id="copy-code">copy</button>
  </span>
</div>
<div id="msg"></div>

<div class="row">
  <span class="k">admin token</span>
  <span class="v"><code>__TOKEN__</code></span>
  <button id="copy-token">copy</button>
</div>

<div class="steps">
  <b>1.</b> In the CyberStrike TUI, run <b>/bolt</b> and press <b>a</b><br>
  <b>2.</b> Enter <b id="step-url">__BASE__</b><br>
  <b>3.</b> Paste the pairing code above (or the admin token)<br>
  <br>
  Codes are single use and expire after 5 minutes. Mint a fresh one per client.
</div>

<div class="foot">
  <a href="__BASE__health" target="_blank">/health</a> ·
  <a href="__BASE__tools" target="_blank">/tools</a> ·
  <a href="__BASE__pair/clients" target="_blank">/pair/clients</a>
  <br>JSON-only server, no UI. This panel is a local file; it talks to the API directly.
  <br><span id="warnbox"></span>
</div>

<script>
const BASE = "__BASE__";
const TOKEN = "__TOKEN__";
let ttl = 0, tick = null;

const $ = (id) => document.getElementById(id);
const codeEl = $("code"), ttlEl = $("ttl"), msgEl = $("msg"), mintBtn = $("mint");

function say(text, kind) { msgEl.textContent = text || ""; msgEl.className = kind || ""; }

function countdown(secs) {
  clearInterval(tick);
  ttl = secs;
  const paint = () => {
    if (ttl <= 0) { clearInterval(tick); codeEl.classList.add("stale"); ttlEl.textContent = "expired"; return; }
    const m = String(Math.floor(ttl / 60)), s = String(ttl % 60).padStart(2, "0");
    ttlEl.textContent = "expires in " + m + ":" + s;
    ttl--;
  };
  codeEl.classList.remove("stale");
  paint();
  tick = setInterval(paint, 1000);
}

function setCode(code, secs) {
  codeEl.textContent = code;
  countdown(secs || 300);
}

async function copy(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    say(label + " copied", "ok");
  } catch (e) {
    const t = document.createElement("textarea");
    t.value = text; document.body.appendChild(t); t.select();
    try { document.execCommand("copy"); say(label + " copied", "ok"); }
    catch (_) { say("copy blocked — select manually", "bad"); }
    document.body.removeChild(t);
  }
}

async function poll() {
  const pill = $("pill"), txt = $("pill-txt");
  try {
    const r = await fetch(BASE + "health", { cache: "no-store" });
    pill.className = "pill " + (r.ok ? "up" : "down");
    txt.textContent = r.ok ? "up" : "http " + r.status;
  } catch (e) {
    pill.className = "pill down";
    txt.textContent = "unreachable";
  }
}

mintBtn.addEventListener("click", async () => {
  mintBtn.disabled = true;
  say("minting…");
  try {
    const r = await fetch(BASE + "pair", {
      method: "POST",
      headers: { "Authorization": "Bearer " + TOKEN }
    });
    if (r.status === 401) { say("401 — token rejected (this file is stale, re-run the deploy)", "bad"); return; }
    if (r.status === 429) { say("429 — rate limited, wait a few seconds", "bad"); return; }
    if (!r.ok) { say("http " + r.status, "bad"); return; }
    const j = await r.json();
    setCode(j.code, j.expiresIn);
    say("code minted — paste it into the TUI", "ok");
    poll();
  } catch (e) {
    say("unreachable: " + e.message, "bad");
  } finally {
    mintBtn.disabled = false;
  }
});

$("copy-code").addEventListener("click", () => {
  if (!codeEl.textContent || codeEl.classList.contains("stale")) { say("nothing live to copy", "bad"); return; }
  copy(codeEl.textContent, "code");
});
$("copy-token").addEventListener("click", () => copy(TOKEN, "token"));

// If this file was opened over file:// and fetch is blocked, say so plainly.
if (location.protocol === "file:") {
  $("warnbox").textContent = "opened as a local file — if status stays unreachable, serve this directory over HTTP instead.";
}

if (__CODE__) countdown(300);
poll();
setInterval(poll, 5000);
</script></div></body></html>
HTML

  sed -i.bak \
    -e "s|__BASE__|${esc_base}|g" \
    -e "s|__NAME__|${esc_name}|g" \
    -e "s|__TOKEN__|${esc_token}|g" \
    -e "s|__CODE__|${esc_code}|g" \
    "${PANEL_FILE}.tmp"
  rm -f "${PANEL_FILE}.tmp.bak"

  mv -f "${PANEL_FILE}.tmp" "$PANEL_FILE" 2>/dev/null \
    || $SUDO mv -f "${PANEL_FILE}.tmp" "$PANEL_FILE"
  chmod 600 "$PANEL_FILE" 2>/dev/null || $SUDO chmod 600 "$PANEL_FILE" 2>/dev/null || true
  if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    $SUDO chown "$SUDO_USER": "$STATE_DIR" "$PANEL_FILE" 2>/dev/null || true
  fi
}

# -------------------------------------------------------------- 10. open browser
# Single attempt against one target. Returns 0 only if an opener reported success.
try_open() {
  local target="$1"

  if [[ "$OS_FAMILY" == "macos" ]]; then
    if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
      sudo -u "$SUDO_USER" open "$target" 2>/dev/null && return 0
    fi
    open "$target" 2>/dev/null && return 0
    return 1
  fi

  if [[ "$OS_FAMILY" == "wsl" ]]; then
    command -v wslview >/dev/null 2>&1 && wslview "$target" >/dev/null 2>&1 && return 0
    local win="$target"
    command -v wslpath >/dev/null 2>&1 \
      && win="$(wslpath -w "$target" 2>/dev/null || printf '%s' "$target")"
    command -v powershell.exe >/dev/null 2>&1 \
      && powershell.exe -NoProfile -Command "Start-Process '$win'" >/dev/null 2>&1 && return 0
    command -v cmd.exe >/dev/null 2>&1 \
      && cmd.exe /c start "" "$win" >/dev/null 2>&1 && return 0
    command -v explorer.exe >/dev/null 2>&1 && explorer.exe "$target" >/dev/null 2>&1 && return 0
    return 1
  fi

  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && -z "${BROWSER:-}" ]]; then
    return 1
  fi

  local runner=()
  if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]] && command -v sudo >/dev/null 2>&1; then
    runner=(sudo -u "$SUDO_USER")
  fi

  for opener in xdg-open "gio open" sensible-browser x-www-browser; do
    # shellcheck disable=SC2086
    if command -v ${opener%% *} >/dev/null 2>&1; then
      ${runner[@]+"${runner[@]}"} $opener "$target" >/dev/null 2>&1 && return 0
    fi
  done

  if [[ -n "${BROWSER:-}" ]]; then
    ${runner[@]+"${runner[@]}"} $BROWSER "$target" >/dev/null 2>&1 && return 0
  fi

  return 1
}

# Walks the target list in order, stopping at the first one that opens.
open_browser() {
  [[ "$BOLT_NO_BROWSER" == "1" ]] && { log "not opening a browser"; return 0; }

  local target
  for target in "$@"; do
    [[ -n "$target" ]] || continue
    if try_open "$target"; then
      log "opened: ${target}"
      return 0
    fi
    warn "could not open ${target}"
  done

  warn "no target could be opened — everything is still running"
  return 0
}

# --------------------------------------------------------------- 11. run it all
install_docker
start_docker

if [[ ${EUID} -ne 0 ]] && ! id -nG "${USER:-$(id -un)}" 2>/dev/null | grep -qw docker; then
  $SUDO usermod -aG docker "${USER:-$(id -un)}" 2>/dev/null \
    || $SUDO adduser "${USER:-$(id -un)}" docker 2>/dev/null || true
  warn "added ${USER:-$(id -un)} to the 'docker' group — new shells won't need sudo"
fi

log "pulling pinned image for ${PLATFORM}"
if ! dkr pull --platform "$PLATFORM" "$IMAGE"; then
  warn "pinned pull failed — retrying via tag (docker resolves the platform)"
  IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
  dkr pull --platform "$PLATFORM" "$IMAGE" || die "image pull failed"
fi

[[ "$BOLT_NO_START" == "1" ]] && { log "--no-start — stopping after pull"; exit 0; }

TOKEN="$(resolve_token)"
[[ -n "$TOKEN" ]] || die "could not resolve an admin token"

if dkr ps -a --format '{{.Names}}' | grep -qx "$BOLT_NAME"; then
  log "replacing existing container '${BOLT_NAME}'"
  dkr rm -f "$BOLT_NAME" >/dev/null
elif port_busy "$BOLT_PORT"; then
  die "port ${BOLT_PORT} is already in use — pick another with --port"
fi

mkdir -p "$STATE_DIR" 2>/dev/null || $SUDO mkdir -p "$STATE_DIR"
printf '%s\n' "$TOKEN" > "${TOKEN_FILE}.tmp" 2>/dev/null \
  || printf '%s\n' "$TOKEN" | $SUDO tee "${TOKEN_FILE}.tmp" >/dev/null
mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE" 2>/dev/null || $SUDO mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE" 2>/dev/null || $SUDO chmod 600 "$TOKEN_FILE" 2>/dev/null || true

dkr volume create "$VOLUME" >/dev/null

log "starting bolt on port ${BOLT_PORT}"
dkr run -d \
  --name "$BOLT_NAME" \
  --restart unless-stopped \
  --platform "$PLATFORM" \
  -p "${BOLT_PORT}:3001" \
  -e MCP_ADMIN_TOKEN="$TOKEN" \
  --cap-add NET_RAW \
  --cap-add NET_ADMIN \
  -v "${VOLUME}:/data" \
  "$IMAGE" >/dev/null

READY=0
for _ in $(seq 1 45); do
  if curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; then READY=1; break; fi
  dkr ps --format '{{.Names}}' | grep -qx "$BOLT_NAME" || die "container exited — run: docker logs ${BOLT_NAME}"
  sleep 2
done
[[ $READY -eq 1 ]] || warn "health check did not pass in 90s — continuing anyway"

if [[ "$BOLT_NO_PAIR" == "0" && $READY -eq 1 ]]; then
  pair_now || warn "pairing code not minted — use the mint button in the panel"
fi

PANEL_OK=0
if write_panel && [[ -s "$PANEL_FILE" ]]; then
  PANEL_OK=1
  if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    $SUDO chown "$SUDO_USER": "$STATE_DIR" "$PANEL_FILE" "$TOKEN_FILE" 2>/dev/null || true
  fi
else
  warn "panel could not be written — falling back to /health only"
fi

cat <<EOF

  bolt is up on ${BASE_URL}

EOF

if [[ -n "$PAIR_CODE" ]]; then
  cat <<EOF
  PAIRING CODE   ${PAIR_CODE}
                 single use, expires in 5 minutes

EOF
fi

cat <<EOF
  Panel          ${PANEL_FILE}
  Admin token    ${TOKEN}
  Saved          ${TOKEN_FILE}
  Container      ${BOLT_NAME}    Volume ${VOLUME}

  Logs:   docker logs ${BOLT_NAME}
  Stop:   docker stop ${BOLT_NAME}
  Remove: docker rm -f ${BOLT_NAME} && docker volume rm ${VOLUME}

EOF

TARGETS=()
if [[ "$HEALTH_FIRST" == "1" ]]; then
  TARGETS+=("$HEALTH_URL")
  [[ $PANEL_OK -eq 1 ]] && TARGETS+=("$PANEL_FILE")
else
  [[ $PANEL_OK -eq 1 ]] && TARGETS+=("$PANEL_FILE")
  TARGETS+=("$HEALTH_URL")
fi

open_browser "${TARGETS[@]}"
