// goty — see CLAUDE.md for the working principles.
// omp/pi state reporting: the extension asset embedded below is written
// into each agent's extension directory (only where the agent is
// installed), and every pane we spawn carries the env pair that points
// the extension at this daemon. Local and remote daemons both do this
// on their own machine — the SSH link already ships the binary, so the
// asset rides it with no separate transfer step.

use std::path::PathBuf;

pub const EXTENSION_ASSET: &str = include_str!("extension_asset.ts");
const INSTALL_NAME: &str = "goty-gui-agent-state.ts";
/// The pre-rename install left this sibling file behind; agents load
/// every file in the dir, so a leftover would double-report.
const LEGACY_INSTALL_NAME: &str = "goty-agent-state.ts";

pub const SOCKET_PATH_ENV: &str = "GOTY_GUI_SOCKET_PATH";
pub const PANE_ID_ENV: &str = "GOTY_GUI_PANE_ID";

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// pi: ~/.pi/agent/extensions (PI_CODING_AGENT_DIR overrides).
/// omp: ~/.omp/agent/extensions (PI_CODING_AGENT_DIR / PI_CONFIG_DIR
/// override). A missing directory means the agent isn't installed —
/// skipped, never created: installing agents is the user's business.
fn extension_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    match std::env::var_os("PI_CODING_AGENT_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => dirs.push(PathBuf::from(dir).join("extensions")),
        None => {
            if let Some(home) = home() {
                dirs.push(home.join(".pi").join("agent").join("extensions"));
            }
        }
    }
    let omp_base = std::env::var_os("PI_CONFIG_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home().map(|home| home.join(".omp")));
    if let Some(base) = omp_base {
        let dir = base.join("agent").join("extensions");
        if !dirs.contains(&dir) {
            dirs.push(dir);
        }
    }
    dirs
}

/// Idempotent install: writes only where the bytes differ, so repeated
/// daemon starts (and the remote restart per binary-hash upgrade) are
/// no-ops.
pub fn install_extension() {
    for dir in extension_dirs() {
        if !dir.is_dir() {
            continue;
        }
        let path = dir.join(INSTALL_NAME);
        let _ = std::fs::remove_file(dir.join(LEGACY_INSTALL_NAME));
        if std::fs::read(&path).is_ok_and(|current| current == EXTENSION_ASSET.as_bytes()) {
            continue;
        }
        if let Err(error) = std::fs::write(&path, EXTENSION_ASSET) {
            eprintln!(
                "goty-sessiond: extension install failed at {}: {error}",
                path.display()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installs_only_where_the_agent_dir_exists() -> anyhow::Result<()> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .subsec_nanos();
        let base =
            std::env::temp_dir().join(format!("goty-gui-ext-{}-{}", std::process::id(), nanos));
        let home = base.join("home");
        let pi_ext = home.join(".pi").join("agent").join("extensions");
        std::fs::create_dir_all(&pi_ext)?;
        // SAFETY: single-threaded test, no other readers of the env.
        unsafe {
            std::env::set_var("HOME", &home);
            std::env::remove_var("PI_CODING_AGENT_DIR");
            std::env::remove_var("PI_CONFIG_DIR");
        }
        install_extension();

        let installed = pi_ext.join(INSTALL_NAME);
        assert_eq!(std::fs::read(&installed)?, EXTENSION_ASSET.as_bytes());
        // omp is not installed here: its directory must NOT be created.
        assert!(!home.join(".omp").join("agent").exists());

        // Re-run is a byte-equality no-op.
        install_extension();
        assert_eq!(std::fs::read(&installed)?, EXTENSION_ASSET.as_bytes());

        // SAFETY: single-threaded test teardown.
        unsafe { std::env::remove_var("HOME") }
        let _ = std::fs::remove_dir_all(&base);
        Ok(())
    }
}
