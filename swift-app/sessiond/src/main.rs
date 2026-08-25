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

#[derive(Clone, Copy, PartialEq, Eq)]
struct AgentReport {
    state: &'static str,
    seq: u64,
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
                }
                info
            })
            .collect()
    }
}

fn main() -> anyhow::Result<()> {
    let socket = socket_argument()?;
    let listener = bind_singleton(&socket)?;
    let _ = SOCKET_PATH.set(socket.clone());
    // omp/pi state extension: installed wherever those agents live on
    // THIS machine (local daemon now; the remote daemon repeats this on
    // its own host when the SSH link starts it — no extra transfer).
    integration::install_extension();
    println!("READY");
    use std::io::Write as _;
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
                if len <= protocol::MAX_FRAME && (1..=8).contains(&head[4]) {
                    let _ = serve(&head, stream, registry);
                } else if head[0] == b'{' {
                    let _ = serve_report(&head, stream, &registry);
                }
            });
    }
    Ok(())
}

/// One extension report: its first 5 bytes plus the rest of one JSON
/// line, `{"pane":..,"state":..,"seq":..}\n`. Any reply closes the
/// connection (the extension only needs delivery confirmation).
fn serve_report(head: &[u8; 5], mut stream: UnixStream, registry: &Registry) -> anyhow::Result<()> {
    use std::io::BufRead;
    let mut line = head.to_vec();
    let mut reader = std::io::BufReader::new(&mut stream);
    reader.read_until(b'\n', &mut line)?;
    let end = line.iter().position(|&b| b == b'\n').unwrap_or(line.len());
    let value: serde_json::Value = serde_json::from_slice(&line[..end])?;
    let pane = value.get("pane").and_then(|v| v.as_str()).unwrap_or("");
    let state = value.get("state").and_then(|v| v.as_str()).unwrap_or("");
    let seq = value.get("seq").and_then(|v| v.as_u64()).unwrap_or(0);
    let report = AgentReport {
        state: match state {
            "working" => "working",
            "blocked" => "blocked",
            _ => "idle",
        },
        seq,
    };
    if !pane.is_empty() {
        registry.apply_report(pane, report);
    }
    let _ = stream.write_all(b"{}\n");
    Ok(())
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
            if registry.get(&request.pane_id).is_some() {
                return write_error(&stream, format!("pane {} already exists", request.pane_id));
            }
            let pane = Pane::spawn(request)?;
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
        protocol::kind::VERSION => {
            // Decimal ASCII, exactly how capability 1 daemons answered —
            // one parse rule on the client for every build.
            protocol::write_frame(
                &stream,
                protocol::kind::VERSION_REPLY,
                protocol::CAPABILITY.to_string().as_bytes(),
            )?;
            Ok(())
        }
        _ => write_error(&stream, "invalid first frame".to_string()),
    }
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
}
