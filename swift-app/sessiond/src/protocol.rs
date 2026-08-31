use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

pub const MAX_FRAME: usize = 16 * 1024 * 1024;

/// Capability level the VERSION reply carries. Bump when the wire GAINS
/// meaning the client depends on; clients must treat a lower level as a
/// degraded daemon, never as an equal. History:
///
/// - 1 = spawn/attach/list with cwd
/// - 2 = PaneInfo.fg + PaneInfo.agent + the extension report server +
///   GOTY_GUI_* env injection on spawn
/// - 4 = SpawnRequest.no_echo + ring_bytes
/// - 5 = SpawnRequest.ring_input — the reattach replay carries the
///   user's own prompt requests, which the client depends on to rebuild
///   the user's side of a recovered conversation. An older daemon
///   silently omits them (2026-08-31: recovered transcripts lost the
///   user's "继续" and the composer could not tell working from idle).
///
/// Daemons are singleton and detached (sessions outlive the GUI), so a
/// host can keep serving an old build indefinitely — this is the only
/// way the client can tell (2026-08-24: remote workspaces silently
/// lost agent logo/status to exactly this).
pub const CAPABILITY: u8 = 5;

pub mod kind {
    pub const SPAWN: u8 = 1;
    pub const ATTACH: u8 = 2;
    pub const INPUT: u8 = 3;
    pub const RESIZE: u8 = 4;
    pub const DETACH: u8 = 5;
    pub const KILL: u8 = 6;
    pub const LIST: u8 = 7;
    pub const VERSION: u8 = 8;

    pub const SPAWNED: u8 = 0x81;
    pub const SIZE: u8 = 0x82;
    pub const SNAPSHOT: u8 = 0x83;
    pub const OUTPUT: u8 = 0x84;
    pub const EXITED: u8 = 0x85;
    pub const PANE_LIST: u8 = 0x86;
    pub const VERSION_REPLY: u8 = 0x87;
    pub const ATTACHED: u8 = 0x88;
    pub const ERROR: u8 = 0xff;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WinSize {
    pub cols: u16,
    pub rows: u16,
    pub cell_w: u16,
    pub cell_h: u16,
}

impl WinSize {
    pub fn sane(self) -> Self {
        Self {
            cols: self.cols.max(1),
            rows: self.rows.max(1),
            cell_w: self.cell_w.max(1),
            cell_h: self.cell_h.max(1),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SpawnRequest {
    pub pane_id: String,
    pub cwd: Option<String>,
    pub shell: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub size: WinSize,
    pub replay: bool,
    /// Agent sessions: run the command under `sh -c 'stty -echo; exec …'`
    /// — agent CLIs do not manage termios, and PTY echo would corrupt the
    /// ndjson stream. Requires CAPABILITY 4.
    #[serde(default)]
    pub no_echo: bool,
    /// Replay-ring capacity override in bytes (agent sessions: 64 MiB so
    /// long transcripts survive attach); None = RING_CAP. Requires
    /// CAPABILITY 4.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ring_bytes: Option<u64>,
    /// Ring the pane's INPUT wire too (agent panes): the reattach replay
    /// then carries the user's own prompt requests interleaved with the
    /// output in true chronological order — the rebuilt transcript keeps
    /// the user's side of the conversation. Terminal panes never set it
    /// (their input echoes back through the PTY anyway).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ring_input: bool,
    /// Bytes written to the PTY master IMMEDIATELY after exec — before
    /// the child's first read. Some agent runtimes (omp's Bun) only
    /// process stdin buffered at boot; post-startup writes are never
    /// surfaced by their event loop, so handshake commands must ride
    /// this pre-write to reach the boot buffer (2026-08-31).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prewrite: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AttachRequest {
    pub pane_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PaneInfo {
    pub pane_id: String,
    pub alive: bool,
    pub cwd: Option<String>,
    /// argv0-derived foreground command (agent detection); absent on
    /// older daemons and unknown foregrounds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fg: Option<String>,
    /// Live agent TUI state ("working"/"blocked"/"idle"), reported over
    /// this daemon's socket by the omp/pi extension; absent = nothing
    /// reported (older daemons, non-agent panes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

pub fn write_frame(mut writer: impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    writer.write_all(&(payload.len() as u32).to_le_bytes())?;
    writer.write_all(&[kind])?;
    writer.write_all(payload)?;
    writer.flush()
}

pub fn read_frame(mut reader: impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut len = [0; 4];
    reader.read_exact(&mut len)?;
    let len = u32::from_le_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut kind = [0];
    reader.read_exact(&mut kind)?;
    let mut payload = vec![0; len];
    reader.read_exact(&mut payload)?;
    Ok((kind[0], payload))
}

pub fn encode_size(size: WinSize) -> [u8; 8] {
    let mut out = [0; 8];
    out[0..2].copy_from_slice(&size.cols.to_le_bytes());
    out[2..4].copy_from_slice(&size.rows.to_le_bytes());
    out[4..6].copy_from_slice(&size.cell_w.to_le_bytes());
    out[6..8].copy_from_slice(&size.cell_h.to_le_bytes());
    out
}

pub fn decode_size(payload: &[u8]) -> io::Result<WinSize> {
    if payload.len() != 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid size frame",
        ));
    }
    Ok(WinSize {
        cols: u16::from_le_bytes([payload[0], payload[1]]),
        rows: u16::from_le_bytes([payload[2], payload[3]]),
        cell_w: u16::from_le_bytes([payload[4], payload[5]]),
        cell_h: u16::from_le_bytes([payload[6], payload[7]]),
    }
    .sane())
}

pub fn json<T: Serialize>(value: &T) -> io::Result<Vec<u8>> {
    serde_json::to_vec(value).map_err(io::Error::other)
}

pub fn from_json<T: for<'a> Deserialize<'a>>(payload: &[u8]) -> io::Result<T> {
    serde_json::from_slice(payload).map_err(io::Error::other)
}
