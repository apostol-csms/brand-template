#!/usr/bin/env bash
#
# server-check.sh — read-only fast health pass of a deployed site, in one run.
#
# Everything is computed on the host; what comes back is one short JSON object
# with only what deviates from the previous run:
#
#   { "report": {...},   # what a reader needs: flags, new / grown fingerprints
#     "state":  {...} }  # the next run's starting point (merge: jq '. + $s')
#
# Usage (from the workdir, or piped — nothing is written on the host either way):
#   ./server-check.sh [options]
#   ssh <host> 'bash -s -- [options]' < server-check.sh
#
# Options:
#   --state-stdin     previous state.json, gzip + base64, read from stdin after the script
#                     text (`{ cat server-check.sh; printf '%s' "$B64"; } | ssh <host> 'bash -s -- --state-stdin'`):
#                     not in the process list, no argument-size limit
#   --state-b64 STR   the same as an argument (visible in `ps`; the Linux limit is 128 KiB)
#   --state-file F    previous state.json as a file on the host
#   --workdir DIR     the brand workdir holding check.sh (default: the script's own
#                     directory when it sits next to check.sh, else the only /opt/*/csms)
#   --since ISO       window start, UTC (default: the previous window end; a first
#                     run takes the oldest container start minus 5 min, capped at
#                     --max-hours)
#   --max-hours N     cap of a first run's window (default 48)
#   --db NAME         database (default: the only non-template one besides postgres)
#   --check-local     pass --local to check.sh (hosts without hairpin NAT)
#   --no-check        do not run check.sh
#   -h, --help
#
# What it reads (never writes; no pg_stat reset, no restart, no setting value
# printed — container environments are never read):
#   containers     docker inspect: image id, start time, restarts, OOM, health, exit code
#   check.sh       the site's own health script, `--json`
#   resources      disk, memory, swap, load, database size
#   logs           `docker logs --since` of every container, nginx error/access logs
#                  (volume *_logs-nginx), counted by the level field of each format and
#                  normalised into fingerprints; e-mails, phones, tokens, client IPs
#                  are masked in every sample
#   database       pg_stat_activity, pg_stat_database, pg_stat_statements,
#                  db.log (E/W), db.api_log, pg_stat_user_tables — SELECT only, through
#                  the container's local socket
#   sessions       counters only, no names: stop commands waiting past their term or ended
#                  without an answer, CostUpdated never answered by a station, closed charging
#                  sessions with no invoice or an invoice neither paid nor closed
#                  (ocpp.command, db.transaction, db.invoice) — flagged under `sessions`
#   metrics        /metrics of backend and ocpp from inside their containers, two scrapes
#
# Exit code: 0 = the pass ran (flags are in the JSON); non-zero = it could not run (stderr says why).

set -uo pipefail

SELF_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export SERVER_CHECK_SELF_DIR="$SELF_DIR"

exec python3 -I -c "$(cat <<'PYEOF'
import sys, os, re, json, gzip, base64, hashlib, subprocess, time, datetime, glob, threading
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import unquote

T0 = time.time()
VERSION = 1

# ── thresholds (the "red" lines of the fast path) ────────────────────────────
GROWTH_X = 3.0              # a known fingerprint is a finding at this rate ratio ...
GROWTH_MIN_COUNT = 5        # ... and at least this many hits in the window
IDLE_TX_S = 60              # idle in transaction older than this
OLDEST_XACT_S = 300         # a client transaction older than this
CONN_RATIO = 0.8            # connections used / max_connections
STUCK_S = 60                # a queue's oldest item older than this
RT_GROWTH_X = 2.0           # nginx / api p95 grew by this factor ...
RT_MIN_REQ = 50             # ... with at least this many requests
RT_MIN_P95 = 0.2            # (seconds) nginx
API_MIN_P95_MS = 50
PGSS_MIN_CALLS = 100        # statement regression: calls in the window ...
PGSS_X = 2.0                # ... and mean grown by this factor
PGSS_MIN_MS = 5
SEQ_TUP_DELTA = 5_000_000_000
DEAD_MIN = 100_000
DISK_WARN = 85
MEM_WARN_MB = 512
MAX_NEW = 15                # new fingerprints listed in full
SAMPLE_LEN = 240
LOG_TIMEOUT_S = 120
PENDING_MAX = 50            # pending_fingerprints kept in the state
FP_KEEP_DAYS = 30           # a known fingerprint not seen for this long is dropped

# ── arguments ───────────────────────────────────────────────────────────────
def usage(rc):
    print(__doc__ or "see the header of server-check.sh", file=sys.stderr)
    sys.exit(rc)

args = sys.argv[1:]
opt = {"state_b64": None, "state_stdin": False, "state_file": None, "workdir": None, "since": None,
       "max_hours": 48.0, "db": None, "check_local": False, "no_check": False}
i = 0
while i < len(args):
    a = args[i]
    if a in ("-h", "--help"):
        print("server-check.sh [--state-stdin | --state-b64 STR | --state-file F] [--workdir DIR] [--since ISO] "
              "[--max-hours N] [--db NAME] [--check-local] [--no-check]")
        sys.exit(0)
    elif a == "--check-local": opt["check_local"] = True
    elif a == "--no-check": opt["no_check"] = True
    elif a == "--state-stdin": opt["state_stdin"] = True
    elif a in ("--state-b64", "--state-file", "--workdir", "--since", "--max-hours", "--db"):
        i += 1
        if i >= len(args):
            print("server-check.sh: %s needs a value" % a, file=sys.stderr); sys.exit(2)
        opt[a[2:].replace("-", "_")] = args[i]
    else:
        print("server-check.sh: unknown argument %s" % a, file=sys.stderr); sys.exit(2)
    i += 1
opt["max_hours"] = float(opt["max_hours"])
if opt["state_stdin"] and (opt["state_b64"] or opt["state_file"]):
    print("server-check.sh: --state-stdin cannot be combined with --state-b64 or --state-file", file=sys.stderr); sys.exit(2)
if opt["state_stdin"] and sys.stdin.isatty():
    print("server-check.sh: --state-stdin needs the state piped on stdin (a terminal is attached)", file=sys.stderr); sys.exit(2)

# ── helpers ─────────────────────────────────────────────────────────────────
def run(cmd, timeout=60, stdin=None):
    try:
        p = subprocess.run(cmd, input=stdin, **({} if stdin is not None else {"stdin": subprocess.DEVNULL}),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, universal_newlines=True, errors="replace")
        return p.returncode, p.stdout
    except Exception as e:
        return 127, str(e)

def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

def iso(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_iso(s):
    s = s.strip()
    m = re.match(r"(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)(\.\d+)?\s*(Z|[+-]\d\d:?\d\d)?", s)
    if not m:
        return None
    base = datetime.datetime.strptime(m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S")
    tz = m.group(4)
    if tz and tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        digits = tz[1:].replace(":", "")
        base -= sign * datetime.timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return base.replace(tzinfo=datetime.timezone.utc)

flags = []
def flag(sev, area, msg, **extra):
    d = {"sev": sev, "area": area, "msg": msg}
    d.update(extra)
    flags.append(d)

# ── masking and fingerprints ────────────────────────────────────────────────
RX_UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
RX_EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
RX_IP4 = re.compile(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}\b")
RX_BEARER = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]+")
RX_HDR = re.compile(r"(?i)\b(authorization|cookie|set-cookie|x-api-key)\s*[:=][^\r\n]*")
RX_KV = re.compile(r"(?i)\b(password|passwd|pwd|token|secret|otp|code|access_token|refresh_token|api_key|apikey|client_secret|signature|sid)(\"?\s*[=:]\s*\"?)[^&\s\"',;]+")
RX_IP6 = re.compile(r"(?<![\w:])(?:[0-9a-fA-F]{0,4}:){4,7}[0-9a-fA-F]{0,4}(?![\w:])")
RX_PHONE = re.compile(r"(?<![\w.])\+?\d[\d\s\-()]{9,16}\d(?![\w.])")
RX_PAN = re.compile(r"\b\d{13,19}\b")
RX_LONG = re.compile(r"\b[A-Za-z0-9_\-]{24,}\b")
RX_DKTS = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z\s?")

def mask(s):
    s = unquote(s)
    s = RX_UUID.sub("<uuid>", s)
    s = RX_BEARER.sub(lambda m: m.group(1) + " <token>", s)
    s = RX_HDR.sub(lambda m: m.group(1) + ": <hidden>", s)
    s = RX_KV.sub(lambda m: m.group(1) + m.group(2) + "<hidden>", s)
    s = RX_IP6.sub("<ipv6>", s)
    s = RX_EMAIL.sub("<email>", s)
    s = RX_IP4.sub(lambda m: m.group(1) + ".x", s)
    s = RX_PAN.sub("<num>", s)
    s = RX_PHONE.sub("<phone>", s)
    s = RX_LONG.sub("<token>", s)
    return s

RX_TS_LONG = re.compile(r"\[?\d{4}[/-]\d\d[/-]\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?(?:\s?(?:UTC|Z|[+-]\d{4}))?\]?")
RX_Q = re.compile(r'"[^"]*"|\'[^\']*\'')
RX_HEX = re.compile(r"\b(?:0x)?[0-9a-fA-F]{8,}\b")
RX_NUM = re.compile(r"\d+")

RX_ROUTE = re.compile(r"(Route not found:)\s*\S+")

def normalise(s):
    s = RX_DKTS.sub("", s)
    s = RX_ROUTE.sub(r"\1 P", s)
    s = RX_TS_LONG.sub("", s)
    s = RX_UUID.sub("U", s)
    s = RX_EMAIL.sub("E", s)
    s = RX_LONG.sub("T", s)
    s = RX_Q.sub("Q", s)
    s = RX_HEX.sub("H", s)
    s = RX_NUM.sub("N", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:300]

def fp_id(source, norm):
    return hashlib.sha1((source + "|" + norm).encode("utf-8", "replace")).hexdigest()[:8]

LEVEL_RX = [
    (re.compile(r"\] (?:error|crit|alert|emerg|fatal):"), "error"),
    (re.compile(r"\] warn:"), "warn"),
    (re.compile(r'"level"\s*:\s*"(?:ERROR|FATAL|PANIC|error|fatal)"'), "error"),
    (re.compile(r'"level"\s*:\s*"(?:WARN|WARNING|warn|warning)"'), "warn"),
    (re.compile(r"\[(?:error|crit|alert|emerg)\]"), "error"),
    (re.compile(r"\[warn\]"), "warn"),
    (re.compile(r"UTC \[\d+\] (?:ERROR|FATAL|PANIC)\b"), "error"),
    (re.compile(r"UTC \[\d+\] WARNING\b"), "warn"),
    (re.compile(r"(?:^|\s)(?:ERROR|FATAL|PANIC|CRITICAL):"), "error"),
    (re.compile(r"(?:^|\s)WARNING:"), "warn"),
    (re.compile(r"^\s*(?:⨯|\[?(?:Type|Range|Reference|Syntax)?Error\b|Unhandled|Traceback|panic:)"), "error"),
    (re.compile(r"checkpoints are occurring too frequently"), "warn"),
]
RX_ACCESS = re.compile(r'^\S+ \S+ \S+ \[[^\]]+\] "(?:[A-Z]+) (\S*)[^"]*" (\d{3}) ')

def level_of(line):
    m = RX_ACCESS.match(line)
    if m:
        return ("error", "http " + m.group(2)) if m.group(2).startswith("5") else (None, None)
    for rx, lv in LEVEL_RX:
        if rx.search(line):
            return lv, None
    return None, None

class Fps:
    """fingerprint → count, first/last time, one masked sample"""
    def __init__(self):
        self.d = {}
        self.lines = {}
        self.counts = {}
    def add(self, source, level, line, ts, n=1, tag=None):
        norm = normalise(line)
        if tag:
            norm = tag + " " + norm
        k = fp_id(source, norm)
        e = self.d.get(k)
        if e is None:
            e = self.d[k] = {"container": source, "level": level, "count": 0,
                             "first": ts, "last": ts, "sample": mask(RX_TS_LONG.sub("", line).strip())[:SAMPLE_LEN]}
        e["count"] += n
        if ts:
            if not e["first"] or ts < e["first"]: e["first"] = ts
            if not e["last"] or ts > e["last"]: e["last"] = ts
    def count_line(self, source, level):
        c = self.counts.setdefault(source, {"error": 0, "warn": 0, "lines": 0})
        if level: c[level] += 1

fps = Fps()

# ── state ───────────────────────────────────────────────────────────────────
state = {}
try:
    if opt["state_stdin"]:
        state = json.loads(gzip.decompress(base64.b64decode(sys.stdin.read().strip())).decode("utf-8"))
    elif opt["state_b64"]:
        state = json.loads(gzip.decompress(base64.b64decode(opt["state_b64"])).decode("utf-8"))
    elif opt["state_file"]:
        with open(opt["state_file"]) as f:
            state = json.load(f)
except Exception as e:
    print("server-check.sh: state not readable: %s" % e, file=sys.stderr)
    state = {}

# ── workdir, site ───────────────────────────────────────────────────────────
def find_workdir():
    if opt["workdir"]:
        return opt["workdir"]
    sd = os.environ.get("SERVER_CHECK_SELF_DIR", "")
    if sd and os.path.exists(os.path.join(sd, "check.sh")):
        return sd
    c = [d for d in glob.glob("/opt/*/csms") if os.path.exists(os.path.join(d, "check.sh"))
         and not d.endswith(".old/csms")]
    if len(c) == 1:
        return c[0]
    return None

workdir = find_workdir()
arc = os.path.basename(os.path.dirname(os.path.abspath(workdir))) if workdir else None
site = state.get("site") or arc

now = utcnow()

# ── containers ──────────────────────────────────────────────────────────────
containers = {}
rc, out = run(["docker", "ps", "-aq"])
ids = out.split() if rc == 0 else []
if ids:
    rc, out = run(["docker", "inspect"] + ids)
    try:
        for c in json.loads(out):
            st = c.get("State", {})
            name = c["Name"].lstrip("/")
            containers[name] = {
                "image": c.get("Image", "")[7:19],
                "tag": (c.get("Config", {}).get("Image") or "").rsplit(":", 1)[-1] if ":" in (c.get("Config", {}).get("Image") or "") else "",
                "running": bool(st.get("Running")),
                "started": st.get("StartedAt", ""),
                "restarts": c.get("RestartCount", 0),
                "oom": bool(st.get("OOMKilled")),
                "exit": st.get("ExitCode", 0),
                "health": (st.get("Health") or {}).get("Status", ""),
                "status": st.get("Status", ""),
            }
    except Exception as e:
        flag("fail", "containers", "docker inspect not readable: %s" % e)
else:
    flag("fail", "containers", "docker ps returned no containers")

running = sorted(n for n, c in containers.items() if c["running"])

# window ----------------------------------------------------------------------
prev_to = parse_iso((state.get("window") or {}).get("to", "")) if state.get("window") else None
fp_state_ok = state.get("fingerprints_v") == 2 and isinstance(state.get("fingerprints"), dict)
baseline = not (prev_to and fp_state_ok)
starts = [parse_iso(containers[n]["started"]) for n in running if containers[n]["started"]]
starts = [s for s in starts if s]
if opt["since"]:
    w_from = parse_iso(opt["since"])
elif baseline:
    w_from = (min(starts) - datetime.timedelta(minutes=5)) if starts else now - datetime.timedelta(hours=24)
    cap = now - datetime.timedelta(hours=opt["max_hours"])
    if w_from < cap:
        w_from = cap
else:
    w_from = prev_to
    later = [s for s in starts if s > prev_to]
    if later:
        w_from = min(w_from, min(later) - datetime.timedelta(minutes=5))
hours = max((now - w_from).total_seconds() / 3600.0, 1 / 60.0)

prev_started = ((state.get("config") or {}).get("started_at")) or {}
prev_images = ((state.get("config") or {}).get("images")) or {}
rollout = {}
for n in running:
    c = containers[n]
    d = {}
    if prev_images.get(n) and prev_images[n] != c["image"]:
        d["image"] = [prev_images[n], c["image"]]
    ps = prev_started.get(n)
    if ps and ps != c["started"] and "image" not in d:
        d["restarted_at"] = c["started"]
    if d:
        rollout[n] = d
    if c["oom"]:
        flag("fail", "containers", "%s was OOM-killed" % n)
    if c["health"] and c["health"] != "healthy":
        flag("warn", "containers", "%s health=%s" % (n, c["health"]))
    if c["restarts"] > 0:
        prev_rc = ((state.get("config") or {}).get("restarts") or {}).get(n)
        if prev_rc is None:
            flag("warn", "containers", "%s RestartCount=%d (no earlier value stored)" % (n, c["restarts"]))
        elif c["restarts"] > prev_rc:
            flag("fail", "containers", "%s RestartCount grew %d -> %d" % (n, prev_rc, c["restarts"]))
for n, c in containers.items():
    if not c["running"] and c["exit"] not in (0, None):
        flag("warn", "containers", "%s is not running, exit code %s" % (n, c["exit"]))

# ── tasks run in parallel ───────────────────────────────────────────────────
since_arg = iso(w_from)
res = {}

def t_check():
    if opt["no_check"] or not workdir or not os.path.exists(os.path.join(workdir, "check.sh")):
        return None
    cmd = ["./check.sh", "--json"] + (["--local"] if opt["check_local"] else [])
    try:
        p = subprocess.run(cmd, cwd=workdir, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, errors="replace", timeout=120)
        return json.loads(p.stdout)
    except Exception as e:
        return {"error": str(e)}

def t_logs(name):
    # a container older than the window start has all its lines in it
    cmd = ["docker", "logs", "--timestamps", "--since", since_arg, name]
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         universal_newlines=True, errors="replace", bufsize=1 << 16)
    timer = threading.Timer(LOG_TIMEOUT_S, p.kill)
    timer.start()
    local = Fps()
    for line in p.stdout:
        line = line.rstrip("\n")
        m = RX_DKTS.match(line)
        ts = m.group(0).strip() if m else None
        body = line[m.end():] if m else line
        local.counts.setdefault(name, {"error": 0, "warn": 0, "lines": 0})["lines"] += 1
        lv, tag = level_of(body)
        if lv:
            local.counts[name][lv] += 1
            local.add(name, lv, body, ts, tag=tag)
    rc = p.wait()
    timer.cancel()
    if rc != 0:
        raise RuntimeError("docker logs %s exited %s%s" % (name, rc, " (killed after %d s)" % LOG_TIMEOUT_S if rc < 0 else ""))
    return name, local

def merge_local(local):
    for k, e in local.d.items():
        if k in fps.d:
            fps.d[k]["count"] += e["count"]
        else:
            fps.d[k] = e
    for n, c in local.counts.items():
        fps.counts[n] = c

def scrape(container, port):
    rc, out = run(["docker", "exec", container, "curl", "-fsS", "--max-time", "8",
                   "http://127.0.0.1:%d/metrics" % port], timeout=20)
    if rc != 0:
        # METRICS_ALLOW (site agent) closes loopback: the answer is 403, the agent still reads it
        return "denied" if "403" in out else None
    d = {}
    for line in out.splitlines():
        if not line or line[0] == "#":
            continue
        m = re.match(r"^([^\s{]+(?:\{[^}]*\})?)\s+(\S+)$", line)
        if m:
            try:
                d[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
    return d

def vmagent_target_health(job, instance):
    rc, out = run(["docker", "inspect", "vmagent", "--format",
                   "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}"], timeout=10)
    ips = out.split() if rc == 0 else []
    if not ips:
        return "no vmagent"
    rc, out = run(["curl", "-fsS", "--max-time", "5", "http://%s:8429/targets" % ips[0]], timeout=10)
    if rc != 0:
        return "unreachable"
    for line in out.splitlines():
        if ('instance="%s"' % instance) in line and ('job="%s"' % job) in line:
            m = re.search(r"state=(\w+)", line)
            return m.group(1) if m else "unknown"
    return "absent"

metrics1 = {}
for cn, port in (("backend", 4977), ("ocpp", 9220)):
    if cn in running:
        metrics1[cn] = (time.time(), scrape(cn, port))

pool = ThreadPoolExecutor(max_workers=8)
f_check = pool.submit(t_check)
f_logs = [pool.submit(t_logs, n) for n in running]

# ── resources ───────────────────────────────────────────────────────────────
resources = {}
try:
    st = os.statvfs("/")
    resources["disk_pct"] = int(round(100.0 * (st.f_blocks - st.f_bfree) / (st.f_blocks - st.f_bfree + st.f_bavail)))
    mem = {}
    with open("/proc/meminfo") as f:
        for l in f:
            k, v = l.split(":", 1)
            mem[k] = int(v.split()[0])
    resources["mem_avail_mb"] = mem["MemAvailable"] // 1024
    resources["swap_used_mb"] = (mem["SwapTotal"] - mem["SwapFree"]) // 1024
    resources["load1"] = float(open("/proc/loadavg").read().split()[0])
    resources["cores"] = os.cpu_count()
except Exception as e:
    flag("warn", "resources", "not readable: %s" % e)
if resources.get("disk_pct", 0) >= DISK_WARN:
    flag("warn", "resources", "disk %d%% used" % resources["disk_pct"])
if resources.get("mem_avail_mb", 1 << 30) < MEM_WARN_MB:
    flag("warn", "resources", "MemAvailable %d MB" % resources["mem_avail_mb"])
if resources.get("cores") and resources.get("load1", 0) > resources["cores"]:
    flag("warn", "resources", "load1 %.1f over %d cores" % (resources["load1"], resources["cores"]))
rc, out = run(["sh", "-c", "dmesg -T 2>/dev/null | grep -iE 'out of memory|killed process' | tail -3"])
if out.strip():
    flag("warn", "resources", "dmesg OOM lines", sample=mask(out.strip())[:SAMPLE_LEN])

# ── nginx files ─────────────────────────────────────────────────────────────
nginx = {}
nginx_prev = state.get("nginx") or {}
rc, out = run(["sh", "-c", "docker volume ls -q | grep -E '_logs-nginx$'"])
vols = out.split()
logdir = None
vol = None
if arc and (arc + "_logs-nginx") in vols:
    vol = arc + "_logs-nginx"
elif len(vols) == 1:
    vol = vols[0]
if vol:
    rc, out = run(["docker", "volume", "inspect", "-f", "{{.Mountpoint}}", vol])
    if rc == 0 and out.strip():
        logdir = out.strip()
if not logdir:
    flag("warn", "nginx", "the nginx log volume was not found or is ambiguous (%d candidates): access logs not measured" % len(vols))

RX_MAIN = re.compile(r'^\S+ \S+ \S+ \[(\d\d/\w{3}/\d{4}:\d\d:\d\d:\d\d) ([+-]\d{4})\] "([^"]*)" (\d{3}) .* host=(\S+) rt=([\d.]+)(?: vh=\S*)?\s*$')
RX_OCPP = re.compile(r'^\S+ \S+ \S+ \[(\d\d/\w{3}/\d{4}:\d\d:\d\d:\d\d) ([+-]\d{4})\] "([^"]*)" (\d{3}) .* rt=([\d.]+)\s*$')
MON = {m: i + 1 for i, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}

def nginx_time(s, tz):
    d, mon, rest = s.split("/", 2)
    y, hh, mm, ss = rest.split(":")
    dt = datetime.datetime(int(y), MON[mon], int(d), int(hh), int(mm), int(ss))
    sign = 1 if tz[0] == "+" else -1
    dt -= sign * datetime.timedelta(hours=int(tz[1:3]), minutes=int(tz[3:5]))
    return dt.replace(tzinfo=datetime.timezone.utc)

def pct(sorted_list, p):
    if not sorted_list:
        return None
    return sorted_list[min(len(sorted_list) - 1, int(round(p * (len(sorted_list) - 1))))]

def day_filters():
    days = []
    d = w_from.date()
    while d <= (now + datetime.timedelta(days=1)).date():
        days.append("%02d/%s/%d:" % (d.day, list(MON)[d.month - 1], d.year))
        d += datetime.timedelta(days=1)
    return days

scan_info = {}

def scan_access(path, rx, hostgroup):
    stats = {}
    info = scan_info[path] = {"seen": 0, "parsed": 0}
    if not os.path.exists(path):
        return stats
    if not os.access(path, os.R_OK):
        flag("warn", "nginx", "%s is not readable" % os.path.basename(path))
        return stats
    days = day_filters()
    grep = ["grep", "-a"] + sum([["-e", x] for x in days], [])
    if path.endswith(".gz"):
        p1 = subprocess.Popen(["zcat", path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        p2 = subprocess.Popen(grep, stdin=p1.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True, errors="replace", bufsize=1 << 16)
        p1.stdout.close()
        stream = p2.stdout
    else:
        p2 = subprocess.Popen(grep + [path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True, errors="replace", bufsize=1 << 16)
        stream = p2.stdout
    for line in stream:
        info["seen"] += 1
        m = rx.match(line)
        if not m:
            continue
        info["parsed"] += 1
        t = nginx_time(m.group(1), m.group(2))
        if t < w_from or t > now:
            continue
        status = m.group(4)
        host = mask(m.group(5))[:80] if hostgroup else os.path.basename(path).split("_")[0]
        rt = float(m.group(6 if hostgroup else 5))
        s = stats.setdefault(host, {"req": 0, "s5": 0, "s4": 0, "rt": [], "paths5": {}})
        s["req"] += 1
        s["rt"].append(rt)
        if status.startswith("5"):
            s["s5"] += 1
            req = m.group(3).split(" ")
            key = "%s %s %s" % (status, req[0] if req else "", normalise(mask(req[1].split("?")[0])) if len(req) > 1 else "")
            s["paths5"][key] = s["paths5"].get(key, 0) + 1
        elif status.startswith("4"):
            s["s4"] += 1
    p2.wait()
    if info["seen"] and not info["parsed"]:
        flag("warn", "nginx", "%s: %d line(s) in the window, none matches the expected log format" % (os.path.basename(path), info["seen"]))
    return stats

if logdir:
    allstats = {}
    allstats.update(scan_access(os.path.join(logdir, "main_access.log.gz"), RX_MAIN, True))
    for f in ("ocpp_access.log", "ws_access.log"):
        allstats.update(scan_access(os.path.join(logdir, f), RX_OCPP, False))
    for host, s in sorted(allstats.items()):
        rt = sorted(s["rt"])
        nginx[host] = {"req": s["req"], "5xx": s["s5"], "5xx_share": round(s["s5"] / s["req"], 4) if s["req"] else 0.0,
                       "4xx": s["s4"], "rt_p50": pct(rt, .5), "rt_p95": pct(rt, .95), "rt_p99": pct(rt, .99)}
        if s["s5"] and (s["req"] >= RT_MIN_REQ or host in nginx_prev or s["s5"] >= 3):
            top = sorted(s["paths5"].items(), key=lambda kv: -kv[1])[:3]
            flag("warn", "nginx", "%s: %d x 5xx of %d requests" % (host, s["s5"], s["req"]),
                 top=[{"what": k, "n": v} for k, v in top])
        pv = nginx_prev.get(host) or {}
        if (s["req"] >= RT_MIN_REQ and pv.get("rt_p95") and nginx[host]["rt_p95"] is not None
                and nginx[host]["rt_p95"] >= RT_MIN_P95 and nginx[host]["rt_p95"] >= RT_GROWTH_X * pv["rt_p95"]):
            flag("warn", "nginx", "%s: rt p95 %.3fs, was %.3fs" % (host, nginx[host]["rt_p95"], pv["rt_p95"]))
    # nginx error log, fingerprinted like a container log
    ef = os.path.join(logdir, "main_error.log")
    if os.path.exists(ef):
        RX_E = re.compile(r"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d) \[(\w+)\]")
        cnt = {"error": 0, "warn": 0, "lines": 0}
        try:
            with open(ef, errors="replace") as f:
                for line in f:
                    m = RX_E.match(line)
                    if not m:
                        continue
                    t = parse_iso(m.group(1).replace("/", "-"))
                    if not t or t < w_from:
                        continue
                    cnt["lines"] += 1
                    lv = {"error": "error", "crit": "error", "alert": "error", "emerg": "error", "warn": "warn"}.get(m.group(2))
                    if lv:
                        cnt[lv] += 1
                        fps.add("nginx-error", lv, line.rstrip("\n"), iso(t))
        except Exception as e:
            flag("warn", "nginx", "main_error.log not read: %s" % e)
        fps.counts["nginx-error"] = cnt

# ── database ────────────────────────────────────────────────────────────────
db = {"ok": False}
def psql(dbname, sql):
    return run(["docker", "exec", "-i", "postgres", "psql", "-U", "postgres", "-d", dbname,
                "-X", "-A", "-t", "-v", "ON_ERROR_STOP=0"], timeout=90, stdin=sql)

dbname = opt["db"]
if "postgres" in running:
    if not dbname:
        rc, out = psql("postgres", "select datname from pg_database where not datistemplate and datname<>'postgres';\n")
        names = [x for x in out.split() if x]
        if len(names) == 1:
            dbname = names[0]
        elif arc and arc in names:
            dbname = arc
    if dbname:
        w_sql = w_from.strftime("%Y-%m-%d %H:%M:%S+00")
        sql = """
select json_build_object('q','activity',
  'by_state',(select coalesce(json_object_agg(coalesce(state,'null'),c),'{}'::json) from (select state,count(*) c from pg_stat_activity where datname=current_database() group by 1) t),
  'idle_in_tx',(select count(*) from pg_stat_activity where state like 'idle in transaction%'),
  'idle_in_tx_oldest_s',(select coalesce(max(extract(epoch from now()-state_change))::int,0) from pg_stat_activity where state like 'idle in transaction%'),
  'oldest_xact_s',(select coalesce(max(extract(epoch from now()-xact_start))::int,0) from pg_stat_activity where xact_start is not null and pid<>pg_backend_pid() and backend_type='client backend' and state<>'idle'),
  'lock_waiters',(select count(*) from pg_stat_activity where wait_event_type='Lock'),
  'conns',(select count(*) from pg_stat_activity),
  'max_conns',current_setting('max_connections')::int);
select json_build_object('q','database','postmaster_start',pg_postmaster_start_time(),
  'size_mb',(pg_database_size(current_database())/1048576)::bigint,
  'row',(select row_to_json(d) from (select xact_commit,xact_rollback,deadlocks,conflicts,temp_files,temp_bytes,blks_read,blks_hit,stats_reset from pg_stat_database where datname=current_database()) d));
select json_build_object('q','pgss','present',exists(select 1 from pg_extension where extname='pg_stat_statements'));
select json_build_object('q','dblog','t',t,'text',x,'n',count(*),'first',min(d),'last',max(d)) from (select type t, datetime d, case when type='W' and code=4040 and event='offline' and text !~ '^CONFIG' and strpos(text,': ')>0 then split_part(text,': ',1)||': '||coalesce(array_length(string_to_array(rtrim(substr(text,strpos(text,': ')+2),'.'),', '),1),0) else left(text,300) end x from db.log where datetime>='@W@' and type in ('E','W')) s group by t,x order by count(*) desc limit 300;
select json_build_object('q','stops','waiting',count(*) filter (where finished is null and created<now()-interval '120 seconds'),'failed',count(*) filter (where finished>='@W@' and status is distinct from 200),'total',count(*) filter (where created>='@W@')) from ocpp.command where action in ('RequestStopTransaction','RemoteStopTransaction') and (created>='@W@' or finished>='@W@' or (finished is null and created>now()-interval '1 day'));
select json_build_object('q','cost','stations',count(*),'silent',count(*) filter (where ok=0 and n>=3)) from (select identity, count(*) n, count(*) filter (where status=200) ok from ocpp.command where action='CostUpdated' and created>='@W@'::timestamptz-interval '120 seconds' and created<now()-interval '120 seconds' group by identity) c;
select json_build_object('q','sessions','closed',count(*),'no_invoice',count(*) filter (where t.client is not null and t.invoice is null),'paid',count(*) filter (where si.code='disabled'),'closed_inv',count(*) filter (where si.code='closed'),'failed_inv',count(*) filter (where si.code='failed'),'pending_inv',count(*) filter (where si.code='in_progress'),'unpaid_inv',count(*) filter (where si.code='created')) from db.transaction t join db.object o on o.id=t.id left join db.object oi on oi.id=t.invoice left join db.state si on si.id=oi.state where o.state_type=(select id from db.state_type where code='disabled') and o.udate>='@W@'::timestamptz-interval '15 minutes' and o.udate<now()-interval '15 minutes';
select json_build_object('q','apilog','path',path,'n',count(*),'p50',round((percentile_cont(0.5) within group (order by extract(epoch from runtime)*1000))::numeric,1),'p95',round((percentile_cont(0.95) within group (order by extract(epoch from runtime)*1000))::numeric,1)) from db.api_log where datetime>='@W@' group by path order by count(*) desc limit 40;
select json_build_object('q','tables','t',schemaname||'.'||relname,'seq_scan',seq_scan,'seq_tup_read',seq_tup_read,'idx_scan',idx_scan,'n_dead_tup',n_dead_tup,'n_live_tup',n_live_tup) from pg_stat_user_tables order by seq_tup_read desc limit 12;
select json_build_object('q','tables','t',schemaname||'.'||relname,'seq_scan',seq_scan,'seq_tup_read',seq_tup_read,'idx_scan',idx_scan,'n_dead_tup',n_dead_tup,'n_live_tup',n_live_tup) from pg_stat_user_tables order by n_dead_tup desc limit 5;
""".replace("@W@", w_sql)
        def parse_psql(rc, out):
            got = []
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("{"):
                    try:
                        got.append(json.loads(line))
                    except ValueError:
                        pass
                elif re.match(r"(?i)^(psql: )?(error|fatal)\b", line) or "No such container" in line or line.startswith("Error response"):
                    flag("warn", "database", "SQL error: " + mask(line)[:160])
            if rc != 0 and not got:
                flag("warn", "database", "psql exited %s" % rc)
            return got
        rc, out = psql(dbname, sql)
        rows = parse_psql(rc, out)
        db = {"ok": bool(rows), "name": dbname, "rows": rows}
        seen_q = {r.get("q") for r in rows}
        for need in ("activity", "database", "pgss", "stops", "cost", "sessions"):
            if rows and need not in seen_q:
                flag("warn", "database", "the %s query returned nothing" % need)
        if any(q.get("q") == "pgss" and q.get("present") for q in rows):
            rc, out = psql(dbname, "select json_build_object('q','stmt','id',queryid::text,'calls',calls,'total_ms',round(total_exec_time::numeric,1),'mean_ms',round(mean_exec_time::numeric,3),'query80',left(regexp_replace(query,'\\s+',' ','g'),80)) from pg_stat_statements where dbid=(select oid from pg_database where datname=current_database()) and query ~* '^\\s*(select|insert|update|delete|with|merge)' order by total_exec_time desc limit 40;\n")
            stmts = parse_psql(rc, out)
            if not stmts:
                flag("warn", "database", "pg_stat_statements is present but returned no statements")
            db["rows"].extend(stmts)
    else:
        flag("warn", "database", "could not choose the database (pass --db)")

state_db = {}
pgsd_new = {}
pgss_new = {}
tables_new = {}
api_new = {}
sessions_new = {}
if db.get("ok"):
    rows = db["rows"]
    for r in rows:
        q = r.get("q")
        if q == "activity":
            if r["idle_in_tx_oldest_s"] >= IDLE_TX_S:
                flag("warn", "database", "idle in transaction %d, oldest %d s" % (r["idle_in_tx"], r["idle_in_tx_oldest_s"]))
            if r["oldest_xact_s"] >= OLDEST_XACT_S:
                flag("warn", "database", "a client transaction is %d s old" % r["oldest_xact_s"])
            if r["lock_waiters"] > 0:
                flag("warn", "database", "%d backend(s) waiting on a lock" % r["lock_waiters"])
            if r["max_conns"] and float(r["conns"]) / r["max_conns"] >= CONN_RATIO:
                flag("warn", "database", "connections %d of %d" % (r["conns"], r["max_conns"]))
            state_db["activity"] = {k: r[k] for k in ("idle_in_tx", "oldest_xact_s", "conns", "max_conns")}
        elif q == "database":
            row = r.get("row") or {}
            pm = r.get("postmaster_start")
            prev_epoch = (state.get("epochs") or {}).get("postmaster_start")
            prev_row = state.get("pg_stat_database") or {}
            same = (prev_epoch and pm and parse_iso(prev_epoch) == parse_iso(pm)
                    and (row.get("stats_reset") or None) == ((state.get("epochs") or {}).get("stats_reset") or None))
            delta = {}
            if same:
                for k in ("xact_commit", "xact_rollback", "deadlocks", "conflicts", "temp_files"):
                    if prev_row.get(k) is not None and row.get(k) is not None:
                        delta[k] = row[k] - prev_row[k]
                if delta.get("deadlocks", 0) > 0:
                    flag("warn", "database", "deadlocks +%d" % delta["deadlocks"])
                if delta.get("conflicts", 0) > 0:
                    flag("warn", "database", "conflicts +%d" % delta["conflicts"])
                if delta.get("xact_commit", 0) > 1000 and delta.get("xact_rollback", 0) / max(delta["xact_commit"], 1) > 0.05:
                    flag("warn", "database", "rollbacks %d of %d commits in the window" % (delta["xact_rollback"], delta["xact_commit"]))
            state_db["delta"] = delta if same else None
            state_db["epoch_same"] = bool(same)
            state_db["size_mb"] = r.get("size_mb")
            pgsd_new = {k: row.get(k) for k in ("xact_commit", "xact_rollback", "deadlocks", "conflicts", "temp_files", "temp_bytes", "blks_read", "blks_hit")}
            pgsd_new["measured_at"] = iso(now)
            state_db["epochs"] = {"postmaster_start": pm, "stats_reset": row.get("stats_reset")}
            resources["db_size_mb"] = r.get("size_mb")
        elif q == "dblog":
            fps.add("db.log", "error" if r["t"] == "E" else "warn", r["text"], r.get("last"), n=r["n"], tag=r["t"])
            e = fps.d[fp_id("db.log", r["t"] + " " + normalise(r["text"]))]
            if r.get("first") and (not e["first"] or r["first"] < e["first"]):
                e["first"] = r["first"]
        elif q == "apilog":
            api_new[mask(r["path"])[:120]] = {"calls": r["n"], "p50_ms": r["p50"], "p95_ms": r["p95"]}
        elif q == "stops":
            sessions_new["stops"] = {k: r[k] for k in ("waiting", "failed", "total")}
            if r["waiting"]:
                flag("warn", "sessions", "%d stop command(s) waiting past their term (%d stops in the window)" % (r["waiting"], r["total"]))
            if r["failed"]:
                flag("warn", "sessions", "%d stop command(s) finished without a 200 (no answer of the station, or a refusal) (%d stops in the window)" % (r["failed"], r["total"]))
        elif q == "cost":
            sessions_new["cost_updated"] = {k: r[k] for k in ("stations", "silent")}
            if r["silent"]:
                flag("warn", "sessions", "%d station(s) never answered CostUpdated in the window (3 or more sent)" % r["silent"])
        elif q == "sessions":
            sessions_new["closed"] = {k: r[k] for k in ("closed", "no_invoice", "paid", "closed_inv", "failed_inv", "pending_inv", "unpaid_inv")}
            if r["no_invoice"]:
                flag("warn", "sessions", "%d closed session(s) with a client but no invoice, closed over 15 min ago (of %d closed)" % (r["no_invoice"], r["closed"]))
            if r["pending_inv"]:
                flag("warn", "sessions", "%d closed session(s) whose invoice is still in progress, closed over 15 min ago (of %d closed)" % (r["pending_inv"], r["closed"]))
        elif q == "tables":
            tables_new[r["t"]] = {k: r[k] for k in ("seq_scan", "seq_tup_read", "idx_scan", "n_dead_tup")}
            tables_new[r["t"]]["n_live_tup"] = r.get("n_live_tup")
        elif q == "stmt":
            pgss_new[r["id"]] = {"calls": r["calls"], "total_ms": r["total_ms"], "mean_ms": r["mean_ms"], "query80": mask(r["query80"])}
    # statement regressions: same id, enough calls in the window, delta mean grew
    prev_pgss = state.get("pg_stat_statements") or {}
    if state_db.get("epoch_same"):
        for qid, cur in pgss_new.items():
            pv = prev_pgss.get(qid)
            if not pv or pv.get("total_ms") is None:
                continue
            dc = cur["calls"] - pv["calls"]
            if dc < PGSS_MIN_CALLS:
                continue
            dmean = (cur["total_ms"] - pv["total_ms"]) / dc
            base = pv.get("mean_ms") or 0
            if dmean >= PGSS_MIN_MS and base and dmean >= PGSS_X * base:
                flag("warn", "database", "statement %s: %.1f ms/call over %d calls, was %.1f" % (qid, dmean, dc, base),
                     query=pv.get("query80") or cur["query80"])
    # tables: heavy sequential reads and dead tuples
    prev_t = state.get("tables") or {}
    for t, cur in tables_new.items():
        pv = prev_t.get(t)
        if pv and state_db.get("epoch_same") and cur["seq_tup_read"] - (pv.get("seq_tup_read") or 0) >= SEQ_TUP_DELTA:
            flag("warn", "database", "%s: %.1e rows read sequentially in the window" % (t, cur["seq_tup_read"] - pv["seq_tup_read"]))
        live = cur.get("n_live_tup") or 0
        if cur["n_dead_tup"] >= DEAD_MIN and cur["n_dead_tup"] > 0.2 * max(live, 1):
            flag("warn", "database", "%s: %d dead tuples (live %d)" % (t, cur["n_dead_tup"], live))
    # api paths: p95 grew
    prev_a = state.get("api_log") or {}
    for pth, cur in api_new.items():
        pv = prev_a.get(pth)
        if (pv and pv.get("p95_ms") and cur["calls"] >= 20 and cur["p95_ms"] and cur["p95_ms"] >= API_MIN_P95_MS
                and cur["p95_ms"] >= RT_GROWTH_X * pv["p95_ms"]):
            flag("warn", "api", "%s p95 %.0f ms, was %.0f ms (%d calls)" % (pth, cur["p95_ms"], pv["p95_ms"], cur["calls"]))
elif "postgres" in running:
    flag("warn", "database", "the SQL part did not run")
else:
    flag("fail", "database", "postgres container is not running")

# ── logs gathered ───────────────────────────────────────────────────────────
for f in f_logs:
    try:
        name, local = f.result()
        merge_local(local)
    except Exception as e:
        flag("warn", "logs", "a container log was not collected: %s" % e)

# compare fingerprints with the stored ones
known = state.get("fingerprints") if fp_state_ok else {}
known = known or {}
prev_hours = 1.0
if state.get("window"):
    a, b = parse_iso(state["window"].get("from", "")), parse_iso(state["window"].get("to", ""))
    if a and b:
        prev_hours = max((b - a).total_seconds() / 3600.0, 1 / 60.0)
new_fp, grown_fp, known_n = {}, [], 0
fp_state = {k: dict(v) for k, v in known.items()}
for k, e in fps.d.items():
    e["per_hour"] = round(e["count"] / hours, 2)
    if k in known:
        known_n += e["count"]
        kv = known[k]
        old_rate = kv.get("per_hour")
        if old_rate is None and kv.get("count") is not None:
            old_rate = kv["count"] / prev_hours
        if old_rate is not None and e["count"] >= GROWTH_MIN_COUNT and e["per_hour"] >= GROWTH_X * max(old_rate, 1 / prev_hours):
            grown_fp.append({"id": k, "container": e["container"], "level": e["level"], "count": e["count"],
                             "per_hour": e["per_hour"], "was_per_hour": round(old_rate, 2),
                             "noise": kv.get("noise"), "sample": e["sample"]})
        fp_state[k].update({"per_hour": e["per_hour"], "count": e["count"], "last": e["last"], "container": e["container"], "level": e["level"]})
    else:
        new_fp[k] = e
new_sorted = sorted(new_fp.items(), key=lambda kv: (0 if kv[1]["level"] == "error" else 1, -kv[1]["count"]))
# the state stays small: a known fingerprint unseen for FP_KEEP_DAYS goes, pending is capped
cutoff = iso(now - datetime.timedelta(days=FP_KEEP_DAYS))[:10]
for k in [k for k, v in fp_state.items() if k not in fps.d and (v.get("last") or "9999")[:10] < cutoff]:
    del fp_state[k]

# ── metrics (second scrape) ─────────────────────────────────────────────────
metrics_state = {}
metrics_facts = {}
def msum(d, prefix, **lab):
    tot, seen = 0.0, False
    for k, v in d.items():
        if not (k == prefix or k.startswith(prefix + "{")):
            continue
        if all(('%s="%s"' % (a, b)) in k for a, b in lab.items()):
            tot += v
            seen = True
    return tot if seen else None

for cn, port in (("backend", 4977), ("ocpp", 9220)):
    if cn not in metrics1:
        continue
    t1, m1 = metrics1[cn]
    m2 = scrape(cn, port)
    t2 = time.time()
    if m1 == "denied" or m2 == "denied":
        # the site agent (vmagent) is the only reader; its targets page says whether it gets the series
        health = vmagent_target_health("csms-app", cn)
        if health != "up":
            flag("warn", "metrics", "%s /metrics closed to loopback (METRICS_ALLOW) and the site agent target is %s" % (cn, health))
        else:
            metrics_facts[cn] = "read by the site agent only (METRICS_ALLOW); target up"
        continue
    if m1 is None or m2 is None:
        flag("warn", "metrics", "%s /metrics unreachable" % cn)
        continue
    el = max(t2 - t1, 1.0)
    ups = [v for k, v in m2.items() if k.startswith("csms_process_up{")]
    up_n = sum(1 for v in ups if v == 1)
    if any(v == 0 for v in ups):
        flag("fail", "metrics", "%s: a process is down (csms_process_up=0)" % cn)
    prev_up = (state.get("metrics") or {}).get("csms_process_up_" + cn)
    if prev_up is not None and up_n < prev_up:
        flag("fail", "metrics", "%s: processes up %d, was %d" % (cn, up_n, prev_up))
    metrics_state["csms_process_up_" + cn] = up_n
    sql_up = msum(m2, "csms_metrics_sql_up")
    if cn == "backend":
        if sql_up is None:
            flag("warn", "metrics", "csms_metrics_sql_up absent (domain rows unknown)")
        elif sql_up != 1:
            flag("warn", "metrics", "csms_metrics_sql_up=%d" % sql_up)
        metrics_state["csms_metrics_sql_up"] = sql_up
    for k, v in m2.items():
        if (k.startswith("csms_db_listener_up{") or k.startswith("csms_db_listen{")) and v == 0:
            flag("fail", "metrics", "%s: %s = 0" % (cn, k[:100]))
    for name, limit in (("csms_notify_queue_oldest_waiting_seconds", STUCK_S),
                        ("csms_outbox_oldest_unsent_seconds", None),
                        ("csms_http_oldest_open_seconds", None)):
        for k, v in m2.items():
            if not (k == name or k.startswith(name + "{")):
                continue
            v1 = m1.get(k)
            stuck = v1 is not None and v1 > 0 and v >= 10 and (v - v1) >= 0.8 * el
            if (limit and v >= limit) or stuck:
                flag("warn", "metrics", "%s: %s = %.0f s%s" % (cn, k[:100], v, " and growing (was %.0f s %d s ago)" % (v1, el) if stuck else ""))
    for k, v in m2.items():
        if k.startswith("csms_worker_db_pool_queued{") and 'role="worker"' in k and v > 0 and m1.get(k, 0) > 0:
            flag("warn", "metrics", "%s: %s > 0 in both scrapes" % (cn, k[:100]))
        if k.startswith("csms_ocpp_calls_pending{") and v > 0 and m1.get(k, 0) > 0:
            flag("warn", "metrics", "%s: %s stuck above 0" % (cn, k[:100]))
    # counters: only within one container epoch
    same_epoch = (prev_started.get(cn) == containers[cn]["started"]) if cn in containers else False
    def mk(name):
        return "%s@%s" % (name, cn)
    for fam, labels in (("csms_ocpp_commands_total", ("success", "error", "timeout")),):
        if msum(m2, fam) is None:
            continue
        cur = {r: msum(m2, fam, result=r) or 0 for r in labels}
        for r in labels:
            metrics_state[mk('%s{result="%s"}' % (fam, r))] = cur[r]
        if same_epoch:
            pv = {r: (state.get("metrics") or {}).get(mk('%s{result="%s"}' % (fam, r))) for r in labels}
            if all(v is not None for v in pv.values()):
                d = {r: cur[r] - pv[r] for r in labels}
                tot_d = sum(d.values())
                bad_d = d["error"] + d["timeout"]
                tot_old = sum(pv.values())
                share_old = (pv["error"] + pv["timeout"]) / tot_old if tot_old else 0.0
                if tot_d >= 10 and bad_d >= 3 and bad_d / tot_d >= max(2 * share_old, share_old + 0.1):
                    flag("warn", "metrics", "ocpp commands: %d of %d failed in the window (stored share %.2f)" % (bad_d, tot_d, share_old))
    for fam in ("csms_ocpp_result_repeats_total", "csms_notify_retries_total"):
        v = msum(m2, fam)
        if v is not None:
            metrics_state[mk(fam)] = v
            pv = (state.get("metrics") or {}).get(mk(fam))
            if same_epoch and pv is not None and v > pv:
                flag("warn", "metrics", "%s +%d" % (fam, v - pv))
    v = msum(m2, "csms_notify_handled_total", result="failed")
    if v is not None:
        metrics_state[mk('csms_notify_handled_total{result="failed"}')] = v
        pv = (state.get("metrics") or {}).get(mk('csms_notify_handled_total{result="failed"}'))
        if (same_epoch and pv is not None and v > pv) or (not same_epoch and v > 0):
            flag("warn", "metrics", "csms_notify_handled_total{result=failed} = %d%s" % (v, " (+%d)" % (v - pv) if same_epoch and pv is not None else " since the container start"))
    for fam in ("csms_stations_online", "csms_stations_total", "csms_sessions_active", "csms_ocpp_connections"):
        v = msum(m2, fam)
        if v is not None:
            metrics_state[mk(fam)] = v
            metrics_facts[fam.replace("csms_", "")] = v

# ── check.sh ────────────────────────────────────────────────────────────────
chk = None
ver = None
try:
    chk = f_check.result()
except Exception as e:
    chk = {"error": str(e)}
check_out = None
if chk:
    if "error" in chk:
        flag("warn", "check.sh", "did not run: %s" % chk["error"])
    else:
        bad = {k: v for k, v in (chk.get("checks") or {}).items() if v.get("status") != "ok"}
        check_out = {"overall": chk.get("overall"), "not_ok": {k: mask("%s: %s" % (v["status"], v.get("details", ""))) for k, v in bad.items()}}
        for k, v in bad.items():
            flag("fail" if v["status"] == "fail" else "warn", "check.sh", mask("%s — %s" % (k, v.get("details", ""))))
        ver = ((chk.get("checks") or {}).get("version") or {}).get("details")

# ── log level flags ─────────────────────────────────────────────────────────
n_err_new = sum(1 for k, e in new_fp.items() if e["level"] == "error")
if n_err_new:
    flag("warn", "logs", "%d new error fingerprint(s)" % n_err_new)
if grown_fp:
    flag("warn", "logs", "%d known fingerprint(s) at >= %dx their stored rate" % (len(grown_fp), GROWTH_X))

# ── output ──────────────────────────────────────────────────────────────────
# flags the owner accepted (state.accepted_flags: area + substring of the message,
# reason, and a card or the owner's recorded word) are counted, not reported as findings.
# A `fail` is never accepted; an entry without a reason, without a card / owner_word,
# or with a substring shorter than ACCEPT_MIN_MATCH characters accepts nothing.
ACCEPT_MIN_MATCH = 8
def _text(v):
    return isinstance(v, str) and bool(v.strip())
def _why_not(a):
    # the missing condition of a stored entry, or None when it is acceptable
    if not isinstance(a, dict): return "not an object"
    if not _text(a.get("area")): return "no area"
    if not _text(a.get("match")) or len(a["match"].strip()) < ACCEPT_MIN_MATCH: return "match shorter than %d characters" % ACCEPT_MIN_MATCH
    if not _text(a.get("reason")): return "no reason"
    if not (_text(a.get("card")) or _text(a.get("owner_word"))): return "no card or owner_word"
    return None
stored = state.get("accepted_flags")
stored = stored if isinstance(stored, list) else []
accepted, ignored = [], []
for idx, a in enumerate(stored):
    why = _why_not(a)
    if why: ignored.append("#%d %s%s: %s" % (idx, a.get("area", "") if isinstance(a, dict) else "", (" / " + str(a.get("match"))[:30]) if isinstance(a, dict) and a.get("match") else "", why))
    else: accepted.append(a)
if state.get("accepted_flags") is not None and not isinstance(state.get("accepted_flags"), list):
    ignored.append("accepted_flags is not a list")
live_flags, accepted_hits = [], []
for f in flags:
    hit = None if f["sev"] == "fail" else next((a for a in accepted if a["area"] == f["area"] and a["match"] in f["msg"]), None)
    if hit:
        accepted_hits.append({k: v for k, v in {"area": f["area"], "msg": f["msg"], "reason": hit.get("reason"),
                                                "card": hit.get("card"), "owner_word": hit.get("owner_word")}.items() if v})
    else:
        live_flags.append(f)
log_counts = {n: c for n, c in sorted(fps.counts.items())}
rep = {
    "tool": "server-check.sh", "v": VERSION, "site": site, "now": iso(now), "elapsed_s": int(time.time() - T0),
    "baseline": baseline,
    "window": {"from": iso(w_from), "to": iso(now), "hours": round(hours, 2)},
    "candidate": "clean" if not live_flags else ("fail" if any(f["sev"] == "fail" for f in live_flags) else "findings"),
    "flags": live_flags,
    "accepted_flags": accepted_hits,
    **({"accepted_ignored": ignored} if ignored else {}),
    "rollout": rollout,
    "check_sh": (check_out or {}).get("overall"),
    "resources": resources,
    "logs": {
        "lines_error_warn": {n: {"error": c["error"], "warn": c["warn"], "lines": c["lines"]} for n, c in log_counts.items()
                             if c["error"] or c["warn"]},
        "lines_total": sum(c["lines"] for c in log_counts.values()),
        "known_noise_hits": known_n,
        "new": [dict(id=k, **{x: e[x] for x in ("container", "level", "count", "per_hour", "first", "last", "sample")})
                for k, e in new_sorted[:MAX_NEW]],
        "new_more": max(0, len(new_sorted) - MAX_NEW),
        "grown": grown_fp,
    },
    "database": {"name": db.get("name"), "size_mb": state_db.get("size_mb"), "activity": state_db.get("activity"),
                 "counter_delta": state_db.get("delta"), "epoch_same": state_db.get("epoch_same")} if db.get("ok") else None,
    "nginx": {"hosts": len(nginx), "requests": sum(v["req"] for v in nginx.values()),
              "5xx": sum(v["5xx"] for v in nginx.values()), "measured": bool(logdir) and any(v["parsed"] for v in scan_info.values())},
    "metrics": metrics_facts,
    "sessions": sessions_new or None,
}
if not baseline and state.get("fingerprints_v") != 2:
    rep["note"] = "fingerprints of the previous record are not in this scheme: every error/warning below is new"
if not fp_state_ok and state.get("fingerprints"):
    rep["legacy_known"] = len(state["fingerprints"])

new_state = {
    "site": site,
    "window": {"from": iso(w_from), "to": iso(now)},
    "config": {"images": {n: containers[n]["image"] for n in running},
               "tags": {n: containers[n]["tag"] for n in running},
               "started_at": {n: containers[n]["started"] for n in running},
               "restarts": {n: containers[n]["restarts"] for n in running},
               "installed_version": ver},
    "fingerprints_v": 2,
    "fingerprints": fp_state,
    "pending_fingerprints": {k: {x: e[x] for x in ("container", "level", "count", "per_hour", "first", "last", "sample")}
                             for k, e in new_sorted[:PENDING_MAX]},
    "pending_dropped": max(0, len(new_sorted) - PENDING_MAX),
    "resources": resources,
}
if workdir:
    try:
        with open(os.path.join(workdir, "docker-compose.yaml"), "rb") as f:
            new_state["config"]["compose_sha256"] = hashlib.sha256(f.read()).hexdigest()
    except Exception:
        pass
if db.get("ok"):
    new_state["epochs"] = dict(state.get("epochs") or {}, **state_db.get("epochs", {}))
    new_state["epochs"]["containers_started"] = max(c["started"] for n, c in containers.items() if c["running"]) if running else None
    new_state["pg_stat_database"] = pgsd_new
    new_state["pg_stat_statements"] = pgss_new      # replaced, never merged: a stale entry would be diffed across an epoch
    new_state["tables"] = tables_new
    new_state["api_log"] = api_new
if metrics_state:
    new_state["metrics"] = dict(state.get("metrics") or {}, **metrics_state)
if nginx:
    ns = dict(state.get("nginx") or {})
    # only hosts with traffic: a scanner's Host header is not a site
    for h, v in sorted(nginx.items(), key=lambda kv: -kv[1]["req"])[:20]:
        if v["req"] >= RT_MIN_REQ or h in ns:
            ns[h] = {"req": v["req"], "5xx_share": v["5xx_share"], "rt_p95": v["rt_p95"]}
    new_state["nginx"] = ns

print(json.dumps({"report": rep, "state": new_state}, ensure_ascii=False, separators=(",", ":"), default=str))
PYEOF
)" "$@"
