mod support;
use exec_agent::{
    Error,
    core::*,
    storage::{ConversationStore, JsonConversationStore},
};
use std::{
    ffi::CString,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt, symlink},
    path::Path,
};
use support::{FakeProvider, conversation, directory};

const LOG: &str = "diagnostics.jsonl";
const PREVIOUS: &str = "diagnostics.previous.jsonl";
const LIMIT: usize = 1024 * 1024;

fn record() -> ConversationRecord {
    conversation(FakeProvider::new(vec![]), vec![]).record()
}
fn diagnostic(id: &str) -> SessionDiagnostic {
    SessionDiagnostic::new(
        id.into(),
        new_id(),
        Some(new_id()),
        DiagnosticEvent::ResponseFailed,
        Some(&Error::Tool(
            "private tool arguments must not be logged".into(),
        )),
    )
}
fn private_file(path: &Path, data: &[u8]) {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap();
    file.write_all(data).unwrap();
}
fn entries(path: &Path) -> Vec<SessionDiagnostic> {
    let text = fs::read_to_string(path).unwrap();
    assert!(text.ends_with('\n'));
    text.lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
fn assert_mode(path: &Path, mode: u32) {
    assert_eq!(
        fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777,
        mode
    );
}
fn fifo(path: &Path) {
    let path = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
}

#[tokio::test]
async fn private_jsonl_appends_survive_reopen_without_moving_or_mixing_transcripts() {
    let root = directory();
    let profile = root.path().join("conversations");
    let store = JsonConversationStore::open(&profile).await.unwrap();
    let a = record();
    let b = record();
    store.save(a.clone()).await.unwrap();
    store.save(b.clone()).await.unwrap();
    let transcript = profile.join(format!("{}.json", a.id));
    let before = fs::read(&transcript).unwrap();
    let folder = profile.join(&a.id);
    assert!(!folder.exists());
    let first = diagnostic(&a.id);
    let mut second = diagnostic(&a.id);
    second.message_id = None;
    second.event = DiagnosticEvent::OperationCompleted;
    let other = diagnostic(&b.id);
    store.diagnostic(first.clone()).await.unwrap();
    store.diagnostic(second.clone()).await.unwrap();
    store.diagnostic(other.clone()).await.unwrap();
    assert_mode(&folder, 0o700);
    assert_mode(&folder.join(LOG), 0o600);
    assert!(!folder.join(PREVIOUS).exists());
    assert_eq!(
        entries(&folder.join(LOG)),
        vec![first.clone(), second.clone()]
    );
    assert_eq!(entries(&profile.join(&b.id).join(LOG)), vec![other]);
    assert!(
        !fs::read_to_string(folder.join(LOG))
            .unwrap()
            .contains("private tool arguments")
    );
    assert_eq!(fs::read(&transcript).unwrap(), before);
    assert!(!folder.join(format!("{}.json", a.id)).exists());
    store.close().await.unwrap();

    let store = JsonConversationStore::open(&profile).await.unwrap();
    let third = diagnostic(&a.id);
    store.diagnostic(third.clone()).await.unwrap();
    assert_eq!(entries(&folder.join(LOG)), vec![first, second, third]);
    assert_eq!(store.load().await.unwrap().len(), 2);
    assert_eq!(fs::read(transcript).unwrap(), before);
    store.close().await.unwrap();
}

#[tokio::test]
async fn queued_diagnostics_require_a_record_and_never_resurrect_deleted_sessions() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let record = record();
    let entry = diagnostic(&record.id);
    assert!(store.diagnostic(entry.clone()).await.is_err());
    assert!(!root.path().join(&record.id).exists());
    assert!(!root.path().join(format!("{}.json", record.id)).exists());
    store.save(record.clone()).await.unwrap();
    let (before, deletion, after) = tokio::join!(
        biased;
        store.diagnostic(entry.clone()),
        store.delete(record.id.clone()),
        store.diagnostic(entry.clone()),
    );
    before.unwrap();
    deletion.unwrap();
    assert!(after.is_err());
    assert!(!root.path().join(&record.id).exists());
    assert!(!root.path().join(format!("{}.json", record.id)).exists());
    store.close().await.unwrap();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    assert!(store.diagnostic(entry).await.is_err());
    assert!(store.load().await.unwrap().is_empty());
    assert!(!root.path().join(&record.id).exists());
    store.close().await.unwrap();
}

#[tokio::test]
async fn deletion_removes_both_logs_and_only_the_selected_session_folder() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let a = record();
    let b = record();
    for record in [&a, &b] {
        store.save(record.clone()).await.unwrap();
        store.diagnostic(diagnostic(&record.id)).await.unwrap();
        let folder = root.path().join(&record.id);
        fs::copy(folder.join(LOG), folder.join(PREVIOUS)).unwrap();
    }
    let b_folder = root.path().join(&b.id);
    let retained = fs::read(b_folder.join(LOG)).unwrap();
    store.delete(a.id.clone()).await.unwrap();
    assert!(!root.path().join(&a.id).exists());
    assert!(!root.path().join(format!("{}.json", a.id)).exists());
    assert_eq!(fs::read(b_folder.join(LOG)).unwrap(), retained);
    assert_eq!(fs::read(b_folder.join(PREVIOUS)).unwrap(), retained);
    assert_eq!(store.load().await.unwrap(), vec![b]);
    store.close().await.unwrap();
}

#[tokio::test]
async fn unreadable_and_legacy_sessions_are_deletable_without_reading_the_transcript() {
    for with_diagnostics in [false, true] {
        let root = directory();
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        let record = record();
        store.save(record.clone()).await.unwrap();
        if with_diagnostics {
            store.diagnostic(diagnostic(&record.id)).await.unwrap();
        }
        let transcript = root.path().join(format!("{}.json", record.id));
        fs::write(&transcript, b"corrupt transcript").unwrap();
        assert_eq!(
            store.load_catalog().await.unwrap().unreadable,
            vec![record.id.clone()]
        );
        fs::set_permissions(&transcript, fs::Permissions::from_mode(0o000)).unwrap();
        store.delete(record.id.clone()).await.unwrap();
        assert!(!transcript.exists());
        assert!(!root.path().join(&record.id).exists());
        store.close().await.unwrap();
    }
}

#[tokio::test]
async fn rotation_retains_only_two_bounded_private_files_across_restart() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let record = record();
    store.save(record.clone()).await.unwrap();
    let mut seed = diagnostic(&record.id);
    seed.timestamp_ms = 0;
    store.diagnostic(seed.clone()).await.unwrap();
    let folder = root.path().join(&record.id);
    let mut line = serde_json::to_vec(&seed).unwrap();
    line.push(b'\n');
    let full = line.repeat(LIMIT / line.len());
    fs::write(folder.join(LOG), &full).unwrap();
    let mut next = seed.clone();
    next.timestamp_ms = 1;
    store.diagnostic(next.clone()).await.unwrap();
    assert_eq!(fs::read(folder.join(PREVIOUS)).unwrap(), full);
    assert_eq!(entries(&folder.join(LOG)), vec![next.clone()]);
    store.close().await.unwrap();

    let store = JsonConversationStore::open(root.path()).await.unwrap();
    assert_eq!(fs::read(folder.join(PREVIOUS)).unwrap(), full);
    assert_eq!(entries(&folder.join(LOG)), vec![next]);
    seed.timestamp_ms = 2;
    let mut line = serde_json::to_vec(&seed).unwrap();
    line.push(b'\n');
    let replacement = line.repeat(LIMIT / line.len());
    fs::write(folder.join(LOG), &replacement).unwrap();
    seed.timestamp_ms = 3;
    store.diagnostic(seed.clone()).await.unwrap();
    assert_eq!(fs::read(folder.join(PREVIOUS)).unwrap(), replacement);
    assert_eq!(entries(&folder.join(LOG)), vec![seed]);
    assert_eq!(fs::read_dir(&folder).unwrap().count(), 2);
    assert_mode(&folder, 0o700);
    for name in [LOG, PREVIOUS] {
        let path = folder.join(name);
        assert_mode(&path, 0o600);
        assert!(fs::metadata(path).unwrap().len() <= LIMIT as u64);
    }
    store.close().await.unwrap();
}

#[tokio::test]
async fn unsafe_current_or_previous_logs_are_refused_before_append_or_deletion() {
    for name in [LOG, PREVIOUS] {
        for kind in ["symlink", "directory", "fifo", "public", "hardlink"] {
            let root = directory();
            let profile = root.path().join("conversations");
            let store = JsonConversationStore::open(&profile).await.unwrap();
            let record = record();
            store.save(record.clone()).await.unwrap();
            store.diagnostic(diagnostic(&record.id)).await.unwrap();
            let folder = profile.join(&record.id);
            let path = folder.join(name);
            let outside = root.path().join("outside");
            private_file(&outside, b"unrelated private data");
            if name == LOG {
                fs::remove_file(&path).unwrap();
            }
            match kind {
                "symlink" => symlink(&outside, &path).unwrap(),
                "directory" => fs::DirBuilder::new().mode(0o700).create(&path).unwrap(),
                "fifo" => fifo(&path),
                "public" => {
                    private_file(&path, b"insecure file");
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
                }
                "hardlink" => fs::hard_link(&outside, &path).unwrap(),
                _ => unreachable!(),
            }
            let transcript = profile.join(format!("{}.json", record.id));
            let before = fs::read(&transcript).unwrap();
            assert!(
                store.diagnostic(diagnostic(&record.id)).await.is_err(),
                "{name}: {kind}"
            );
            assert!(
                store.delete(record.id.clone()).await.is_err(),
                "{name}: {kind}"
            );
            assert_eq!(fs::read(transcript).unwrap(), before);
            assert_eq!(fs::read(outside).unwrap(), b"unrelated private data");
            assert!(fs::symlink_metadata(path).is_ok());
            store.close().await.unwrap();
        }
    }
}

#[tokio::test]
async fn unsafe_session_folders_are_not_followed_or_removed() {
    for kind in ["symlink", "dangling", "file", "fifo", "public"] {
        let root = directory();
        let profile = root.path().join("conversations");
        let store = JsonConversationStore::open(&profile).await.unwrap();
        let record = record();
        store.save(record.clone()).await.unwrap();
        let folder = profile.join(&record.id);
        let outside = root.path().join("outside");
        fs::DirBuilder::new().mode(0o700).create(&outside).unwrap();
        private_file(&outside.join(LOG), b"unrelated private data");
        match kind {
            "symlink" => symlink(&outside, &folder).unwrap(),
            "dangling" => symlink(root.path().join("missing"), &folder).unwrap(),
            "file" => private_file(&folder, b"not a directory"),
            "fifo" => fifo(&folder),
            "public" => {
                fs::DirBuilder::new().mode(0o700).create(&folder).unwrap();
                fs::set_permissions(&folder, fs::Permissions::from_mode(0o755)).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(
            store.diagnostic(diagnostic(&record.id)).await.is_err(),
            "{kind}"
        );
        assert!(store.delete(record.id.clone()).await.is_err(), "{kind}");
        assert!(profile.join(format!("{}.json", record.id)).exists());
        assert!(fs::symlink_metadata(&folder).is_ok());
        assert_eq!(
            fs::read(outside.join(LOG)).unwrap(),
            b"unrelated private data"
        );
        store.close().await.unwrap();
    }
}

#[tokio::test]
async fn deletion_preserves_unexpected_folder_contents_and_the_transcript() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let record = record();
    store.save(record.clone()).await.unwrap();
    store.diagnostic(diagnostic(&record.id)).await.unwrap();
    let folder = root.path().join(&record.id);
    let before = fs::read(folder.join(LOG)).unwrap();
    private_file(&folder.join("unrelated.txt"), b"do not remove");
    assert!(store.delete(record.id.clone()).await.is_err());
    assert_eq!(
        fs::read(folder.join("unrelated.txt")).unwrap(),
        b"do not remove"
    );
    assert_eq!(fs::read(folder.join(LOG)).unwrap(), before);
    assert_eq!(store.load().await.unwrap(), vec![record]);
    store.close().await.unwrap();
}

#[tokio::test]
async fn invalid_diagnostic_ids_do_not_create_folders() {
    let root = directory();
    let store = JsonConversationStore::open(root.path()).await.unwrap();
    let record = record();
    store.save(record.clone()).await.unwrap();
    for invalid in [
        "",
        "../outside",
        "not-a-uuid",
        "00000000000000000000000000000000",
    ] {
        for field in 0..3 {
            let mut entry = diagnostic(&record.id);
            match field {
                0 => entry.conversation_id = invalid.into(),
                1 => entry.operation_id = invalid.into(),
                2 => entry.message_id = Some(invalid.into()),
                _ => unreachable!(),
            }
            assert!(store.diagnostic(entry).await.is_err());
        }
    }
    assert!(store.delete("../outside".into()).await.is_err());
    assert!(!root.path().join(&record.id).exists());
    store.close().await.unwrap();
}

#[tokio::test]
async fn unsafe_transcripts_do_not_create_folders() {
    for kind in ["symlink", "directory", "fifo"] {
        let root = directory();
        let profile = root.path().join("conversations");
        let store = JsonConversationStore::open(&profile).await.unwrap();
        let record = record();
        let outside = root.path().join("outside");
        private_file(&outside, b"unrelated private data");
        let transcript = profile.join(format!("{}.json", record.id));
        match kind {
            "symlink" => symlink(&outside, &transcript).unwrap(),
            "directory" => fs::create_dir(&transcript).unwrap(),
            "fifo" => fifo(&transcript),
            _ => unreachable!(),
        }
        assert!(store.diagnostic(diagnostic(&record.id)).await.is_err());
        assert!(store.delete(record.id.clone()).await.is_err());
        assert!(!profile.join(&record.id).exists());
        assert_eq!(fs::read(outside).unwrap(), b"unrelated private data");
        store.close().await.unwrap();
    }
}

#[tokio::test]
async fn diagnostics_and_deletion_respect_closed_or_replaced_profile_ownership() {
    for closed in [false, true] {
        let root = directory();
        let store = JsonConversationStore::open(root.path()).await.unwrap();
        let record = record();
        store.save(record.clone()).await.unwrap();
        if closed {
            store.close().await.unwrap();
        } else {
            fs::rename(root.path().join(".lock"), root.path().join(".old-lock")).unwrap();
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.path().join(".lock"))
                .unwrap();
        }
        assert!(store.diagnostic(diagnostic(&record.id)).await.is_err());
        assert!(store.delete(record.id.clone()).await.is_err());
        assert!(!root.path().join(&record.id).exists());
        assert!(root.path().join(format!("{}.json", record.id)).exists());
    }
}
