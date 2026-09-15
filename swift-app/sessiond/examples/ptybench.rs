use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use std::io::{Read, Write};
use std::time::Instant;

fn main() -> anyhow::Result<()> {
    let pty_system = NativePtySystem::default();
    let pair = pty_system.openpty(PtySize {
        rows: 50,
        cols: 200,
        pixel_width: 8,
        pixel_height: 16,
    })?;
    let mut cmd = CommandBuilder::new("/bin/zsh");
    cmd.arg("-i");
    cmd.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    cmd.env("HOME", std::env::var("HOME").unwrap_or_default());
    let _child = pair.slave.spawn_command(cmd)?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader()?;
    let mut writer = pair.master.take_writer()?;

    // drain the prompt
    std::thread::sleep(std::time::Duration::from_millis(600));
    let mut scratch = [0u8; 64 * 1024];
    let _ = reader.read(&mut scratch);

    writer.write_all(b"stty raw -echo 2>/dev/null; ls /tmp/manyfiles; echo DONE_$((41+1))\n")?;

    let t0 = Instant::now();
    let mut total = 0usize;
    let mut chunks = 0usize;
    let mut done = false;
    while !done {
        let n = reader.read(&mut scratch)?;
        if n == 0 {
            break;
        }
        total += n;
        chunks += 1;
        if scratch[..n].windows(7).any(|w| w == b"DONE_42") {
            done = true;
        }
        if t0.elapsed().as_secs() > 30 {
            break;
        }
    }
    let secs = t0.elapsed().as_secs_f32();
    println!(
        "ptybench-rust bytes={} chunks={} avg={}B secs={:.2} mib_s={:.2}",
        total,
        chunks,
        total / chunks.max(1),
        secs,
        total as f32 / 1048576.0 / secs.max(0.001)
    );
    Ok(())
}
