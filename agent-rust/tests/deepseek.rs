#[path = "support/http.rs"]
mod http;
mod support;
use exec_agent::{
    Error, ProviderFailure as Failure,
    core::*,
    manager::AgentManager,
    providers::{DeepSeekProvider, HttpResponse},
    storage::JsonConversationStore,
    tools::create_workspace_tools,
};
use futures_util::StreamExt;
use http::*;
use serde_json::json;
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio_util::sync::CancellationToken;
#[tokio::test]
async fn concrete_non_thinking_requests_and_split_utf8_sse_framing() {
    let value = delta(json!({"role":"assistant","content":"Hello λ 🥑"}), None).to_string();
    let index = value.find('[').unwrap();
    let data = format!(
        "\u{feff}: keepalive\r\nretry: 1\r\n\r\ndata: {}\rdata: {}\r\r{}{}{}",
        &value[..index],
        &value[index..],
        event(delta(json!({}), Some("stop"))),
        event(json!({"choices":[],"usage":{"total_tokens":10}})),
        event(json!("[DONE]"))
    );
    let dropped = Arc::new(AtomicBool::new(false));
    let observed = dropped.clone();
    let t = Transport::new(move |r| {
        let data = data.clone();
        let dropped = observed.clone();
        async move {
            assert_eq!(r.path, "chat/completions");
            assert_eq!(r.key, "synthetic-test-key");
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&r.body.unwrap()).unwrap(),
                json!({"model":"deepseek-flash","stream":true,"thinking":{"type":"disabled"},"reasoning_effort":"none","messages":[{"role":"user","content":"Hello"}]})
            );
            Ok(response(data, 1, true, dropped))
        }
    });
    assert_eq!(
        collect(&provider(t.clone()), request()).await.unwrap(),
        vec![
            ProviderEvent::Text("Hello λ 🥑".into()),
            ProviderEvent::Done
        ]
    );
    assert_eq!(t.count(), 1);
    assert!(dropped.load(Ordering::SeqCst));
}
#[tokio::test]
async fn fragmented_calls_assembled_by_index_withheld_until_completion() {
    let first = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = first.clone();
    let held = release.clone();
    let t = Transport::new(move |_| {
        let ready = ready.clone();
        let held = held.clone();
        async move {
            let body = async_stream::try_stream! {
                yield bytes::Bytes::from(event(delta(json!({"tool_calls":[{"index":1,"id":"second","type":"function","function":{"name":"read_file","arguments":"{\"path\":"}},{"index":0,"id":"first","type":"function","function":{"name":"list_files","arguments":"{\"path\":\""}}]}),None)));
                ready.cancel();held.cancelled().await;
                yield bytes::Bytes::from(event(delta(json!({"tool_calls":[{"index":0,"function":{"arguments":".\"}"}},{"index":1,"function":{"arguments":"\"x\",\"start_line\":1,\"end_line\":2}"}}]}),Some("tool_calls")))+&event(json!("[DONE]")));
            };
            Ok(HttpResponse {
                status: 200,
                content_type: Some("text/event-stream".into()),
                body: Box::pin(body),
            })
        }
    });
    let p = provider(t);
    let seen = Arc::new(Mutex::new(vec![]));
    let observed = seen.clone();
    let task = tokio::spawn(async move {
        let mut stream = p.stream(request());
        while let Some(event) = stream.next().await {
            observed.lock().unwrap().push(event.unwrap());
        }
    });
    first.cancelled().await;
    assert!(seen.lock().unwrap().is_empty());
    release.cancel();
    task.await.unwrap();
    let events = seen.lock().unwrap();
    assert_eq!(events.len(), 3);
    assert!(
        matches!(&events[0],ProviderEvent::ToolCall(c) if c.id=="first"&&c.name=="list_files"&&c.arguments["path"]==".")
    );
    assert!(
        matches!(&events[1],ProviderEvent::ToolCall(c) if c.id=="second"&&c.arguments["end_line"]==2)
    );
}
async fn invalid_response(case: usize) {
    let finish = event(delta(json!({}), Some("tool_calls")));
    let done = event(json!("[DONE]"));
    let normal = event(call("{}", 0, "call-1"));
    let data = match case {
        0 => normal + &finish,
        1 => normal + &done,
        2 => normal + &event(delta(json!({}), Some("length"))) + &done,
        3 => normal + &event(delta(json!({}), Some("stop"))) + &done,
        4 => event(call("[]", 0, "call-1")) + &finish + &done,
        5 => event(call("{\"x\":1e999}", 0, "call-1")) + &finish + &done,
        6 => event(call("{}", 0, "same")) + &event(call("{}", 1, "same")) + &finish + &done,
        7 => event(call("{}", 1, "call-1")) + &finish + &done,
        8 => {
            event(call(
                &json!({"x":"x".repeat(32768)}).to_string(),
                0,
                "call-1",
            )) + &finish
                + &done
        }
        9 => event(json!("{malformed")),
        10 => event(delta(
            json!({"reasoning_content":"must not expose reasoning"}),
            None,
        )),
        _ => unreachable!(),
    };
    let t = Transport::new(move |_| {
        let data = data.clone();
        async move { Ok(wire(data)) }
    });
    let mut stream = provider(t.clone()).stream(request());
    let mut failed = false;
    while let Some(event) = stream.next().await {
        match event {
            Ok(event) => assert!(!matches!(
                event,
                ProviderEvent::ToolCall(_) | ProviderEvent::Done
            )),
            Err(Error::Provider(_)) => {
                failed = true;
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(failed);
    assert_eq!(t.count(), 1);
}
macro_rules! invalid {
    ($name:ident,$case:literal) => {
        #[tokio::test]
        async fn $name() {
            invalid_response($case).await;
        }
    };
}
invalid!(missing_sentinel, 0);
invalid!(missing_finish, 1);
invalid!(output_limit_finish, 2);
invalid!(inconsistent_stop, 3);
invalid!(invalid_arguments, 4);
invalid!(nonfinite_arguments, 5);
invalid!(duplicate_ids, 6);
invalid!(missing_index, 7);
invalid!(oversized_arguments, 8);
invalid!(malformed_event, 9);
invalid!(unexpected_thinking, 10);
#[tokio::test]
async fn malformed_utf8_and_oversized_frames_are_bounded_failures() {
    for data in [
        vec![255],
        format!("data: {}\n\n", "x".repeat(256 * 1024)).into_bytes(),
    ] {
        let t = Transport::new(move |_| {
            let data = data.clone();
            async move { Ok(wire(data)) }
        });
        assert_eq!(
            collect(&provider(t), request()).await.unwrap_err(),
            Error::Provider(Failure::Response)
        );
    }
}
#[tokio::test]
async fn http_failures_sanitized_body_discarded_no_retry() {
    for (status, code) in [
        (401, Failure::Authentication),
        (402, Failure::Quota),
        (429, Failure::RateLimit),
        (500, Failure::Transport),
        (302, Failure::Transport),
    ] {
        let dropped = Arc::new(AtomicBool::new(false));
        let observed = dropped.clone();
        let t = Transport::new(move |_| {
            let dropped = observed.clone();
            async move {
                let mut response = response("raw secret: synthetic-test-key", 19, true, dropped);
                response.status = status;
                Ok(response)
            }
        });
        let error = collect(&provider(t.clone()), request()).await.unwrap_err();
        assert_eq!(error, Error::Provider(code));
        assert!(!error.to_string().contains("synthetic-test-key"));
        assert_eq!(t.count(), 1);
        assert!(dropped.load(Ordering::SeqCst));
    }
}
#[tokio::test]
async fn credential_transport_errors_never_enter_runtime_verbatim() {
    let t = Transport::new(|_| async { Err(Error::Tool("raw request synthetic-test-key".into())) });
    let p = DeepSeekProvider::with_transport(
        Arc::new(|_| {
            Box::pin(async { Err(Error::Tool("private credential synthetic-test-key".into())) })
        }),
        t.clone(),
        Duration::from_secs(2),
    )
    .unwrap();
    let mut config = support::options(Arc::new(p), vec![]);
    config.model = "deepseek-flash".into();
    let c = Conversation::new(config, None).unwrap();
    assert_eq!(
        support::complete(c.submit("Hi".into()).unwrap())
            .await
            .state,
        OperationState::Failed
    );
    assert!(
        c.snapshot()
            .operation
            .unwrap()
            .error
            .unwrap()
            .contains("authentication failed")
    );
    assert!(
        !serde_json::to_string(&c.snapshot())
            .unwrap()
            .contains("synthetic-test-key")
    );
    assert_eq!(t.count(), 0);
    assert_eq!(
        collect(&provider(t.clone()), request()).await.unwrap_err(),
        Error::Provider(Failure::Transport)
    );
    assert_eq!(t.count(), 1);
}
#[tokio::test]
async fn missing_credentials_and_precancel_send_no_request() {
    let t = Transport::new(|_| async { panic!("unexpected request") });
    let missing = DeepSeekProvider::with_transport(
        Arc::new(|_| Box::pin(async { Ok(String::new()) })),
        t.clone(),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(
        collect(&missing, request()).await.unwrap_err(),
        Error::Provider(Failure::Authentication)
    );
    let p = DeepSeekProvider::with_transport(
        Arc::new(|_| panic!("unexpected credentials")),
        t.clone(),
        Duration::from_secs(2),
    )
    .unwrap();
    let r = request();
    r.cancel.cancel();
    assert_eq!(collect(&p, r).await.unwrap_err(), Error::Cancelled);
    assert_eq!(t.count(), 0);
}
#[tokio::test]
async fn timeout_cancels_stalled_body_without_retry() {
    let dropped = Arc::new(AtomicBool::new(false));
    let observed = dropped.clone();
    let t = Transport::new(move |_| {
        let dropped = observed.clone();
        async move { Ok(response("", 19, true, dropped)) }
    });
    let p = DeepSeekProvider::with_transport(credentials(), t.clone(), Duration::from_millis(30))
        .unwrap();
    assert_eq!(
        collect(&p, request()).await.unwrap_err(),
        Error::Provider(Failure::Timeout)
    );
    assert_eq!(t.count(), 1);
    assert!(dropped.load(Ordering::SeqCst));
}
#[tokio::test]
async fn cancellation_before_headers_aborts_transport_without_retry() {
    let ready = CancellationToken::new();
    let entered = ready.clone();
    let t = Transport::new(move |_| {
        let entered = entered.clone();
        async move {
            entered.cancel();
            std::future::pending().await
        }
    });
    let p = provider(t.clone());
    let r = request();
    let cancel = r.cancel.clone();
    let task = tokio::spawn(async move { collect(&p, r).await });
    ready.cancelled().await;
    cancel.cancel();
    assert_eq!(task.await.unwrap().unwrap_err(), Error::Cancelled);
    assert_eq!(t.count(), 1);
    assert!(t.requests.lock().unwrap()[0].cancel.is_cancelled());
}
#[tokio::test]
async fn late_credentials_after_cancellation_cannot_send_inference() {
    let entered = CancellationToken::new();
    let release = CancellationToken::new();
    let ready = entered.clone();
    let held = release.clone();
    let t = Transport::new(|_| async { panic!("late credentials sent inference") });
    let p = DeepSeekProvider::with_transport(
        Arc::new(move |_| {
            let ready = ready.clone();
            let held = held.clone();
            Box::pin(async move {
                ready.cancel();
                held.cancelled().await;
                Ok("synthetic-test-key".into())
            })
        }),
        t.clone(),
        Duration::from_secs(2),
    )
    .unwrap();
    let r = request();
    let cancel = r.cancel.clone();
    let task = tokio::spawn(async move { collect(&p, r).await });
    entered.cancelled().await;
    cancel.cancel();
    release.cancel();
    assert_eq!(task.await.unwrap().unwrap_err(), Error::Cancelled);
    assert_eq!(t.count(), 0);
}
#[tokio::test]
async fn successful_http_still_requires_expected_body_and_type() {
    for kind in [None, Some("application/json"), Some("text/event-stream")] {
        let t = Transport::new(move |_| async move {
            let mut r = wire("");
            r.content_type = kind.map(str::to_owned);
            Ok(r)
        });
        assert_eq!(
            collect(&provider(t), request()).await.unwrap_err(),
            Error::Provider(Failure::Response)
        );
    }
}
#[tokio::test]
async fn shared_provider_isolates_concurrent_cancellation() {
    let dropped = Arc::new(AtomicBool::new(false));
    let observed = dropped.clone();
    let t = Transport::new(move |r| {
        let dropped = observed.clone();
        async move {
            let body: serde_json::Value = serde_json::from_str(&r.body.unwrap()).unwrap();
            Ok(if body["messages"][1]["content"] == "A" {
                response(
                    event(delta(json!({"content":"Partial A"}), None)),
                    4096,
                    true,
                    dropped,
                )
            } else {
                wire(complete("B completed"))
            })
        }
    });
    let p = Arc::new(provider(t.clone()));
    let a = support::conversation(p.clone(), vec![]);
    let b = support::conversation(p, vec![]);
    let first = a.submit("A".into()).unwrap();
    let second = b.submit("B".into()).unwrap();
    support::until(&a, |s| {
        s.messages.last().is_some_and(|m| m.text() == "Partial A")
    })
    .await;
    a.cancel(&first.operation_id);
    assert_eq!(
        support::complete(first).await.state,
        OperationState::Interrupted
    );
    assert_eq!(
        support::complete(second).await.state,
        OperationState::Completed
    );
    assert!(dropped.load(Ordering::SeqCst));
    assert_eq!(t.count(), 2);
}
#[tokio::test]
async fn model_discovery_only_bounded_neutral_metadata() {
    let t = Transport::new(|r| async move {
        assert_eq!(r.path, "models");
        assert!(r.body.is_none());
        Ok(json_response(
            json!({"object":"list","data":[{"id":"deepseek-flash","name":"DeepSeek Flash","context_window":1048576,"max_output_tokens":393216,"owned_by":"not exported","effort":{"supported_levels":["high"]}},{"id":"deepseek-v4-pro"}]}),
        ))
    });
    let models = provider(t.clone())
        .models(CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(
        serde_json::to_value(models).unwrap(),
        json!([{"id":"deepseek-flash","name":"DeepSeek Flash","contextWindow":1048576,"maxOutputTokens":393216},{"id":"deepseek-v4-pro","name":"deepseek-v4-pro"}])
    );
    assert_eq!(t.count(), 1);
    let t = Transport::new(|_| async {
        Ok(json_response(
            json!({"object":"list","data":[{"id":"duplicate"},{"id":"duplicate"}]}),
        ))
    });
    assert_eq!(
        provider(t)
            .models(CancellationToken::new())
            .await
            .unwrap_err(),
        Error::Provider(Failure::Response)
    );
}
#[tokio::test]
async fn deepseek_shaped_responses_drive_approved_real_tools_and_durable_continuation() {
    let root = support::directory();
    let profile = root.path().join("profile");
    let calls = Arc::new(AtomicUsize::new(0));
    let count = calls.clone();
    let t = Transport::new(move |_| {
        let index = count.fetch_add(1, Ordering::SeqCst);
        async move {
            Ok(wire(if index == 0 {
                event(call(&json!({"path":"result.txt","expected_revision":"new","old_text":"","new_text":"approved content"}).to_string(),0,"call-1"))+&event(delta(json!({}),Some("tool_calls")))+&event(json!("[DONE]"))
            } else {
                complete("File created")
            }))
        }
    });
    let p = Arc::new(provider(t.clone()));
    let tools = create_workspace_tools();
    let manager = AgentManager::open(JsonConversationStore::open(&profile).await.unwrap(), |_| {
        (p.clone(), tools.clone())
    })
    .await
    .unwrap();
    let mut config = support::options(p.clone(), tools.clone());
    config.workspace = root.path().to_string_lossy().into();
    config.model = "deepseek-flash".into();
    let c = manager.create(config).await.unwrap();
    let run = c.submit("Create result.txt".into()).unwrap();
    let a = support::approval(&c).await;
    assert!(!root.path().join("result.txt").exists());
    assert_eq!(t.count(), 1);
    c.resolve_approval(&run.operation_id, &a.id, true);
    assert_eq!(
        support::complete(run).await.state,
        OperationState::Completed
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("result.txt")).unwrap(),
        "approved content"
    );
    assert_eq!(t.count(), 2);
    {
        let requests = t.requests.lock().unwrap();
        let body: serde_json::Value =
            serde_json::from_str(requests[1].body.as_ref().unwrap()).unwrap();
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][2]["role"], "assistant");
        assert_eq!(body["messages"][3]["tool_call_id"], "call-1");
        assert!(
            body["messages"][3]["content"]
                .as_str()
                .unwrap()
                .contains("Edited")
        );
    }
    manager.close().await.unwrap();
    let disk = std::fs::read_to_string(profile.join(format!("{}.json", c.id))).unwrap();
    assert!(!disk.contains("synthetic-test-key") && !disk.contains("Authorization"));
    let restored = AgentManager::open(JsonConversationStore::open(profile).await.unwrap(), |_| {
        (p.clone(), tools.clone())
    })
    .await
    .unwrap();
    assert_eq!(t.count(), 2);
    support::complete(
        restored
            .get(&c.id)
            .unwrap()
            .submit("Continue".into())
            .unwrap(),
    )
    .await;
    assert_eq!(t.count(), 3);
    let count = serde_json::from_str::<serde_json::Value>(
        t.requests.lock().unwrap()[2].body.as_ref().unwrap(),
    )
    .unwrap()["messages"]
        .as_array()
        .unwrap()
        .len();
    assert_eq!(count, 6);
    restored.close().await.unwrap();
}
#[tokio::test]
async fn tool_failure_outcomes_explicit_in_deepseek_wire_context() {
    let mut r = request();
    r.messages = vec![
        ContextMessage::User {
            text: "Change".into(),
        },
        ContextMessage::Assistant {
            text: "".into(),
            calls: vec![ToolCall {
                id: "a".into(),
                name: "edit_file".into(),
                arguments: json!({"path":"x"}).as_object().unwrap().clone(),
            }],
        },
        ContextMessage::Tool {
            call_id: "a".into(),
            text: "May have had effects".into(),
            outcome: ToolOutcome::Interrupted,
        },
        ContextMessage::User {
            text: "Inspect instead".into(),
        },
    ];
    let body: serde_json::Value =
        serde_json::from_str(&exec_agent::providers::deepseek::request_body(&r).unwrap()).unwrap();
    assert_eq!(
        body["messages"][1]["tool_calls"][0]["function"]["arguments"],
        "{\"path\":\"x\"}"
    );
    let text = body["messages"][2]["content"].as_str().unwrap();
    assert!(text.contains("Tool outcome: interrupted") && text.contains("May have had effects"));
}
