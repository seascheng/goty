use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// mini4 = mini3 + the daemon's REAL per-chunk data structures:
/// VecDeque ring with per-byte extend, and the bracketed-paste tracker
/// with its carry.clone() + full-chunk copy + scan. Plus holding the
/// state lock ACROSS the channel send, like the daemon does.
fn main() -> anyhow::Result<()> {
    let pty_system = NativePtySystem::default();
    let pair = pty_system.openpty(PtySize {
        rows: 50,
        cols: 200,
        pixel_width: 8,
        pixel_height: 16,
    })?;
    let mut cmd = CommandBuilder::new("/bin/sh");
    cmd.arg("-c");
    cmd.arg("stty raw -echo 2>/dev/null; exec '/bin/zsh'");
    cmd.env_clear();
    cmd.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.cwd("/tmp");
    let _child = pair.slave.spawn_command(cmd)?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader()?;
    let mut writer = pair.master.take_writer()?;

    let (client, server) = std::os::unix::net::UnixStream::pair()?;
    let _consumer = std::thread::spawn(move || {
        let mut client = client;
        let mut sink = [0u8; 64 * 1024];
        loop {
            match std::io::Read::read(&mut client, &mut sink) {
                Ok(0) | Err(_) => break,
                Ok(_) => continue,
            }
        }
    });
    let (sender, receiver) = sync_channel::<Vec<u8>>(512);
    let writer_thread = std::thread::spawn(move || {
        let mut server = server;
        while let Ok(payload) = receiver.recv() {
            let len = (payload.len() as u32).to_le_bytes();
            if server.write_all(&len).is_err()
                || server.write_all(&[0x84u8]).is_err()
                || server.write_all(&payload).is_err()
            {
                break;
            }
        }
    });

    std::thread::sleep(std::time::Duration::from_millis(600));
    let mut scratch = [0u8; 64 * 1024];
    let _ = reader.read(&mut scratch);

    writer.write_all(b"ls /tmp/manyfiles; echo DONE_$((41+1))\n")?;

    // daemon-shaped state: VecDeque ring + carry-based tracker, one lock
    struct State {
        ring: VecDeque<u8>,
        carry: Vec<u8>,
    }
    let state = Arc::new(Mutex::new(State {
        ring: VecDeque::new(),
        carry: Vec::new(),
    }));
    let t0 = Instant::now();
    let mut total = 0usize;
    let mut chunks = 0usize;
    loop {
        let n = reader.read(&mut scratch)?;
        if n == 0 {
            break;
        }
        let bytes = &scratch[..n];
        {
            let Ok(mut s) = state.lock() else { break };
            s.ring.extend(bytes.iter().copied()); // per-byte extend
            let mut buf = s.carry.clone(); // carry clone
            buf.extend_from_slice(bytes); // full chunk copy
            let _ = buf.windows(6).any(|w| w == b"\x1b[200~"); // scan stand-in
            s.carry = bytes.iter().rev().take(5).rev().copied().collect();
            if sender.send(bytes.to_vec()).is_err() {
                break;
            } // send UNDER the lock
        }
        total += n;
        chunks += 1;
        if bytes.windows(7).any(|w| w == b"DONE_42") {
            break;
        }
        if t0.elapsed().as_secs() > 30 {
            break;
        }
    }
    drop(sender);
    let secs = t0.elapsed().as_secs_f32();
    let _ = writer_thread.join();
    println!(
        "ptybench-mini4 bytes={} chunks={} avg={}B secs={:.2} mib_s={:.2}",
        total,
        chunks,
        total / chunks.max(1),
        secs,
        total as f32 / 1048576.0 / secs.max(0.001)
    );
    Ok(())
}
