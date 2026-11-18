mod support;

use async_trait::async_trait;
use exec_agent::{
    Error, Result,
    core::*,
    manager::AgentManager,
    service::{ServiceOptions, start_service},
    storage::ConversationStore,
};
use futures_util::StreamExt;
use std::{
    collections::BTreeMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::*;
use tokio_util::sync::CancellationToken;

#[derive(Default)]
struct Gate {
    entered: CancellationToken,
    release: CancellationToken,
    armed: AtomicBool,
}
impl Gate {
    fn arm(&self) {
        self.armed.store(true, Ordering::SeqCst);
    }
    async fn hold(&self) {
        if self.armed.swap(false, Ordering::SeqCst) {
            self.entered.cancel();
            self.release.cancelled().await;
        }
    }
}

// Saves round-trip through the real disk schema. Gates distinguish mutation,
// durable checkpoint acknowledgement and deletion; no sleeps decide ordering.
#[derive(Default)]
struct GatedStore {
    records: Mutex<BTreeMap<String, ConversationRecord>>,
    save_gate: Gate,
    delete_gate: Gate,
    progress_saves: AtomicUsize,
    deletes: AtomicUsize,
    fail_save: bool,
    fail_after_write: bool,
    fail_delete: bool,
    allow_unsaved_delete: bool,
}
impl GatedStore {
    fn record(&self, id: &str) -> ConversationRecord {
        self.records.lock().unwrap()[id].clone()
    }
}
#[async_trait]
impl Checkpoint for GatedStore {
    async fn save(&self, record: ConversationRecord) -> Result<()> {
        record.validate().unwrap();
        let record: ConversationRecord =
            serde_json::from_slice(&serde_json::to_vec(&record).unwrap()).unwrap();
        let progress = record.messages.iter().any(|m| {
            matches!(
                m,
                Message::Tool {
                    outcome: ToolOutcome::Running,
                    ..
                }
            )
        });
        if progress {
            self.progress_saves.fetch_add(1, Ordering::SeqCst);
            self.save_gate.hold().await;
            if self.fail_save && !self.fail_after_write {
                return Err(Error::Storage);
            }
        }
        self.records
            .lock()
            .unwrap()
            .insert(record.id.clone(), record);
        if progress && self.fail_save {
            Err(Error::Storage)
        } else {
            Ok(())
        }
    }
}
#[async_trait]
impl ConversationStore for GatedStore {
    async fn load(&self) -> Result<Vec<ConversationRecord>> {
        Ok(self.records.lock().unwrap().values().cloned().collect())
    }
    async fn delete(&self, id: String) -> Result<()> {
        let record = self.record(&id);
        if let Some(parent) = record.metadata.parent
            && !self.allow_unsaved_delete
        {
            let saved = self.record(&parent.session_id);
            assert!(
                results(&saved.messages).iter().any(|r| r.session_id == id),
                "child removed before its result was durable"
            );
        }
        let index = self.deletes.fetch_add(1, Ordering::SeqCst);
        self.delete_gate.hold().await;
        if self.fail_delete && index == 0 {
            return Err(Error::Storage);
        }
        self.records.lock().unwrap().remove(&id);
        Ok(())
    }
    async fn save_library(&self, _: LibraryConfiguration) -> Result<()> {
        Ok(())
    }
    async fn close(&self) -> Result<()> {
        Ok(())
    }
}

fn results(messages: &[Message]) -> Vec<DelegationResult> {
    messages
        .iter()
        .rev()
        .find_map(|m| match m {
            Message::Tool {
                details: Some(ToolDetails::Delegation { results, .. }),
                ..
            } => Some(results.clone()),
            _ => None,
        })
        .unwrap_or_default()
}
fn result_message(snapshot: &ConversationSnapshot) -> &Message {
    snapshot
        .messages
        .iter()
        .rev()
        .find(|m| matches!(m, Message::Tool { .. }))
        .unwrap()
}
async fn wait(token: &CancellationToken) {
    tokio::time::timeout(Duration::from_secs(5), token.cancelled())
        .await
        .unwrap();
}
async fn removed(manager: &AgentManager, id: &str) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while manager.snapshot(id).is_ok() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}
fn batch(id: &str, count: usize) -> Script {
    response(vec![
        ProviderEvent::ToolCall(ToolCall {
            id: id.into(),
            name: "delegate".into(),
            arguments: serde_json::json!({"tasks": (0..count).map(|index| serde_json::json!({
            "task": index.to_string(), "title": format!("Task {index}")
        })).collect::<Vec<_>>()})
            .as_object()
            .unwrap()
            .clone(),
        }),
        ProviderEvent::Done,
    ])
}
fn gated_children(count: usize, failure: bool, large: bool) -> (Vec<Script>, Vec<Arc<Gate>>) {
    let gates: Vec<_> = (0..count).map(|_| Arc::new(Gate::default())).collect();
    let scripts = (0..count).map(|_| {
        let gates = gates.clone();
        script(move |request| Box::pin(async_stream::try_stream! {
            let ContextMessage::User { text } = &request.messages[0] else { panic!("missing task") };
            let index: usize = text.parse().unwrap();
            let gate = &gates[index];
            gate.entered.cancel();
            let cancelled = tokio::select! { biased;
                _ = request.cancel.cancelled() => true,
                _ = gate.release.cancelled() => false,
            };
            if cancelled { Err(Error::Cancelled)?; }
            if failure && index == 1 { Err(Error::Internal)?; }
            yield ProviderEvent::Text(format!("Answer {index}: {}", if large { "é🦀".repeat(10_000) } else { "done".into() }));
            yield ProviderEvent::Done;
        }))
    }).collect();
    (scripts, gates)
}
async fn setup(
    store: Arc<GatedStore>,
    provider: Arc<FakeProvider>,
    workspace: &std::path::Path,
) -> (Arc<AgentManager>, Arc<Conversation>) {
    let manager = AgentManager::open(store, |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let mut library = manager.library_configuration().unwrap();
    library.automatic_titles = false;
    manager.update_library(library).await.unwrap();
    let parent = manager
        .create_session(
            provider,
            vec![],
            Some("fake".into()),
            workspace.to_string_lossy().into_owned(),
            None,
            Some(vec![]),
        )
        .await
        .unwrap();
    (manager, parent)
}
fn child_id(manager: &AgentManager, index: usize) -> String {
    manager
        .list()
        .unwrap()
        .into_iter()
        .find(|s| s.metadata.parent.is_some() && s.metadata.title == Some(format!("Task {index}")))
        .unwrap()
        .id
}
fn pending(run: &mut Submission, provider: &FakeProvider, requests: usize, parent: &Conversation) {
    assert!(matches!(
        run.completion.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
    ));
    assert_eq!(provider.count(), requests);
    assert!(parent.busy());
    assert!(parent.snapshot().active_tool_call_id.is_some());
}

#[tokio::test]
async fn each_child_is_checkpointed_then_deleted_while_the_parent_tool_keeps_running() {
    let workspace = directory();
    let store = Arc::new(GatedStore::default());
    store.save_gate.arm();
    store.delete_gate.arm();
    let (children, gates) = gated_children(2, false, false);
    let mut scripts = vec![batch("batch", 2)];
    scripts.extend(children);
    scripts.push(answer());
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
    let service = start_service(ServiceOptions {
        access: http_access(),
        manager: manager.clone(),
        provider: provider.clone(),
        tools: vec![],
        address: "127.0.0.1:0".parse().unwrap(),
    })
    .await
    .unwrap();
    let client = client::AgentClient::new(service.address).unwrap();
    let mut run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    for gate in &gates {
        wait(&gate.entered).await;
    }
    let slow = child_id(&manager, 0);
    let fast = child_id(&manager, 1);
    let (_, mut events) = parent.subscribe();
    gates[1].release.cancel();
    wait(&store.save_gate.entered).await;
    assert!(results(&store.record(&parent.id).messages).is_empty());
    assert_eq!(
        manager.snapshot(&fast).unwrap().operation.unwrap().state,
        OperationState::Completed
    );
    assert_eq!(store.deletes.load(Ordering::SeqCst), 0);
    pending(&mut run, &provider, 3, &parent);
    store.save_gate.release.cancel();
    wait(&store.delete_gate.entered).await;
    let saved = store.record(&parent.id);
    let partial_id = result_message(&parent.snapshot()).id().to_owned();
    assert_eq!(results(&saved.messages)[0].task_index, 1);
    assert!(
        !context(&saved.messages)
            .iter()
            .any(|m| matches!(m, ContextMessage::Tool { .. }))
    );
    assert!(manager.get(&fast).is_err()); // Mutation-capable handle stays guarded.
    assert!(manager.snapshot(&fast).is_ok());
    assert!(manager.observe(&fast).is_ok());
    assert!(manager.rename(&fast, "changed".into()).await.is_err());
    assert!(
        manager
            .submit(&fast, "competing turn".into())
            .await
            .is_err()
    );
    assert!(manager.compact(&fast).is_err());
    assert!(
        manager
            .update_settings(&fast, SessionSettings::default())
            .await
            .is_err()
    );
    assert!(manager.fork(&fast, provider.clone(), vec![]).await.is_err());
    assert!(manager.delete(&fast).await.is_err());
    for suffix in ["", "/sync"] {
        let value = client
            .call("GET", &format!("/v1/conversations/{fast}{suffix}"), None)
            .await
            .unwrap();
        assert_eq!(
            if suffix.is_empty() {
                &value["id"]
            } else {
                &value["snapshot"]["id"]
            },
            &serde_json::json!(fast)
        );
    }
    let mut observer = client.events(&fast, CancellationToken::new());
    assert!(matches!(
        observer.next().await.unwrap().unwrap(),
        ServiceEvent::Snapshot { .. }
    ));
    drop(observer);
    store.delete_gate.release.cancel();
    removed(&manager, &fast).await;
    assert_eq!(
        client
            .call("GET", &format!("/v1/conversations/{fast}"), None)
            .await
            .unwrap_err(),
        Error::Api(404)
    );
    assert!(
        manager
            .snapshot(&slow)
            .unwrap()
            .operation
            .unwrap()
            .state
            .active()
    );
    assert_eq!(manager.list().unwrap().len(), 2);
    pending(&mut run, &provider, 3, &parent);
    let mut saw_progress = false;
    while let Ok(frame) = events.try_recv() {
        if let ServiceEvent::Runtime { event, snapshot } = frame.as_ref() {
            assert!(!matches!(event.kind, EventKind::ToolFinished { .. }));
            if let EventKind::Message { message_id } = &event.kind {
                assert_eq!(message_id, &partial_id);
                assert!(matches!(
                    result_message(snapshot.as_ref().unwrap()),
                    Message::Tool {
                        outcome: ToolOutcome::Running,
                        ..
                    }
                ));
                saw_progress = true;
            }
        }
    }
    assert!(saw_progress);
    let partial_page = client
        .call(
            "GET",
            &format!("/v1/conversations/{}/sync", parent.id),
            None,
        )
        .await
        .unwrap();
    let wire_message = partial_page["snapshot"]["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap();
    assert_eq!(wire_message["id"], partial_id);
    assert_eq!(wire_message["outcome"], "running");
    assert_eq!(wire_message["details"]["type"], "delegation");
    assert_eq!(wire_message["details"]["total"], 2);
    assert_eq!(wire_message["details"]["results"][0]["taskIndex"], 1);
    assert_eq!(wire_message["details"]["results"][0]["sessionId"], fast);
    let partial_prefix = partial_page["prefix"].as_str().unwrap();

    // Simulate restart from exactly this durable partial checkpoint, not live state.
    let restored_store = Arc::new(GatedStore::default());
    *restored_store.records.lock().unwrap() = store.records.lock().unwrap().clone();
    let restored = AgentManager::open(restored_store, |_| (provider.clone(), vec![]))
        .await
        .unwrap();
    let recovered = restored.get(&parent.id).unwrap().record();
    recovered.validate().unwrap();
    assert_eq!(recovered.messages.last().unwrap().id(), partial_id);
    assert!(matches!(
        recovered.messages.last().unwrap(),
        Message::Tool {
            outcome: ToolOutcome::Interrupted,
            ..
        }
    ));
    assert_eq!(results(&recovered.messages)[0].session_id, fast);
    assert!(restored.snapshot(&fast).is_err());
    assert_eq!(
        restored.snapshot(&slow).unwrap().operation.unwrap().state,
        OperationState::Interrupted
    );
    restored.close().await.unwrap();
    let fork = manager
        .fork(&parent.id, provider.clone(), vec![])
        .await
        .unwrap();
    fork.record().validate().unwrap();
    assert!(results(&fork.snapshot().messages).is_empty());

    gates[0].release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    let snapshot = parent.snapshot();
    let message = result_message(&snapshot);
    assert_eq!(message.id(), partial_id);
    assert!(matches!(
        message,
        Message::Tool {
            outcome: ToolOutcome::Completed,
            ..
        }
    ));
    assert!(message.text().find("Answer 0").unwrap() < message.text().find("Answer 1").unwrap());
    let delta = client
        .call(
            "GET",
            &format!(
                "/v1/conversations/{}/sync?after={partial_id}&prefix={partial_prefix}",
                parent.id
            ),
            None,
        )
        .await
        .unwrap();
    assert_eq!(delta["reset"], false);
    let updated = &delta["snapshot"]["messages"][0];
    assert_eq!(updated["id"], partial_id);
    assert_eq!(updated["callID"], "batch");
    assert_eq!(updated["outcome"], "completed");
    assert_eq!(updated["details"]["results"].as_array().unwrap().len(), 2);
    assert_eq!(
        results(&snapshot.messages)
            .iter()
            .map(|r| r.task_index)
            .collect::<Vec<_>>(),
        [0, 1]
    );
    assert_eq!(
        event_kinds(&mut events)
            .iter()
            .filter(|e| matches!(e, EventKind::ToolFinished { .. }))
            .count(),
        1
    );
    assert_eq!(provider.count(), 4);
    {
        let requests = provider.requests.lock().unwrap();
        assert_eq!(
            requests[3]
                .messages
                .iter()
                .filter(|m| matches!(
                    m,
                    ContextMessage::Tool {
                        outcome: ToolOutcome::Completed,
                        ..
                    }
                ))
                .count(),
            1
        );
    }
    service.close().await.unwrap();
}

#[tokio::test]
async fn failed_progress_checkpoint_retains_inspectable_results_and_every_child_without_retry() {
    for fail_after_write in [false, true] {
        let workspace = directory();
        let store = Arc::new(GatedStore {
            fail_save: true,
            fail_after_write,
            ..Default::default()
        });
        store.save_gate.arm();
        let (children, gates) = gated_children(2, false, false);
        let mut scripts = vec![batch("batch", 2)];
        scripts.extend(children);
        let provider = FakeProvider::new(scripts);
        let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
        let mut run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
        for gate in &gates {
            wait(&gate.entered).await;
        }
        gates[1].release.cancel();
        wait(&store.save_gate.entered).await;
        store.save_gate.release.cancel();
        until(&parent, |s| s.storage_error.is_some()).await;
        pending(&mut run, &provider, 3, &parent);
        assert_eq!(manager.list().unwrap().len(), 3);
        assert_eq!(
            manager
                .snapshot(&child_id(&manager, 0))
                .unwrap()
                .operation
                .unwrap()
                .state,
            OperationState::Running
        );
        gates[0].release.cancel();
        assert_eq!(complete(run).await.state, OperationState::Failed);
        assert_eq!(results(&parent.snapshot().messages).len(), 2);
        assert_eq!(manager.list().unwrap().len(), 3);
        assert_eq!(store.progress_saves.load(Ordering::SeqCst), 1);
        assert_eq!(store.deletes.load(Ordering::SeqCst), 0);
        assert_eq!(
            results(&store.record(&parent.id).messages).len(),
            usize::from(fail_after_write)
        );
        parent.record().validate().unwrap();
        for session in manager
            .list()
            .unwrap()
            .into_iter()
            .filter(|s| s.metadata.parent.is_some())
        {
            assert_eq!(session.operation.unwrap().state, OperationState::Completed);
            assert!(
                session.messages.iter().any(
                    |m| matches!(m, Message::Assistant { text, .. } if text.contains("Answer"))
                )
            );
        }
        assert_eq!(provider.count(), 3);
    }
}

#[tokio::test]
async fn deletion_failure_keeps_the_durable_result_and_session_and_does_not_stop_a_sibling() {
    let workspace = directory();
    let store = Arc::new(GatedStore {
        fail_delete: true,
        ..Default::default()
    });
    store.delete_gate.arm();
    let (children, gates) = gated_children(2, false, false);
    let mut scripts = vec![batch("batch", 2)];
    scripts.extend(children);
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
    let mut run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    for gate in &gates {
        wait(&gate.entered).await;
    }
    let fast = child_id(&manager, 1);
    gates[1].release.cancel();
    wait(&store.delete_gate.entered).await;
    store.delete_gate.release.cancel();
    pending(&mut run, &provider, 3, &parent);
    gates[0].release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Failed);
    assert!(manager.snapshot(&fast).is_ok());
    assert_eq!(manager.list().unwrap().len(), 2);
    assert_eq!(results(&store.record(&parent.id).messages).len(), 2);
    assert_eq!(store.deletes.load(Ordering::SeqCst), 2); // No cleanup-hook retry.
    parent.record().validate().unwrap();
    assert_eq!(provider.count(), 3);
}

#[tokio::test]
async fn failure_or_individual_cancellation_publishes_early_without_cancelling_siblings() {
    for cancel_child in [false, true] {
        let workspace = directory();
        let store = Arc::new(GatedStore::default());
        let (children, gates) = gated_children(2, !cancel_child, false);
        let mut scripts = vec![batch("batch", 2)];
        scripts.extend(children);
        scripts.push(answer());
        let provider = FakeProvider::new(scripts);
        let (manager, parent) = setup(store, provider.clone(), workspace.path()).await;
        let mut run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
        for gate in &gates {
            wait(&gate.entered).await;
        }
        let fast = child_id(&manager, 1);
        if cancel_child {
            let child = manager.get(&fast).unwrap();
            assert!(child.cancel(&child.snapshot().operation.unwrap().id));
        } else {
            gates[1].release.cancel();
        }
        removed(&manager, &fast).await;
        let partial = results(&parent.snapshot().messages);
        assert_eq!(
            partial[0].outcome,
            if cancel_child {
                ToolOutcome::Interrupted
            } else {
                ToolOutcome::Failed
            }
        );
        assert!(partial[0].text.contains("Do not retry"));
        pending(&mut run, &provider, 3, &parent);
        assert_eq!(
            manager
                .snapshot(&child_id(&manager, 0))
                .unwrap()
                .operation
                .unwrap()
                .state,
            OperationState::Running
        );
        gates[0].release.cancel();
        assert_eq!(complete(run).await.state, OperationState::Completed);
        assert_eq!(outcomes(&parent), [ToolOutcome::Completed]);
        assert_eq!(manager.list().unwrap().len(), 1);
        assert_eq!(provider.count(), 4);
    }
}

#[tokio::test]
async fn parent_cancellation_preserves_published_results_and_retains_unfinished_children() {
    let workspace = directory();
    let store = Arc::new(GatedStore::default());
    let (children, gates) = gated_children(2, false, false);
    let mut scripts = vec![batch("batch", 2)];
    scripts.extend(children);
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
    let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    for gate in &gates {
        wait(&gate.entered).await;
    }
    let slow = child_id(&manager, 0);
    let fast = child_id(&manager, 1);
    gates[1].release.cancel();
    removed(&manager, &fast).await;
    assert!(parent.cancel(&run.operation_id));
    assert_eq!(complete(run).await.state, OperationState::Interrupted);
    let saved = store.record(&parent.id);
    saved.validate().unwrap();
    assert_eq!(results(&saved.messages)[0].session_id, fast);
    assert!(saved.messages.last().unwrap().text().contains("Answer 1"));
    assert_eq!(
        manager.snapshot(&slow).unwrap().operation.unwrap().state,
        OperationState::Interrupted
    );
    assert_eq!(outcomes(&parent), [ToolOutcome::Interrupted]);
    assert_eq!(provider.count(), 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn repeated_full_batches_publish_in_completion_order_and_return_bounded_original_order() {
    const TURNS: usize = 12;
    const CHILDREN: usize = 8;
    let workspace = directory();
    let store = Arc::new(GatedStore::default());
    let mut scripts = vec![];
    let mut all_gates = vec![];
    for turn in 0..TURNS {
        let (children, gates) = gated_children(CHILDREN, false, true);
        scripts.push(batch(&format!("batch-{turn}"), CHILDREN));
        scripts.extend(children);
        scripts.push(answer());
        all_gates.push(gates);
    }
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
    for (turn, gates) in all_gates.into_iter().enumerate() {
        let mut run = manager
            .submit(&parent.id, format!("Batch {turn}"))
            .await
            .unwrap();
        for gate in &gates {
            wait(&gate.entered).await;
        }
        let ids: Vec<_> = (0..CHILDREN).map(|i| child_id(&manager, i)).collect();
        for index in (0..CHILDREN).rev() {
            gates[index].release.cancel();
            removed(&manager, &ids[index]).await;
            let saved = store.record(&parent.id);
            let partial = results(&saved.messages);
            assert_eq!(
                partial.iter().map(|r| r.task_index).collect::<Vec<_>>(),
                (index..CHILDREN).collect::<Vec<_>>()
            );
            assert!(
                partial
                    .iter()
                    .all(|r| r.text.contains("Response truncated"))
            );
            if index > 0 {
                pending(
                    &mut run,
                    &provider,
                    turn * (CHILDREN + 2) + CHILDREN + 1,
                    &parent,
                );
                assert_eq!(manager.list().unwrap().len(), index + 1);
            }
        }
        assert_eq!(complete(run).await.state, OperationState::Completed);
        let snapshot = parent.snapshot();
        let message = result_message(&snapshot);
        assert!(message.text().len() <= MAX_DELEGATION_OUTPUT_BYTES);
        assert_eq!(
            message.text(),
            results(&snapshot.messages)
                .iter()
                .map(|r| r.text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n")
        );
        assert_eq!(manager.list().unwrap().len(), 1);
        parent.record().validate().unwrap();
    }
    assert_eq!(store.deletes.load(Ordering::SeqCst), TURNS * CHILDREN);
    assert_eq!(provider.count(), TURNS * (CHILDREN + 2));
}

#[tokio::test]
async fn steering_during_a_progress_checkpoint_keeps_polling_the_delegate() {
    let workspace = directory();
    let store = Arc::new(GatedStore::default());
    store.save_gate.arm();
    let (children, gates) = gated_children(2, false, false);
    let mut scripts = vec![batch("batch", 2)];
    scripts.extend(children);
    scripts.push(answer());
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
    let mut run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    for gate in &gates {
        wait(&gate.entered).await;
    }
    let fast = child_id(&manager, 1);
    gates[1].release.cancel();
    wait(&store.save_gate.entered).await;
    parent
        .steer(&run.operation_id, "New instructions".into())
        .unwrap();
    // The delegate holds the checkpoint lock while the steering save waits for it.
    // Both futures must keep moving; neither may be dropped to break the deadlock.
    store.save_gate.release.cancel();
    removed(&manager, &fast).await;
    pending(&mut run, &provider, 3, &parent);
    gates[0].release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Completed);
    assert_eq!(store.deletes.load(Ordering::SeqCst), 2);
    assert_eq!(manager.list().unwrap().len(), 1);
    assert!(provider.requests.lock().unwrap().last().unwrap().messages.iter().any(
        |message| matches!(message, ContextMessage::User { text } if text == "New instructions")
    ));
    parent.record().validate().unwrap();
}

#[tokio::test]
async fn automatic_cleanup_never_retries_a_failed_explicit_child_deletion() {
    let workspace = directory();
    let store = Arc::new(GatedStore {
        fail_delete: true,
        allow_unsaved_delete: true, // Explicit user deletion need not wait for a result.
        ..Default::default()
    });
    store.save_gate.arm();
    let (children, gates) = gated_children(2, false, false);
    let mut scripts = vec![batch("batch", 2)];
    scripts.extend(children);
    let provider = FakeProvider::new(scripts);
    let (manager, parent) = setup(store.clone(), provider.clone(), workspace.path()).await;
    let run = manager.submit(&parent.id, "Delegate".into()).await.unwrap();
    for gate in &gates {
        wait(&gate.entered).await;
    }
    let fast = child_id(&manager, 1);
    gates[1].release.cancel();
    wait(&store.save_gate.entered).await;
    assert_eq!(manager.delete(&fast).await.unwrap_err(), Error::Storage);
    assert!(manager.snapshot(&fast).is_ok());
    store.save_gate.release.cancel();
    gates[0].release.cancel();
    assert_eq!(complete(run).await.state, OperationState::Failed);
    assert!(manager.snapshot(&fast).is_ok());
    assert_eq!(manager.list().unwrap().len(), 2);
    assert_eq!(store.deletes.load(Ordering::SeqCst), 2); // One failed attempt + sibling cleanup.
    assert_eq!(results(&store.record(&parent.id).messages).len(), 2);
    assert_eq!(provider.count(), 3);
    parent.record().validate().unwrap();
}
