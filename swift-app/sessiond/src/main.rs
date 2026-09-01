mod integration;
mod pane;
mod protocol;

use pane::{OutFrame, Pane};
use protocol::{AttachRequest, PaneInfo, SpawnRequest};
use std::collections::HashMap;
use std::io;
use std::io::Read as _;
use std::io::Write as _;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};

/// The socket this daemon serves on — pane env injection reads it.
static SOCKET_PATH: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

#[derive(Clone, PartialEq, Eq)]
struct AgentReport {
    state: &'static str,
    seq: u64,
    /// Background async-job rows from the same extension report
    /// (capability 6); empty when the extension is older or jobless.
    jobs: Vec<protocol::AgentJobInfo>,
}

#[derive(Default)]
struct Registry {
    panes: Mutex<HashMap<String, Arc<Pane>>>,
    agent_states: Mutex<HashMap<String, AgentReport>>,
}

impl Registry {
    fn get(&self, id: &str) -> Option<Arc<Pane>> {
        self.panes.lock().ok()?.get(id).cloned()
    }

    fn insert(&self, pane: Arc<Pane>) -> Result<(), String> {
        let mut panes = self.panes.lock().map_err(|_| "registry poisoned")?;
        if panes.contains_key(&pane.id) {
            return Err(format!("pane {} already exists", pane.id));
        }
        panes.insert(pane.id.clone(), pane.clone());
        Ok(())
    }

    fn remove(&self, id: &str) -> Option<Arc<Pane>> {
        self.panes.lock().ok()?.remove(id)
    }

    /// Extension report: keep the highest seq per pane so late or
    /// duplicated reports cannot travel the state backwards.
    fn apply_report(&self, pane: &str, report: AgentReport) {
        if let Ok(mut states) = self.agent_states.lock() {
            let stale = states
                .get(pane)
                .is_some_and(|current| current.seq > report.seq);
            if !stale {
                states.insert(pane.to_string(), report);
            }
        }
    }

    fn list(&self) -> Vec<PaneInfo> {
        let panes: Vec<Arc<Pane>> = self
            .panes
            .lock()
            .map(|panes| panes.values().cloned().collect())
            .unwrap_or_default();
        let states = self.agent_states.lock().ok();
        panes
            .into_iter()
            .map(|pane| {
                let mut info = pane.info();
                if let Some(states) = &states
                    && let Some(report) = states.get(&pane.id)
                {
                    info.agent = Some(report.state.to_string());
                    info.agent_jobs = report.jobs.clone();
                }
                info
            })
            .collect()
    }
}

fn main() -> anyhow::Result<()> {
    let socket = socket_argument()?;
    detach_stdio(&socket);
    let listener = bind_singleton(&socket)?;
    let _ = SOCKET_PATH.set(socket.clone());
    // omp/pi state extension: installed wherever those agents live on
    // THIS machine (local daemon now; the remote daemon repeats this on
    // its own host when the SSH link starts it — no extra transfer).
    integration::install_extension();
    println!("READY");
    std::io::stdout().flush()?;
    let registry = Arc::new(Registry::default());

    for connection in listener.incoming() {
        let Ok(mut stream) = connection else { continue };
        let registry = registry.clone();
        let _ = std::thread::Builder::new()
            .name("goty-session-client".to_string())
            .spawn(move || {
                // Read one 5-byte head. Frames are [len:4][kind:1];
                // extension reports are one JSON line. Strict frame
                // test: length ≤ MAX_FRAME AND kind in 1..=8 — a
                // report's head (`{"pa` → huge length, kind 'p')
                // fails both, so no frame can ever misroute.
                let mut head = [0u8; 5];
                if stream.read_exact(&mut head).is_err() {
                    return;
                }
                let len = u32::from_le_bytes([head[0], head[1], head[2], head[3]]) as usize;
                if len <= protocol::MAX_FRAME && (1..=11).contains(&head[4]) {
                    let _ = serve(&head, stream, registry);
                } else if head[0] == b'{' {
                    let _ = serve_report(&head, stream, &registry);
                }
            });
    }
    Ok(())
}

/// The daemon is a detached singleton: it outlives the GUI that launched
/// it, and the inherited stdio is that GUI's pipe/pty — which dies with
/// it. `eprintln!` PANICS on a broken stderr, and that panic killed every
/// SPAWN thread: after a GUI relaunch, new agent panes (and therefore
/// session resumes) failed silently while VERSION/LIST kept working.
/// Point stdin at the void and stdout/stderr at a durable log file.
fn detach_stdio(socket: &Path) {
    let log_path = socket.with_file_name("sessiond.log");
    let devnull = std::fs::File::open("/dev/null");
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path);
    unsafe {
        if let Ok(file) = devnull {
            libc::dup2(std::os::unix::io::AsRawFd::as_raw_fd(&file), 0);
        }
        match log {
            Ok(file) => {
                let fd = std::os::unix::io::AsRawFd::as_raw_fd(&file);
                libc::dup2(fd, 1);
                libc::dup2(fd, 2);
            }
            Err(_) => {
                if let Ok(file) = std::fs::File::open("/dev/null") {
                    let fd = std::os::unix::io::AsRawFd::as_raw_fd(&file);
                    libc::dup2(fd, 1);
                    libc::dup2(fd, 2);
                }
            }
        }
    }
}

/// One extension report: its first 5 bytes plus the rest of one JSON
/// line, `{"pane":..,"state":..,"seq":..,"jobs"?}\n`. Any reply closes
/// the connection (the extension only needs delivery confirmation).
fn serve_report(head: &[u8; 5], mut stream: UnixStream, registry: &Registry) -> anyhow::Result<()> {
    use std::io::BufRead;
    let mut line = head.to_vec();
    let mut reader = std::io::BufReader::new(&mut stream);
    reader.read_until(b'\n', &mut line)?;
    let end = line.iter().position(|&b| b == b'\n').unwrap_or(line.len());
    let value: serde_json::Value = serde_json::from_slice(&line[..end])?;
    let pane = value.get("pane").and_then(|v| v.as_str()).unwrap_or("");
    let report = parse_report(&value);
    if !pane.is_empty() {
        registry.apply_report(pane, report);
    }
    let _ = stream.write_all(b"{}\n");
    Ok(())
}

/// Report body → AgentReport. Unknown states settle idle (the old
/// contract); a malformed `jobs` array drops wholesale, never the
/// state — the badge must not die with the dock.
fn parse_report(value: &serde_json::Value) -> AgentReport {
    let state = value.get("state").and_then(|v| v.as_str()).unwrap_or("");
    AgentReport {
        state: match state {
            "working" => "working",
            "blocked" => "blocked",
            _ => "idle",
        },
        seq: value.get("seq").and_then(|v| v.as_u64()).unwrap_or(0),
        jobs: value
            .get("jobs")
            .and_then(|v| serde_json::from_value::<Vec<protocol::AgentJobInfo>>(v.clone()).ok())
            .unwrap_or_default(),
    }
}

fn socket_argument() -> anyhow::Result<PathBuf> {
    let mut args = std::env::args_os();
    let _ = args.next();
    let Some(path) = args.next() else {
        anyhow::bail!("usage: goty-sessiond SOCKET_PATH");
    };
    Ok(path.into())
}

fn bind_singleton(path: &Path) -> anyhow::Result<UnixListener> {
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            anyhow::bail!("session daemon is already running");
        }
        std::fs::remove_file(path)?;
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let listener = UnixListener::bind(path)?;
    set_private_socket(path)?;
    Ok(listener)
}

fn set_private_socket(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

fn serve(head: &[u8; 5], mut stream: UnixStream, registry: Arc<Registry>) -> anyhow::Result<()> {
    // The head's length field was already validated by the dispatcher;
    // finish the first frame (kind + payload), then hand off below.
    let len = u32::from_le_bytes([head[0], head[1], head[2], head[3]]) as usize;
    let kind = head[4];
    let mut payload = vec![0u8; len];
    std::io::Read::read_exact(&mut stream, &mut payload)?;
    dispatch(kind, payload, stream, registry)
}

fn dispatch(
    kind: u8,
    payload: Vec<u8>,
    stream: UnixStream,
    registry: Arc<Registry>,
) -> anyhow::Result<()> {
    match kind {
        protocol::kind::SPAWN => {
            let request: SpawnRequest = protocol::from_json(&payload)?;
            eprintln!(
                "gotyd: SPAWN pane={} env={} no_echo={} ring={:?}",
                request.pane_id,
                request.env.len(),
                request.no_echo,
                request.ring_bytes
            );
            if registry.get(&request.pane_id).is_some() {
                return write_error(&stream, format!("pane {} already exists", request.pane_id));
            }
            let pane = match Pane::spawn(request) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("gotyd: SPAWN FAILED: {e:#}");
                    return Err(e);
                }
            };
            eprintln!("gotyd: SPAWNED pane={}", pane.id);
            registry.insert(pane.clone()).map_err(anyhow::Error::msg)?;
            protocol::write_frame(&stream, protocol::kind::SPAWNED, pane.id.as_bytes())?;
            stream_pane(stream, pane)
        }
        protocol::kind::ATTACH => {
            let request: AttachRequest = protocol::from_json(&payload)?;
            let Some(pane) = registry.get(&request.pane_id) else {
                return write_error(&stream, format!("no such pane {}", request.pane_id));
            };
            stream_pane(stream, pane)
        }
        protocol::kind::KILL => {
            let id = String::from_utf8(payload)?;
            if let Some(pane) = registry.remove(&id) {
                pane.kill();
            }
            Ok(())
        }
        protocol::kind::LIST => {
            let payload = protocol::json(&registry.list())?;
            protocol::write_frame(&stream, protocol::kind::PANE_LIST, &payload)?;
            Ok(())
        }
        protocol::kind::SESSION_LIST => {
            let request: protocol::SessionListRequest = protocol::from_json(&payload)?;
            let sessions = match request.store.as_deref().unwrap_or("omp") {
                "claude" => list_claude_sessions(&request.cwd),
                "pi" => list_pi_sessions(&request.cwd),
                _ => list_omp_sessions(&request.cwd),
            };
            let reply = protocol::SessionListReply { sessions };
            let payload = protocol::json(&reply)?;
            protocol::write_frame(&stream, protocol::kind::SESSION_LIST_REPLY, &payload)
                .map_err(anyhow::Error::from)
        }
        protocol::kind::SESSION_FILE => {
            let request: protocol::SessionFileRequest = protocol::from_json(&payload)?;
            let store = request.store.as_deref().unwrap_or("omp").to_string();
            match read_store_file(&store, &request.session_id) {
                Ok(bytes) => {
                    protocol::write_frame(&stream, protocol::kind::SESSION_FILE_REPLY, &bytes)
                        .map_err(anyhow::Error::from)
                }
                Err(e) => write_error(&stream, format!("session file: {e}")),
            }
        }

        protocol::kind::SESSION_FORK => {
            let request: protocol::SessionForkRequest = protocol::from_json(&payload)?;
            match fork_omp_session(&request.session_id, &request.entry_id) {
                Ok(id) => {
                    let payload = protocol::json(&serde_json::json!({ "id": id }))?;
                    protocol::write_frame(&stream, protocol::kind::SESSION_FORK_REPLY, &payload)
                        .map_err(anyhow::Error::from)
                }
                Err(e) => write_error(&stream, format!("session fork: {e}")),
            }
        }
        protocol::kind::VERSION => {
            // Decimal ASCII, exactly how capability 1 daemons answered —
            // one parse rule on the client for every build.
            protocol::write_frame(
                &stream,
                protocol::kind::VERSION_REPLY,
                protocol::CAPABILITY.to_string().as_bytes(),
            )
            .map_err(anyhow::Error::from)
        }
        _ => {
            eprintln!("gotyd: INVALID first frame kind={kind}");
            write_error(&stream, "invalid first frame".to_string())
        }
    }
}

/// Capability 9: offline prefix fork — a pure file operation mirroring
/// the GUI's local fast path. 256-byte title slot + fresh v3 session
/// header + verbatim source entries through the target entry's turn.
fn fork_omp_session(session_id: &str, entry_id: &str) -> anyhow::Result<String> {
    let source = find_suffixed_file(".omp/agent/sessions", session_id)?;
    let raw = std::fs::read_to_string(&source)?;
    let lines: Vec<&str> = raw.lines().filter(|l| !l.is_empty()).collect();
    anyhow::ensure!(lines.len() > 2, "source too short");
    let field = |line: &str, key: &str| -> Option<String> {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        match key {
            "role" => value
                .get("message")
                .and_then(|m| m.get("role"))
                .and_then(|r| r.as_str())
                .map(String::from),
            _ => value.get(key).and_then(|v| v.as_str()).map(String::from),
        }
    };
    let target = lines
        .iter()
        .position(|l| field(l, "id").as_deref() == Some(entry_id))
        .ok_or_else(|| anyhow::anyhow!("entry {entry_id} not found"))?;
    // A USER cut extends through its turn (until the next user entry)
    // so the fork keeps the reply.
    let mut cut = target;
    if field(lines[target], "role").as_deref() == Some("user") {
        cut = lines[target + 1..]
            .iter()
            .position(|l| field(l, "role").as_deref() == Some("user"))
            .map(|i| target + i)
            .unwrap_or(lines.len() - 1);
    }
    // uuidv7 (timestamp ms + version/variant bits + randomness)
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_millis() as u64;
    let mut bytes = [0u8; 16];
    for (i, b) in bytes.iter_mut().enumerate().take(6) {
        *b = (ms >> (8 * (5 - i))) as u8;
    }
    for b in &mut bytes[6..] {
        *b = rand_byte();
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x70;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    let new_id = uuid_hex(&bytes);
    // omp timestamps: header uses colons, filename uses dashes.
    let (y, mo, d, h, mi, s, mls) = epoch_parts((ms / 1000) as i64, (ms % 1000) as u32);
    let header_time = format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{mls:03}Z");
    let file_time = format!("{y:04}-{mo:02}-{d:02}T{h:02}-{mi:02}-{s:02}-{mls:03}Z");
    let mut slot = format!(
        "{{\"type\":\"title\",\"v\":1,\"title\":\"\",\"updatedAt\":\"{header_time}\",\"pad\":\"\"}}"
    );
    if slot.len() < 255 {
        let pad = " ".repeat(255 - slot.len());
        slot = format!("{}{}\"}}", &slot[..slot.len() - 2], pad);
    }
    let source_cwd = field(lines[1], "cwd").unwrap_or_default();
    let header = format!(
        "{{\"type\":\"session\",\"version\":3,\"id\":\"{new_id}\",\"timestamp\":\"{header_time}\",\"cwd\":\"{source_cwd}\"}}"
    );
    let mut out = String::with_capacity(raw.len() / 2);
    out.push_str(&slot);
    out.push('\n');
    out.push_str(&header);
    out.push('\n');
    for line in &lines[2..=cut] {
        out.push_str(line);
        out.push('\n');
    }
    let dest = source.with_file_name(format!("{file_time}_{new_id}.jsonl"));
    std::fs::write(&dest, out)?;
    Ok(new_id)
}

fn rand_byte() -> u8 {
    use std::cell::Cell;
    thread_local!(static STATE: Cell<u64> = const { Cell::new(0) });
    STATE.with(|s| {
        let mut x = s.get();
        if x == 0 {
            x = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0x9E3779B97F4A7C15)
                | 1;
        }
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        s.set(x);
        (x.wrapping_mul(0x2545F4914F6CDD1D) >> 56) as u8
    })
}

fn uuid_hex(b: &[u8; 16]) -> String {
    b.iter()
        .map(|x| format!("{x:02x}"))
        .collect::<Vec<_>>()
        .join("")
}

/// UTC calendar parts from epoch seconds (no chrono dep).
fn epoch_parts(secs: i64, millis: u32) -> (i64, u32, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, mi, s) = (
        (rem / 3600) as u32,
        ((rem % 3600) / 60) as u32,
        (rem % 60) as u32,
    );
    // civil-from-days (Howard Hinnant's algorithm)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d, h, mi, s, millis)
}

/// ~/.omp/agent/sessions on THIS machine — the store the omp processes
/// spawned by this daemon write to. Same layout the GUI's local reader
/// expects: <cwd-dir>/<timestamp>_<sessionId>.jsonl, one JSON object
/// per line, head lines carrying the title and the session cwd.
fn omp_sessions_root() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".omp/agent/sessions"))
}

/// Capability 7 store listing: mirror of the GUI's local parser —
/// filename suffix = session id, first lines = title + session cwd,
/// newest first, filtered by cwd prefix when the caller passes one.
fn list_omp_sessions(cwd_filter: &Option<String>) -> Vec<protocol::SessionSummaryRow> {
    let Some(root) = omp_sessions_root() else {
        return Vec::new();
    };
    let dir_entries = |dir: &Path| {
        std::fs::read_dir(dir)
            .map(|entries| entries.flatten().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    let mut rows = Vec::new();
    for cwd_dir in dir_entries(&root) {
        let cwd_path = cwd_dir.path();
        if !cwd_path.is_dir() {
            continue;
        }
        for file in dir_entries(&cwd_path) {
            let path = file.path();
            if path.extension().is_none_or(|ext| ext != "jsonl") {
                continue;
            }
            let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let Some((_, id)) = name.rsplit_once('_') else {
                continue;
            };
            // uuidv7-shaped ids (omp's) — skip strays like "export".
            if id.len() < 30 || !id.contains('-') {
                continue;
            }
            let Ok(head) = std::fs::File::open(&path).and_then(|mut file| {
                use std::io::Read;
                let mut head = vec![0u8; 4096];
                let read = file.read(&mut head)?;
                head.truncate(read);
                Ok(head)
            }) else {
                continue;
            };
            let head = String::from_utf8_lossy(&head);
            let mut session_cwd: Option<String> = None;
            let mut title: Option<String> = None;
            for line in head.lines().take(6) {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                    continue;
                };
                match value.get("type").and_then(|t| t.as_str()) {
                    Some("session") => {
                        session_cwd = value.get("cwd").and_then(|c| c.as_str()).map(String::from);
                    }
                    Some("title") if title.is_none() => {
                        title = value
                            .get("title")
                            .and_then(|t| t.as_str())
                            .filter(|t| !t.is_empty())
                            .map(String::from);
                    }
                    _ => {}
                }
            }
            if let (Some(filter), Some(session_cwd)) = (cwd_filter, &session_cwd)
                && !session_cwd.starts_with(filter.as_str())
            {
                continue;
            }
            let mtime_ms = file
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_millis() as u64)
                .unwrap_or(0);
            rows.push(protocol::SessionSummaryRow {
                id: id.to_string(),
                cwd: session_cwd,
                title,
                mtime_ms,
                path: path.to_string_lossy().into_owned(),
            });
        }
    }
    rows.sort_by_key(|row| std::cmp::Reverse(row.mtime_ms));
    rows
}

/// Shared plumbing for store listings: walk <root>/<dir>/*.jsonl,
/// read a bounded head, let the per-store closure extract the row.
fn list_store(
    store_root: &str,
    head_bytes: usize,
    cwd_filter: &Option<String>,
    extract: impl Fn(&str, &Path) -> Option<(String, Option<String>, Option<String>)>,
) -> Vec<protocol::SessionSummaryRow> {
    let Ok(root) = store_root_path(store_root) else {
        return Vec::new();
    };
    let dir_entries = |dir: &Path| {
        std::fs::read_dir(dir)
            .map(|entries| entries.flatten().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    let mut rows = Vec::new();
    for dir in dir_entries(&root) {
        let dir_path = dir.path();
        if !dir_path.is_dir() {
            continue;
        }
        for file in dir_entries(&dir_path) {
            let path = file.path();
            if path.extension().is_none_or(|ext| ext != "jsonl") {
                continue;
            }
            let Ok(head) = std::fs::File::open(&path).and_then(|mut handle| {
                use std::io::Read;
                let mut head = vec![0u8; head_bytes];
                let read = handle.read(&mut head)?;
                head.truncate(read);
                Ok(head)
            }) else {
                continue;
            };
            let head = String::from_utf8_lossy(&head);
            let Some((id, cwd, title)) = extract(&head, &path) else {
                continue;
            };
            if let (Some(filter), Some(session_cwd)) = (cwd_filter, &cwd)
                && !session_cwd.starts_with(filter.as_str())
            {
                continue;
            }
            let mtime_ms = file
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_millis() as u64)
                .unwrap_or(0);
            rows.push(protocol::SessionSummaryRow {
                id,
                cwd,
                title,
                mtime_ms,
                path: path.to_string_lossy().into_owned(),
            });
        }
    }
    rows.sort_by_key(|row| std::cmp::Reverse(row.mtime_ms));
    rows
}

/// claude: `~/.claude/projects/<dir>/<sessionId>.jsonl`. The id rides
/// every frame (sessionId) or the system/init record (session_id);
/// no title in the listing (parity with the GUI's local reader).
fn list_claude_sessions(cwd_filter: &Option<String>) -> Vec<protocol::SessionSummaryRow> {
    list_store(".claude/projects", 8192, cwd_filter, |head, path| {
        let mut id: Option<String> = None;
        let mut cwd: Option<String> = None;
        for (scanned, line) in head.lines().take(20).enumerate() {
            let _ = scanned;
            let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            if id.is_none() {
                id = value
                    .get("sessionId")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                if id.is_none()
                    && value.get("type").and_then(|t| t.as_str()) == Some("system")
                    && value.get("subtype").and_then(|s| s.as_str()) == Some("init")
                {
                    id = value
                        .get("session_id")
                        .and_then(|v| v.as_str())
                        .map(String::from);
                }
            }
            if cwd.is_none() {
                cwd = value.get("cwd").and_then(|v| v.as_str()).map(String::from);
            }
            if id.is_some() && cwd.is_some() {
                break;
            }
        }
        let id = id.or_else(|| path.file_stem().and_then(|s| s.to_str()).map(String::from))?;
        Some((id, cwd, None))
    })
}

/// pi: `~/.pi/agent/sessions/<dir>/<timestamp>_<uuid>.jsonl`. The
/// session record carries id/cwd/name; a missing name falls back to
/// the first user message (the title users recognize).
fn list_pi_sessions(cwd_filter: &Option<String>) -> Vec<protocol::SessionSummaryRow> {
    list_store(".pi/agent/sessions", 16384, cwd_filter, |head, path| {
        let mut id: Option<String> = None;
        let mut cwd: Option<String> = None;
        let mut title: Option<String> = None;
        for line in head.lines() {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            match value.get("type").and_then(|t| t.as_str()) {
                Some("session") => {
                    id = id.or_else(|| value.get("id").and_then(|v| v.as_str()).map(String::from));
                    cwd =
                        cwd.or_else(|| value.get("cwd").and_then(|v| v.as_str()).map(String::from));
                    title = title.or_else(|| {
                        value
                            .get("name")
                            .and_then(|v| v.as_str())
                            .filter(|n| !n.is_empty())
                            .map(String::from)
                    });
                }
                Some("message") => {
                    if title.is_none()
                        && value.get("message").and_then(|m| m.get("role"))
                            == Some(&serde_json::Value::String("user".into()))
                        && let Some(text) = value
                            .get("message")
                            .and_then(|m| m.get("content"))
                            .and_then(|c| c.as_array())
                            .and_then(|blocks| blocks.first())
                            .and_then(|block| block.get("text"))
                            .and_then(|t| t.as_str())
                            .filter(|t| !t.is_empty())
                    {
                        title = Some(text.chars().take(80).collect());
                    }
                }
                _ => {}
            }
        }
        let id = id.or_else(|| {
            path.file_stem()
                .and_then(|s| s.to_str())
                .and_then(|stem| stem.rsplit_once('_').map(|(_, id)| id.to_string()))
        })?;
        Some((id, cwd, title))
    })
}

/// Capability 7-8: one store file's bytes, located per store layout.
fn read_store_file(store: &str, session_id: &str) -> anyhow::Result<Vec<u8>> {
    let path = match store {
        "claude" => find_claude_file(session_id)?,
        "pi" => find_suffixed_file(".pi/agent/sessions", session_id)?,
        _ => find_suffixed_file(".omp/agent/sessions", session_id)?,
    };
    let bytes = std::fs::read(&path)?;
    anyhow::ensure!(
        bytes.len() <= protocol::MAX_FRAME,
        "{} exceeds the frame cap",
        path.display()
    );
    Ok(bytes)
}

/// `<timestamp>_<sessionId>.jsonl` located by suffix across all cwd
/// dirs (omp + pi layout — the timestamp prefix is not derivable).
fn find_suffixed_file(store_root: &str, session_id: &str) -> anyhow::Result<PathBuf> {
    let root = store_root_path(store_root)?;
    let suffix = format!("_{session_id}.jsonl");
    let dir_entries = |dir: &Path| {
        std::fs::read_dir(dir)
            .map(|entries| entries.flatten().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    for cwd_dir in dir_entries(&root) {
        let cwd_path = cwd_dir.path();
        if !cwd_path.is_dir() {
            continue;
        }
        for file in dir_entries(&cwd_path) {
            let path = file.path();
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.ends_with(&suffix))
            {
                return Ok(path);
            }
        }
    }
    anyhow::bail!("no store file for {session_id}")
}

/// claude names files `<sessionId>.jsonl`; fall back to a head scan
/// for builds that name differently but carry the id in the frames.
fn find_claude_file(session_id: &str) -> anyhow::Result<PathBuf> {
    let root = store_root_path(".claude/projects")?;
    let dir_entries = |dir: &Path| {
        std::fs::read_dir(dir)
            .map(|entries| entries.flatten().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    let exact = format!("{session_id}.jsonl");
    for dir in dir_entries(&root) {
        let dir_path = dir.path();
        if !dir_path.is_dir() {
            continue;
        }
        for file in dir_entries(&dir_path) {
            let path = file.path();
            if path.file_name().and_then(|n| n.to_str()) == Some(exact.as_str()) {
                return Ok(path);
            }
        }
    }
    anyhow::bail!("no store file for {session_id}")
}

fn store_root_path(relative: &str) -> anyhow::Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("no HOME"))?;
    Ok(PathBuf::from(home).join(relative))
}

fn stream_pane(stream: UnixStream, pane: Arc<Pane>) -> anyhow::Result<()> {
    const QUEUE_FRAMES: usize = 512;
    let (sender, receiver) = mpsc::sync_channel::<OutFrame>(QUEUE_FRAMES);
    let Some(epoch) = pane.attach(sender) else {
        return write_error(&stream, "failed to attach pane".to_string());
    };
    let writer_stream = stream.try_clone()?;
    let writer = std::thread::Builder::new()
        .name(format!("goty-pane-writer-{}", pane.id))
        .spawn(move || write_output(writer_stream, receiver))?;

    let mut reader = stream;
    loop {
        match protocol::read_frame(&mut reader) {
            Ok((protocol::kind::INPUT, bytes)) => pane.input(&bytes),
            Ok((protocol::kind::RESIZE, payload)) => {
                if let Ok(size) = protocol::decode_size(&payload) {
                    pane.resize(size);
                }
            }
            Ok((protocol::kind::DETACH, _)) => break,
            Ok((protocol::kind::KILL, _)) => {
                pane.kill();
                break;
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    pane.detach(epoch);
    let _ = reader.shutdown(std::net::Shutdown::Both);
    let _ = writer.join();
    Ok(())
}

fn write_output(mut stream: UnixStream, receiver: mpsc::Receiver<OutFrame>) {
    while let Ok(frame) = receiver.recv() {
        if protocol::write_frame(&mut stream, frame.kind, &frame.payload).is_err() {
            break;
        }
    }
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

fn write_error(mut stream: &UnixStream, message: String) -> anyhow::Result<()> {
    protocol::write_frame(&mut stream, protocol::kind::ERROR, message.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_round_trip_preserves_binary_output() -> anyhow::Result<()> {
        let payload: Vec<u8> = (0..=255u8).chain([0x1b, 0x5b, 0x00, 0xff]).collect();
        let expected = payload.clone();
        let (mut left, mut right) = UnixStream::pair()?;

        let writer = std::thread::spawn(move || {
            protocol::write_frame(&mut left, protocol::kind::OUTPUT, &payload)
        });
        let (kind, got) = protocol::read_frame(&mut right)?;
        assert_eq!(kind, protocol::kind::OUTPUT);
        writer
            .join()
            .map_err(|_| anyhow::anyhow!("writer panicked"))??;
        assert_eq!(got, expected);
        Ok(())
    }

    #[test]
    fn version_reply_carries_the_capability_level() -> anyhow::Result<()> {
        // The client's ONLY way to detect a stale daemon instance
        // (singleton + fixed socket = an old build can serve forever):
        // the reply must carry the current CAPABILITY, not a constant.
        let (client, mut server) = UnixStream::pair()?;
        dispatch(
            protocol::kind::VERSION,
            Vec::new(),
            client,
            Arc::new(Registry::default()),
        )?;
        let (kind, payload) = protocol::read_frame(&mut server)?;
        assert_eq!(kind, protocol::kind::VERSION_REPLY);
        assert_eq!(payload, protocol::CAPABILITY.to_string().as_bytes());
        // Compile-time guard: this build must not regress below the
        // capability the GUI's expectedCapability demands.
        const _: () = assert!(protocol::CAPABILITY >= 2);
        Ok(())
    }

    #[test]
    fn private_socket_replaces_a_stale_path() -> anyhow::Result<()> {
        let dir = std::env::temp_dir().join(format!("goty-sessiond-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        let path = dir.join("daemon.sock");
        std::fs::File::create(&path).and_then(|mut file| file.write_all(b"stale"))?;
        let listener = bind_singleton(&path)?;
        drop(listener);
        let _ = std::fs::remove_dir_all(&dir);
        Ok(())
    }

    #[test]
    fn report_parsing_keeps_state_and_jobs() {
        let value: serde_json::Value = serde_json::json!({
            "pane": "p1", "state": "working", "seq": 42,
            "jobs": [{"id": "bg_2", "type": "bash", "status": "running",
                      "label": "cd /tmp", "startTime": 1756600000000i64}]
        });
        let report = parse_report(&value);
        assert_eq!(report.state, "working");
        assert_eq!(report.seq, 42);
        assert_eq!(report.jobs.len(), 1);
        assert_eq!(report.jobs[0].id, "bg_2");
        assert_eq!(report.jobs[0].kind, "bash");
        assert_eq!(report.jobs[0].status, "running");
        assert_eq!(report.jobs[0].label, "cd /tmp");
        assert_eq!(report.jobs[0].start_time, 1_756_600_000_000);
    }

    #[test]
    fn report_without_jobs_still_lands() {
        let value: serde_json::Value = serde_json::json!({"pane": "p1", "state": "idle", "seq": 7});
        let report = parse_report(&value);
        assert_eq!(report.state, "idle");
        assert!(report.jobs.is_empty());
    }

    #[test]
    fn report_with_malformed_jobs_keeps_the_state() {
        let value: serde_json::Value = serde_json::json!({
            "pane": "p1", "state": "blocked", "seq": 9,
            "jobs": [{"id": 3}]
        });
        let report = parse_report(&value);
        assert_eq!(report.state, "blocked");
        assert!(report.jobs.is_empty());
    }
}
