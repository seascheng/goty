use crate::protocol::{self, WinSize};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::Serialize;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::mpsc::SyncSender;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

const RING_CAP: usize = 8 * 1024 * 1024;
const MAX_RING_SEGMENTS: usize = 64;

#[derive(Debug)]
pub struct OutFrame {
    pub kind: u8,
    pub payload: Vec<u8>,
}

impl OutFrame {
    fn new(kind: u8, payload: Vec<u8>) -> Self {
        Self { kind, payload }
    }
}

#[derive(Clone)]
struct RingSegment {
    size: WinSize,
    bytes: VecDeque<u8>,
}

impl RingSegment {
    fn empty(size: WinSize) -> Self {
        Self {
            size,
            bytes: VecDeque::new(),
        }
    }

    fn bytes(&self) -> Vec<u8> {
        let (a, b) = self.bytes.as_slices();
        let mut out = Vec::with_capacity(self.bytes.len());
        out.extend_from_slice(a);
        out.extend_from_slice(b);
        out
    }
}

struct ReplayRing {
    segments: VecDeque<RingSegment>,
    cap: usize,
    len: usize,
}

impl ReplayRing {
    fn new(size: WinSize, cap: usize) -> Self {
        Self {
            segments: VecDeque::from([RingSegment::empty(size)]),
            cap,
            len: 0,
        }
    }

    fn resize(&mut self, size: WinSize) -> bool {
        let Some(tail) = self.segments.back_mut() else {
            self.segments.push_back(RingSegment::empty(size));
            return true;
        };
        if tail.size == size {
            return false;
        }
        if tail.bytes.is_empty() {
            tail.size = size;
            return true;
        }
        if self.segments.len() >= MAX_RING_SEGMENTS
            && let Some(old) = self.segments.pop_front()
            && let Some(head) = self.segments.front_mut()
        {
            let mut merged = old.bytes;
            merged.extend(head.bytes.drain(..));
            head.bytes = merged;
        }
        self.segments.push_back(RingSegment::empty(size));
        true
    }
    fn append(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        if bytes.len() >= self.cap {
            let size = self.segments.back().map_or(
                WinSize {
                    cols: 80,
                    rows: 24,
                    cell_w: 8,
                    cell_h: 16,
                },
                |s| s.size,
            );
            self.segments.clear();
            let mut tail = RingSegment::empty(size);
            tail.bytes.extend(&bytes[bytes.len() - self.cap..]);
            self.segments.push_back(tail);
            self.len = self.cap;
            return;
        }
        if let Some(tail) = self.segments.back_mut() {
            tail.bytes.extend(bytes);
        }
        self.len += bytes.len();
        let mut overflow = self.len.saturating_sub(self.cap);
        while overflow > 0 {
            let Some(head) = self.segments.front_mut() else {
                break;
            };
            let count = overflow.min(head.bytes.len());
            head.bytes.drain(..count);
            self.len -= count;
            overflow -= count;
            if head.bytes.is_empty() && self.segments.len() > 1 {
                self.segments.pop_front();
            }
        }
    }

    fn replay(&self, sender: &SyncSender<OutFrame>) -> bool {
        for segment in &self.segments {
            if sender
                .send(OutFrame::new(
                    protocol::kind::SIZE,
                    protocol::encode_size(segment.size).to_vec(),
                ))
                .is_err()
            {
                return false;
            }
            if !segment.bytes.is_empty()
                && sender
                    .send(OutFrame::new(protocol::kind::SNAPSHOT, segment.bytes()))
                    .is_err()
            {
                return false;
            }
        }
        true
    }
}

/// Bracketed-paste (DECSET/DECRST 2004) tracker. Private modes live in
/// the terminal emulator, not the pane: after a GUI restart the fresh
/// surface loses them, and ghostty then converts pasted newlines to CR
/// (xterm behavior for unbracketed pastes). The replay ring may have
/// rotated past the program's startup sequences long ago, so the mode
/// is tracked as live state and re-sent as an output frame after replay.
/// ponytail: tracks 2004 only — extend to other private modes (1049,
/// kitty keyboard flags) if one proves stale after reattach.
const BRACKETED_PASTE_ON: &[u8] = b"\x1b[?2004h";
const BRACKETED_PASTE_OFF: &[u8] = b"\x1b[?2004l";

struct BracketedPasteTracker {
    mode: bool,
    /// Tail of the previous chunk so a sequence split across reads is
    /// still matched.
    carry: Vec<u8>,
}

impl BracketedPasteTracker {
    fn new() -> Self {
        Self {
            mode: false,
            carry: Vec::new(),
        }
    }

    fn feed(&mut self, bytes: &[u8]) {
        let mut buf = self.carry.clone();
        buf.extend_from_slice(bytes);
        // Last occurrence wins; a raw ESC cannot appear inside an
        // OSC/DCS payload (it terminates it), so a byte match here is
        // exactly what a conformant terminal parser would have seen.
        let on = buf
            .windows(BRACKETED_PASTE_ON.len())
            .rposition(|w| w == BRACKETED_PASTE_ON);
        let off = buf
            .windows(BRACKETED_PASTE_OFF.len())
            .rposition(|w| w == BRACKETED_PASTE_OFF);
        match (on, off) {
            (Some(on), Some(off)) => self.mode = on > off,
            (Some(_), None) => self.mode = true,
            (None, Some(_)) => self.mode = false,
            (None, None) => {}
        }
        let keep = buf.len().min(BRACKETED_PASTE_ON.len() - 1);
        self.carry = buf[buf.len() - keep..].to_vec();
    }
}

struct PaneState {
    ring: ReplayRing,
    bracketed_paste: BracketedPasteTracker,
    subscriber: Option<SyncSender<OutFrame>>,
    subscriber_epoch: u64,
    alive: bool,
    exit_code: Option<i32>,
}

pub struct Pane {
    pub id: String,
    replay_enabled: bool,
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    child: Mutex<Option<Box<dyn Child + Send + Sync>>>,
    writer: Mutex<Box<dyn Write + Send>>,
    state: Mutex<PaneState>,
    reader: Mutex<Option<JoinHandle<()>>>,
}

impl Pane {
    pub fn spawn(request: crate::protocol::SpawnRequest) -> anyhow::Result<Arc<Self>> {
        let size = request.size.sane();
        let pair = native_pty_system().openpty(pty_size(size))?;
        let (shell, args) = if request.no_echo {
            echo_off_wrapper(&request.shell, &request.args)
        } else {
            (request.shell.clone(), request.args.clone())
        };
        let mut command = CommandBuilder::new(&shell);
        command.args(&args);
        if let Some(cwd) = request
            .cwd
            .as_deref()
            .filter(|dir| std::path::Path::new(dir).is_dir())
        {
            command.cwd(cwd);
            command.env("PWD", cwd);
        }
        for (key, value) in &request.env {
            command.env(key, value);
        }
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        // The omp/pi state extension inside every pane we own reports
        // back to THIS daemon (see integration.rs).
        if let Some(socket) = crate::SOCKET_PATH.get() {
            command.env(crate::integration::SOCKET_PATH_ENV, socket);
            command.env(crate::integration::PANE_ID_ENV, &request.pane_id);
        }

        let child = pair.slave.spawn_command(command)?;
        drop(pair.slave);
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        let pane = Arc::new(Self {
            id: request.pane_id,
            replay_enabled: request.replay,
            master: Mutex::new(Some(pair.master)),
            child: Mutex::new(Some(child)),
            writer: Mutex::new(writer),
            state: Mutex::new(PaneState {
                ring: ReplayRing::new(
                    size,
                    request
                        .ring_bytes
                        .map(|b| (b as usize).clamp(64 * 1024, 256 * 1024 * 1024))
                        .unwrap_or(RING_CAP),
                ),
                bracketed_paste: BracketedPasteTracker::new(),
                subscriber: None,
                subscriber_epoch: 0,
                alive: true,
                exit_code: None,
            }),
            reader: Mutex::new(None),
        });
        let handle = spawn_reader(pane.clone(), reader)?;
        if let Ok(mut slot) = pane.reader.lock() {
            *slot = Some(handle);
        }
        Ok(pane)
    }

    /// Replay and subscriber installation happen under the same lock used by
    /// the PTY reader. Output is therefore either in the replay or after it;
    /// no byte can fall between the two channels.
    pub fn attach(&self, sender: SyncSender<OutFrame>) -> Option<u64> {
        let mut state = self.state.lock().ok()?;
        state.subscriber_epoch = state.subscriber_epoch.wrapping_add(1);
        let epoch = state.subscriber_epoch;
        if self.replay_enabled && !state.ring.replay(&sender) {
            return None;
        }
        // Replay restores screen content, not private modes — hand the
        // tracked bracketed-paste state to the fresh surface before the
        // attach marker so pasted newlines stay newlines.
        if state.bracketed_paste.mode
            && sender
                .send(OutFrame::new(
                    protocol::kind::OUTPUT,
                    BRACKETED_PASTE_ON.to_vec(),
                ))
                .is_err()
        {
            return None;
        }
        if sender
            .send(OutFrame::new(protocol::kind::ATTACHED, Vec::new()))
            .is_err()
        {
            return None;
        }
        if !state.alive {
            let payload = protocol::json(&ExitStatus {
                code: state.exit_code,
            })
            .ok()?;
            if sender
                .send(OutFrame::new(protocol::kind::EXITED, payload))
                .is_err()
            {
                return None;
            }
        }
        state.subscriber = Some(sender);
        Some(epoch)
    }

    pub fn detach(&self, epoch: u64) {
        if let Ok(mut state) = self.state.lock()
            && state.subscriber_epoch == epoch
        {
            state.subscriber = None;
        }
    }

    pub fn input(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        if let Ok(mut writer) = self.writer.lock() {
            let _ = writer.write_all(bytes);
            let _ = writer.flush();
        }
    }

    /// Resize only when the stream geometry changes. A duplicate request is
    /// common immediately after attach: replay already ended with the
    /// daemon's current size. Calling the PTY resize ioctl in that case
    /// emits SIGWINCH and makes full-screen applications repaint needlessly.
    pub fn resize(&self, size: WinSize) {
        let size = size.sane();
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if !state.ring.resize(size) {
            return;
        }
        let marker = OutFrame::new(protocol::kind::SIZE, protocol::encode_size(size).to_vec());
        if state
            .subscriber
            .as_ref()
            .is_some_and(|sender| sender.send(marker).is_err())
        {
            state.subscriber = None;
        }
        drop(state);
        if let Ok(master) = self.master.lock()
            && let Some(master) = master.as_ref()
        {
            let _ = master.resize(pty_size(size));
        }
    }

    pub fn info(&self) -> crate::protocol::PaneInfo {
        crate::protocol::PaneInfo {
            pane_id: self.id.clone(),
            alive: self.state.lock().map(|s| s.alive).unwrap_or(false),
            cwd: self.cwd(),
            fg: self.foreground_command(),
            agent: None,
        }
    }

    pub fn cwd(&self) -> Option<String> {
        Self::read_cwd(self.foreground_pid()?)
    }

    /// Foreground process pid: the PTY's foreground process-group leader
    /// (what the user typed last), falling back to the spawned child while
    /// no job has taken the terminal.
    fn foreground_pid(&self) -> Option<i32> {
        self.master
            .lock()
            .ok()
            .and_then(|master| {
                master
                    .as_ref()
                    .and_then(|master| master.process_group_leader())
            })
            .or_else(|| {
                self.child
                    .lock()
                    .ok()
                    .and_then(|child| child.as_ref().and_then(|child| child.process_id()))
                    .map(|pid| pid as i32)
            })
    }

    /// argv0-derived command of the pane's foreground process, unwrapping
    /// node-family launchers (normalized process name, reduced to
    /// the shapes real agent CLIs use). Native binaries (claude, omp, grok)
    /// surface directly; `#!/usr/bin/env node` scripts (codex, gemini)
    /// surface via the script path argument.
    pub fn foreground_command(&self) -> Option<String> {
        let command = unwrap_runtime_argv(&Self::read_argv(self.foreground_pid()?)?)?;
        (!command.is_empty()).then_some(command)
    }

    #[cfg(target_os = "macos")]
    fn read_argv(pid: i32) -> Option<Vec<String>> {
        if pid <= 0 {
            return None;
        }
        let mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        let mut size = 0usize;
        if unsafe {
            libc::sysctl(
                mib.as_ptr() as *mut _,
                3,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return None;
        }
        let mut buffer = vec![0u8; size];
        if unsafe {
            libc::sysctl(
                mib.as_ptr() as *mut _,
                3,
                buffer.as_mut_ptr() as *mut _,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return None;
        }
        buffer.truncate(size);
        // Layout: argc (i32), then NUL-separated strings. Some slots are
        // historically empty; collect non-empty tokens up to argc.
        if buffer.len() < 4 {
            return None;
        }
        let argc = i32::from_le_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]).clamp(1, 1024)
            as usize;
        let strings: Vec<&[u8]> = buffer[4..]
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .take(argc)
            .collect();
        Some(
            strings
                .iter()
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect(),
        )
    }

    #[cfg(not(target_os = "macos"))]
    fn read_argv(pid: i32) -> Option<Vec<String>> {
        if pid <= 0 {
            return None;
        }
        let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        Some(
            cmdline
                .split(|b| *b == 0)
                .filter(|s| !s.is_empty())
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect(),
        )
    }

    #[cfg(target_os = "macos")]
    fn read_cwd(pid: i32) -> Option<String> {
        use std::ffi::CStr;
        if pid <= 0 {
            return None;
        }
        let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
        let read = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                size,
            )
        };
        if read != size {
            return None;
        }
        let path =
            unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr() as *const libc::c_char) }
                .to_str()
                .ok()?;
        (!path.is_empty()).then(|| path.to_string())
    }

    #[cfg(not(target_os = "macos"))]
    fn read_cwd(pid: i32) -> Option<String> {
        if pid <= 0 {
            return None;
        }
        std::fs::read_link(format!("/proc/{pid}/cwd"))
            .ok()
            .and_then(|path| path.to_str().map(str::to_string))
            .filter(|path| !path.is_empty())
    }

    pub fn kill(&self) {
        if let Ok(mut child) = self.child.lock()
            && let Some(child) = child.as_mut()
        {
            if let Some(pid) = child.process_id() {
                unsafe {
                    libc::killpg(pid as libc::pid_t, libc::SIGHUP);
                }
            }
            let _ = child.kill();
        }
        if let Ok(mut master) = self.master.lock() {
            master.take();
        }
    }
}

/// Maps a foreground argv to the command the user perceives: the basename
/// of argv[0], unless that is a JS runtime — then the first following
/// non-flag argument (the script the runtime was told to run). Native
/// binaries (claude, omp, grok) surface directly; `#!/usr/bin/env node`
/// CLIs (codex, gemini) surface via the script argument.
fn unwrap_runtime_argv(argv: &[String]) -> Option<String> {
    fn basename(token: &str) -> String {
        let trimmed = token.trim_end_matches(['/', '\\']);
        let name = match trimmed.rfind(['/', '\\']) {
            Some(i) => &trimmed[i + 1..],
            None => trimmed,
        };
        name.trim_end_matches(".js")
            .trim_end_matches(".mjs")
            .to_string()
    }

    let argv0 = basename(argv.first()?);
    match argv0.as_str() {
        "node" | "nodejs" | "bun" | "deno" | "npx" => argv
            .iter()
            .skip(1)
            .find(|arg| !arg.starts_with('-'))
            .map(|arg| basename(arg))
            .filter(|name| !name.is_empty())
            .or(Some(argv0)),
        _ => Some(argv0),
    }
}
/// Agent panes need ECHO off (agent CLIs never manage termios). Rather
/// than reaching for the master fd, run the command under `sh -c`: stty
/// executes inside the pty itself, then exec replaces the shell. The
/// client's echo filter (JSONRPCChannel.recentOut) tolerates the µs window
/// before stty lands.
fn echo_off_wrapper(shell: &str, args: &[String]) -> (String, Vec<String>) {
    fn quote(token: &str) -> String {
        format!("'{}'", token.replace('\'', "'\\''"))
    }
    let mut line = String::from("stty -echo 2>/dev/null; exec ");
    line.push_str(&quote(shell));
    for arg in args {
        line.push(' ');
        line.push_str(&quote(arg));
    }
    ("/bin/sh".to_string(), vec!["-c".to_string(), line])
}

impl Drop for Pane {
    fn drop(&mut self) {
        self.kill();
    }
}

#[derive(Serialize)]
struct ExitStatus {
    code: Option<i32>,
}

fn spawn_reader(
    pane: Arc<Pane>,
    mut reader: Box<dyn Read + Send>,
) -> anyhow::Result<JoinHandle<()>> {
    std::thread::Builder::new()
        .name(format!("goty-pane-{}", pane.id))
        .spawn(move || {
            let mut scratch = [0u8; 64 * 1024];
            let mut diag_bytes: usize = 0;
            let mut diag_chunks: usize = 0;
            let diag_t0 = std::time::Instant::now();
            loop {
                match reader.read(&mut scratch) {
                    Ok(0) => break,
                    Ok(count) => {
                        if std::env::var("GOTYD_REPLAY_DIAG").is_ok() {
                            diag_bytes += count;
                            diag_chunks += 1;
                            if diag_bytes / 262_144 != (diag_bytes - count) / 262_144 {
                                eprintln!(
                                    "gotyd: reader {}B in {:.3}s chunks={} ({:.2} MB/s)",
                                    diag_bytes,
                                    diag_t0.elapsed().as_secs_f32(),
                                    diag_chunks,
                                    diag_bytes as f32
                                        / 1048576.0
                                        / diag_t0.elapsed().as_secs_f32().max(0.001)
                                );
                            }
                        }
                        let bytes = &scratch[..count];
                        let Ok(mut state) = pane.state.lock() else {
                            break;
                        };
                        if pane.replay_enabled {
                            state.ring.append(bytes);
                        }
                        state.bracketed_paste.feed(bytes);
                        // Build the frame only when someone is attached —
                        // headless panes (parked servers, background
                        // sessions) would otherwise copy every chunk.
                        // Blocking send is the backpressure contract: a slow
                        // display slows the PTY reader, exactly like a real
                        // terminal. try_send dropped the subscriber forever
                        // at 512 queued frames and froze the pane silently
                        // (socket alive, no EXITED, no reconnect).
                        if let Some(sender) = state.subscriber.as_ref()
                            && sender
                                .send(OutFrame::new(protocol::kind::OUTPUT, bytes.to_vec()))
                                .is_err()
                        {
                            state.subscriber = None;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }

            let code = pane
                .child
                .lock()
                .ok()
                .and_then(|mut child| child.as_mut().and_then(|child| child.wait().ok()))
                .map(|status| status.exit_code() as i32);
            if let Ok(mut state) = pane.state.lock() {
                state.alive = false;
                state.exit_code = code;
                if let Some(sender) = &state.subscriber
                    && let Ok(payload) = protocol::json(&ExitStatus { code })
                {
                    let _ = sender.send(OutFrame::new(protocol::kind::EXITED, payload));
                }
            }
        })
        .map_err(Into::into)
}

fn pty_size(size: WinSize) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: size.cols.saturating_mul(size.cell_w),
        pixel_height: size.rows.saturating_mul(size.cell_h),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn size(cols: u16) -> WinSize {
        WinSize {
            cols,
            rows: 24,
            cell_w: 8,
            cell_h: 16,
        }
    }

    #[test]
    fn replay_preserves_geometry_boundaries() {
        let mut ring = ReplayRing::new(size(80), RING_CAP);
        ring.append(b"old");
        assert!(ring.resize(size(120)));
        ring.append(b"new");
        let (tx, rx) = mpsc::sync_channel(8);
        assert!(ring.replay(&tx));
        drop(tx);
        let frames: Vec<_> = rx.into_iter().collect();
        assert_eq!(frames.len(), 4);
        assert_eq!(
            protocol::decode_size(&frames[0].payload).ok(),
            Some(size(80))
        );
        assert_eq!(frames[1].payload, b"old");
        assert_eq!(
            protocol::decode_size(&frames[2].payload).ok(),
            Some(size(120))
        );
        assert_eq!(frames[3].payload, b"new");
    }

    #[test]
    fn duplicate_resize_is_not_a_new_geometry() {
        let mut ring = ReplayRing::new(size(80), RING_CAP);
        ring.append(b"screen");
        let before = ring.segments.len();
        assert!(!ring.resize(size(80)));
        assert_eq!(ring.segments.len(), before);
        assert_eq!(
            ring.segments.back().map(|segment| segment.size),
            Some(size(80))
        );
    }

    #[test]
    fn bracketed_paste_tracker_sets_and_clears() {
        let mut tracker = BracketedPasteTracker::new();
        tracker.feed(b"hello world");
        assert!(!tracker.mode);
        tracker.feed(b"\x1b[?2004h");
        assert!(tracker.mode);
        tracker.feed(b"\x1b[?2004l");
        assert!(!tracker.mode);
    }

    #[test]
    fn bracketed_paste_tracker_matches_across_chunk_split() {
        let mut tracker = BracketedPasteTracker::new();
        tracker.feed(b"\x1b[?20");
        assert!(!tracker.mode);
        tracker.feed(b"04h");
        assert!(tracker.mode);
    }

    #[test]
    fn bracketed_paste_tracker_last_occurrence_wins() {
        let mut tracker = BracketedPasteTracker::new();
        tracker.feed(b"junk \x1b[?2004h junk \x1b[?2004l");
        assert!(!tracker.mode);
        tracker.feed(b" \x1b[?2004h");
        assert!(tracker.mode);
    }

    #[test]
    fn ring_keeps_only_the_newest_bytes() {
        let mut ring = ReplayRing::new(size(80), RING_CAP);
        let bytes = vec![b'x'; RING_CAP + 4096];
        ring.append(&bytes);
        assert_eq!(ring.len, RING_CAP);
        assert_eq!(ring.segments.len(), 1);
        assert_eq!(ring.segments[0].bytes.len(), RING_CAP);
    }

    #[test]
    fn ring_honors_custom_capacity() {
        let mut ring = ReplayRing::new(size(80), 16);
        ring.append(b"aaaaaaaaaaaaaaaa"); // 16 bytes: exactly full
        ring.append(b"bbbb");
        assert_eq!(ring.len, 16);
        let (tx, rx) = mpsc::sync_channel(8);
        assert!(ring.replay(&tx));
        drop(tx);
        let bytes: Vec<u8> = rx
            .into_iter()
            .filter(|f: &OutFrame| f.kind == protocol::kind::SNAPSHOT)
            .flat_map(|f| f.payload)
            .collect();
        assert_eq!(bytes, b"aaaaaaaaaaaabbbb".to_vec()); // newest 16 bytes
    }

    #[test]
    fn echo_off_wrapper_quotes_arguments() {
        let (shell, args) = echo_off_wrapper("omp", &["acp".to_string()]);
        assert_eq!(shell, "/bin/sh");
        assert_eq!(args[0], "-c");
        assert_eq!(args[1], "stty -echo 2>/dev/null; exec 'omp' 'acp'");
        let (_, args) = echo_off_wrapper(
            "/usr/local/bin/claude",
            &["-r".to_string(), "it's id".to_string()],
        );
        assert!(args[1].contains(r"'it'\''s id'"));
    }

    #[test]
    fn foreground_command_unwraps_agent_launchers() {
        let argv = |parts: &[&str]| parts.iter().map(|s| s.to_string()).collect::<Vec<_>>();

        // Native binaries surface directly.
        assert_eq!(unwrap_runtime_argv(&argv(&["omp"])).as_deref(), Some("omp"));
        assert_eq!(
            unwrap_runtime_argv(&argv(&["/opt/homebrew/bin/claude", "--resume"])).as_deref(),
            Some("claude")
        );

        // `#!/usr/bin/env node` CLIs surface via the script argument.
        assert_eq!(
            unwrap_runtime_argv(&argv(&[
                "node",
                "/Users/x/.nvm/bin/codex",
                "--profile",
                "x"
            ]))
            .as_deref(),
            Some("codex")
        );
        assert_eq!(
            unwrap_runtime_argv(&argv(&["/usr/local/bin/node", "/usr/local/bin/gemini"]))
                .as_deref(),
            Some("gemini")
        );

        // Entry-point .js paths keep their stem.
        assert_eq!(
            unwrap_runtime_argv(&argv(&["node", "/pkg/dist/cli.mjs"])).as_deref(),
            Some("cli")
        );

        // Runtime flags never leak as the command; bare runtime stays itself.
        assert_eq!(
            unwrap_runtime_argv(&argv(&["node", "--max-old-space-size=4096", "/x/codex.js"]))
                .as_deref(),
            Some("codex")
        );
        assert_eq!(
            unwrap_runtime_argv(&argv(&["node"])).as_deref(),
            Some("node")
        );
        assert_eq!(
            unwrap_runtime_argv(&argv(&["zsh", "-l"])).as_deref(),
            Some("zsh")
        );
        assert_eq!(unwrap_runtime_argv(&[]), None);
    }
}
