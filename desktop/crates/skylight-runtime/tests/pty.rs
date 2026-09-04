use skylight_runtime::session::{LaunchRequest, Session, SessionEvent};
use std::{
    sync::{mpsc, Arc},
    time::{Duration, Instant},
};

fn shell() -> (String, Vec<String>) {
    if cfg!(windows) {
        ("cmd.exe".into(), vec!["/Q".into()])
    } else {
        ("/bin/sh".into(), vec![])
    }
}
#[test]
fn real_pty_accepts_input_resizes_and_reports_exit() {
    let directory = tempfile::tempdir().unwrap();
    let (sender, receiver) = mpsc::channel();
    let (program, arguments) = shell();
    eprintln!("Starting test PTY");
    let session = Session::spawn(
        LaunchRequest {
            program,
            arguments,
            cwd: Some(directory.path().to_path_buf()),
            columns: 80,
            rows: 24,
        },
        Arc::new(move |e| sender.send(e).map_err(|e| e.to_string())),
    )
    .unwrap();
    eprintln!("Test PTY started; requesting resize");
    session.resize(100, 32).unwrap();
    eprintln!("Resize complete; sending input");
    let command = if cfg!(windows) {
        "echo SKYLIGHT_PTY_OK>proof.txt\r\nexit 7\r\n"
    } else {
        "printf SKYLIGHT_PTY_OK > proof.txt\nexit 7\n"
    };
    session.write(command.as_bytes().to_vec()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    eprintln!("Waiting for output and exit");
    let mut through = 0;
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .expect("PTY exit deadline");
        match receiver.recv_timeout(remaining).unwrap() {
            SessionEvent::Output(bytes) => {
                through += bytes.len() as u64;
                session.acknowledge(through).unwrap();
            }
            SessionEvent::Exited(code) => {
                assert_eq!(code, Some(7));
                break;
            }
            SessionEvent::Error(_) => {}
        }
    }
    assert_eq!(
        std::fs::read_to_string(directory.path().join("proof.txt"))
            .unwrap()
            .trim(),
        "SKYLIGHT_PTY_OK"
    );
    assert!(!session.is_alive());
}
#[test]
fn invalid_directory_fails_before_starting_a_shell() {
    let (program, arguments) = shell();
    let result = Session::spawn(
        LaunchRequest {
            program,
            arguments,
            cwd: Some("relative-folder".into()),
            columns: 80,
            rows: 24,
        },
        Arc::new(|_| Ok(())),
    );
    assert!(result.is_err());
}

#[cfg(windows)]
#[test]
fn windows_batch_wrapper_preserves_a_spaced_argument() {
    let directory = tempfile::tempdir().unwrap();
    let launcher = directory.path().join("test launcher.cmd");
    std::fs::write(
        &launcher,
        "@echo off\r\necho %~1>batch-proof.txt\r\nexit /b 0\r\n",
    )
    .unwrap();
    let (sender, receiver) = mpsc::channel();
    eprintln!("Starting test PTY");
    let session = Session::spawn(
        LaunchRequest {
            program: launcher.to_string_lossy().into_owned(),
            arguments: vec!["two words".into()],
            cwd: Some(directory.path().to_path_buf()),
            columns: 80,
            rows: 24,
        },
        Arc::new(move |e| sender.send(e).map_err(|e| e.to_string())),
    )
    .unwrap();
    eprintln!("Waiting for output and exit");
    let mut through = 0;
    loop {
        match receiver.recv_timeout(Duration::from_secs(15)).unwrap() {
            SessionEvent::Output(bytes) => {
                through += bytes.len() as u64;
                session.acknowledge(through).unwrap();
            }
            SessionEvent::Exited(code) => {
                assert_eq!(code, Some(0));
                break;
            }
            SessionEvent::Error(error) => panic!("{error}"),
        }
    }
    assert_eq!(
        std::fs::read_to_string(directory.path().join("batch-proof.txt"))
            .unwrap()
            .trim(),
        "two words"
    );
}

#[cfg(unix)]
#[test]
fn output_flood_is_bounded_and_does_not_block_another_session() {
    use skylight_runtime::session::OUTPUT_WINDOW;
    let directory = tempfile::tempdir().unwrap();
    let (sender, receiver) = mpsc::channel();
    let noisy=Session::spawn(LaunchRequest{program:"/bin/sh".into(),arguments:vec!["-c".into(),"while :; do printf '012345678901234567890123456789012345678901234567890123456789\n'; done".into()],cwd:Some(directory.path().to_path_buf()),columns:80,rows:24},Arc::new(move |e| sender.send(e).map_err(|e|e.to_string()))).unwrap();
    let mut bytes = 0;
    while let Ok(event) = receiver.recv_timeout(Duration::from_millis(100)) {
        if let SessionEvent::Output(chunk) = event {
            bytes += chunk.len() as u64;
        }
    }
    assert!(bytes > 0 && bytes <= OUTPUT_WINDOW);
    // With no acknowledgements the noisy reader must stop before the next
    // frame. Another real terminal still needs to accept input and finish.
    real_pty_accepts_input_resizes_and_reports_exit();
    noisy.close();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let SessionEvent::Exited(_) = receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap()
        {
            break;
        }
    }
}

#[cfg(windows)]
#[test]
fn windows_close_reports_exit_for_a_quiet_shell() {
    let (sender, receiver) = mpsc::channel();
    let session = Session::spawn(
        LaunchRequest {
            program: "cmd.exe".into(),
            arguments: vec!["/Q".into()],
            cwd: None,
            columns: 80,
            rows: 24,
        },
        Arc::new(move |event| sender.send(event).map_err(|e| e.to_string())),
    )
    .unwrap();
    session.close();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let SessionEvent::Exited(_) = receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap()
        {
            break;
        }
    }
    assert!(!session.is_alive());
    session.close();
}

#[cfg(unix)]
#[test]
fn explicit_close_stops_a_quiet_process_that_ignores_hangup() {
    let (sender, receiver) = mpsc::channel();
    eprintln!("Starting test PTY");
    let session = Session::spawn(
        LaunchRequest {
            program: "/bin/sh".into(),
            arguments: vec!["-c".into(), "trap '' HUP; printf READY; read answer".into()],
            cwd: None,
            columns: 80,
            rows: 24,
        },
        Arc::new(move |event| sender.send(event).map_err(|e| e.to_string())),
    )
    .unwrap();
    let ready = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(matches!(ready, SessionEvent::Output(_)));
    session.close();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let SessionEvent::Exited(_) = receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap()
        {
            break;
        }
    }
    assert!(!session.is_alive());
    session.close();
}
