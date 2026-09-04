use anyhow::{anyhow, bail, Context, Result};
#[cfg(windows)]
use portable_pty::ChildKiller;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use std::{
    io::{Read, Write},
    path::PathBuf,
    sync::{
        mpsc::{self, SyncSender},
        Arc, Condvar, Mutex,
    },
    thread,
};

pub const OUTPUT_WINDOW: u64 = 128 * 1024;
pub const INPUT_CHUNK: usize = 16 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchRequest {
    pub program: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub columns: u16,
    pub rows: u16,
}

#[derive(Debug)]
pub enum SessionEvent {
    Output(Vec<u8>),
    Exited(Option<u32>),
    Error(String),
}
pub type Sink = Arc<dyn Fn(SessionEvent) -> Result<(), String> + Send + Sync>;

#[derive(Default)]
struct Counters {
    sent: u64,
    acknowledged: u64,
    closed: bool,
}
#[derive(Default)]
struct OutputBudget {
    state: Mutex<Counters>,
    changed: Condvar,
}
impl OutputBudget {
    fn reserve(&self, count: usize) -> bool {
        let mut state = self.state.lock().unwrap();
        while !state.closed && state.sent - state.acknowledged + count as u64 > OUTPUT_WINDOW {
            state = self.changed.wait(state).unwrap();
        }
        if state.closed {
            return false;
        }
        state.sent += count as u64;
        true
    }
    fn acknowledge(&self, through: u64) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        if through > state.sent {
            bail!("Acknowledgement exceeds delivered output");
        }
        // Duplicate or reordered acknowledgements cannot create extra capacity.
        state.acknowledged = state.acknowledged.max(through);
        self.changed.notify_all();
        Ok(())
    }
    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.changed.notify_all();
    }
}

// A thread-creation failure must not orphan a process that already owns a PTY.
struct ChildGuard {
    process: Box<dyn Child + Send + Sync>,
    reaped: bool,
}
impl ChildGuard {
    #[cfg(windows)]
    fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
        let status = self.process.wait()?;
        self.reaped = true;
        Ok(status)
    }
    #[cfg(unix)]
    fn try_wait(&mut self) -> std::io::Result<Option<portable_pty::ExitStatus>> {
        let result = self.process.try_wait()?;
        if result.is_some() {
            self.reaped = true;
        }
        Ok(result)
    }
}
impl Drop for ChildGuard {
    fn drop(&mut self) {
        if !self.reaped {
            let _ = self.process.kill();
            let _ = self.process.wait();
        }
    }
}

/// Owns one OS PTY. No window toolkit, web server, or provider credentials.
/// Output has a per-session window; a blocked renderer cannot build an unbounded
/// IPC queue. Input has a separate worker and bounded queue so it can interrupt
/// a producer whose output is backpressured.
pub struct Session {
    master: Arc<Mutex<Option<Box<dyn MasterPty + Send>>>>,
    #[cfg(windows)]
    killer: Arc<Mutex<Box<dyn ChildKiller + Send + Sync>>>,
    input: Arc<Mutex<Option<SyncSender<Vec<u8>>>>>,
    budget: Arc<OutputBudget>,
    ended: Arc<Mutex<bool>>,
    pub process_id: Option<u32>,
}

impl Session {
    pub fn spawn(request: LaunchRequest, sink: Sink) -> Result<Self> {
        validate_size(request.columns, request.rows)?;
        if request.program.is_empty() || request.program.contains('\0') {
            bail!("Choose an executable");
        }
        if request.arguments.iter().any(|a| a.contains('\0')) {
            bail!("Arguments contain a null byte");
        }
        if let Some(cwd) = &request.cwd {
            if !cwd.is_absolute() || !cwd.is_dir() {
                bail!("Working directory is unavailable on this computer. Choose a local folder.");
            }
        }
        let pair = native_pty_system().openpty(size(request.columns, request.rows))?;
        let mut command = build_command(&request)?;
        if let Some(cwd) = request.cwd {
            command.cwd(cwd);
        }
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        if let Some(path) = crate::catalog::search_path() {
            command.env("PATH", path);
        }
        let mut reader = pair.master.try_clone_reader()?;
        let mut writer = pair.master.take_writer()?;
        let child = pair
            .slave
            .spawn_command(command)
            .context("Could not start terminal")?;
        let mut child = ChildGuard {
            process: child,
            reaped: false,
        };
        let process_id = child.process.process_id();
        #[cfg(windows)]
        let killer = Arc::new(Mutex::new(child.process.clone_killer()));
        drop(pair.slave);
        let master = Arc::new(Mutex::new(Some(pair.master)));
        let budget = Arc::new(OutputBudget::default());
        let ended = Arc::new(Mutex::new(false));
        let (input, incoming) = mpsc::sync_channel::<Vec<u8>>(64);
        let input = Arc::new(Mutex::new(Some(input)));
        let input_sink = sink.clone();
        thread::Builder::new()
            .name("skylight-input".into())
            .spawn(move || {
                for bytes in incoming {
                    if let Err(error) = writer.write_all(&bytes).and_then(|_| writer.flush()) {
                        let _ = input_sink(SessionEvent::Error(format!(
                            "Terminal input closed: {error}"
                        )));
                        break;
                    }
                }
            })?;
        let reader_budget = budget.clone();
        #[cfg(unix)]
        let reader_ended = ended.clone();
        #[cfg(windows)]
        let reader_killer = killer.clone();
        #[cfg(windows)]
        let (exit_sender, exit_receiver) = mpsc::channel();
        let reader_input = input.clone();
        thread::Builder::new()
            .name("skylight-output".into())
            .spawn(move || {
                let mut buffer = [0u8; 16 * 1024];
                loop {
                    match reader.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(count) => {
                            if !reader_budget.reserve(count) {
                                // After cancellation keep draining without forwarding.
                                // A PTY writer blocked in the kernel may not complete
                                // shutdown until its pending bytes have been consumed.
                                continue;
                            }
                            if sink(SessionEvent::Output(buffer[..count].to_vec())).is_err() {
                                #[cfg(unix)]
                                let _ = child.process.kill();
                                #[cfg(windows)]
                                let _ = reader_killer.lock().unwrap().kill();
                                reader_budget.close();
                                continue;
                            }
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(error) => {
                            // Unix PTYs commonly signal slave closure as EIO.
                            #[cfg(unix)]
                            if error.raw_os_error() == Some(5) {
                                break;
                            }
                            let _ = sink(SessionEvent::Error(format!(
                                "Terminal output closed: {error}"
                            )));
                            break;
                        }
                    }
                }
                // Reaping and the liveness flag share a lock with close().
                // A late close can never signal a PID that has been reaped and
                // reused. This short exit-only wait does not poll live PTYs.
                #[cfg(unix)]
                let exit = loop {
                    let mut ended = reader_ended.lock().unwrap();
                    match child.try_wait() {
                        Ok(Some(status)) => {
                            *ended = true;
                            break Some(status.exit_code());
                        }
                        Err(_) => {
                            *ended = true;
                            break None;
                        }
                        Ok(None) => {}
                    }
                    drop(ended);
                    thread::sleep(std::time::Duration::from_millis(20));
                };
                #[cfg(windows)]
                let exit = exit_receiver.recv().ok().flatten();
                reader_input.lock().unwrap().take();
                reader_budget.close();
                let _ = sink(SessionEvent::Exited(exit));
            })?;
        #[cfg(windows)]
        {
            let exit_master = master.clone();
            let exit_ended = ended.clone();
            let exit_input = input.clone();
            // ConPTY retains the output pipe until its master is closed. Waiting
            // for output EOF before waiting for the process creates a cycle.
            // Wait on the process on a separate thread, then close the console
            // while the output worker continues draining its final bytes.
            thread::Builder::new()
                .name("skylight-exit".into())
                .spawn(move || {
                    let code = child.wait().ok().map(|status| status.exit_code());
                    *exit_ended.lock().unwrap() = true;
                    exit_input.lock().unwrap().take();
                    let _ = exit_sender.send(code);
                    let master = exit_master.lock().unwrap().take();
                    drop(master);
                })?;
        }
        Ok(Self {
            master,
            #[cfg(windows)]
            killer,
            input,
            budget,
            ended,
            process_id,
        })
    }
    pub fn write(&self, bytes: Vec<u8>) -> Result<()> {
        if bytes.len() > INPUT_CHUNK {
            bail!("Input chunk is too large");
        }
        let guard = self.input.lock().unwrap();
        let input = guard.as_ref().ok_or_else(|| anyhow!("Session is closed"))?;
        input
            .try_send(bytes)
            .map_err(|e| anyhow!("Terminal input is busy or closed: {e}"))
    }
    pub fn resize(&self, columns: u16, rows: u16) -> Result<()> {
        validate_size(columns, rows)?;
        self.master
            .lock()
            .unwrap()
            .as_ref()
            .ok_or_else(|| anyhow!("Session is closed"))?
            .resize(size(columns, rows))
    }
    pub fn acknowledge(&self, through: u64) -> Result<()> {
        self.budget.acknowledge(through)
    }
    pub fn is_alive(&self) -> bool {
        !*self.ended.lock().unwrap()
    }
    pub fn close(&self) {
        let ended = self.ended.lock().unwrap();
        if !*ended {
            #[cfg(unix)]
            if let Some(pid) = self.process_id {
                // This PID is still owned and unreaped while ended is locked.
                // Explicit terminal close must work even if the shell ignores HUP.
                unsafe {
                    libc::kill(pid as i32, libc::SIGKILL);
                }
            }
            #[cfg(windows)]
            {
                let _ = self.killer.lock().unwrap().kill();
            }
        }
        drop(ended);
        self.budget.close();
        self.input.lock().unwrap().take();
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.close();
    }
}
fn size(columns: u16, rows: u16) -> PtySize {
    PtySize {
        rows,
        cols: columns,
        pixel_width: 0,
        pixel_height: 0,
    }
}
fn validate_size(columns: u16, rows: u16) -> Result<()> {
    if columns == 0 || rows == 0 || columns > 1000 || rows > 1000 {
        bail!("Invalid terminal dimensions");
    }
    Ok(())
}

fn build_command(request: &LaunchRequest) -> Result<CommandBuilder> {
    #[cfg(windows)]
    if ["cmd", "bat"].contains(
        &std::path::Path::new(&request.program)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
    ) {
        use base64::Engine;
        let shell = crate::catalog::resolve("powershell.exe")
            .context("PowerShell is required for this batch launcher")?;
        let script = crate::windows_launch::batch_script(&request.program, &request.arguments)?;
        let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        let mut command = CommandBuilder::new(shell);
        command.args(["-NoLogo", "-NoProfile", "-EncodedCommand", &encoded]);
        return Ok(command);
    }
    let mut command = CommandBuilder::new(&request.program);
    command.args(&request.arguments);
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[test]
    fn output_blocks_at_window_and_resumes_after_ack() {
        let budget = Arc::new(OutputBudget::default());
        assert!(budget.reserve(OUTPUT_WINDOW as usize));
        let worker = budget.clone();
        let (send, recv) = mpsc::channel();
        let join = thread::spawn(move || {
            send.send(worker.reserve(1)).unwrap();
        });
        assert!(recv.recv_timeout(Duration::from_millis(30)).is_err());
        budget.acknowledge(1).unwrap();
        assert!(recv.recv_timeout(Duration::from_secs(2)).unwrap());
        join.join().unwrap();
    }
    #[test]
    fn close_wakes_a_blocked_renderer_and_overack_is_rejected() {
        let budget = Arc::new(OutputBudget::default());
        assert!(budget.reserve(OUTPUT_WINDOW as usize));
        assert!(budget.acknowledge(OUTPUT_WINDOW + 1).is_err());
        let worker = budget.clone();
        let join = thread::spawn(move || worker.reserve(1));
        budget.close();
        assert!(!join.join().unwrap());
    }
    #[test]
    fn reordered_ack_does_not_reduce_accounted_output() {
        let budget = OutputBudget::default();
        budget.reserve(100);
        budget.acknowledge(80).unwrap();
        budget.acknowledge(40).unwrap();
        assert_eq!(budget.state.lock().unwrap().acknowledged, 80);
    }
}
