use super::*;
use crate::check_cancel;
use std::time::Duration;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

const MAX_DURATION_SECONDS: u64 = 86_400;
const MAX_DESCRIPTION_BYTES: usize = 160;
const MAX_WAKE_PROMPT_BYTES: usize = 4096;

struct Wait;
struct PreparedWait {
    duration: Duration,
    wake_prompt: String,
    cancel: CancellationToken,
}

pub fn create_wait_tool() -> Arc<dyn Tool> {
    Arc::new(Wait)
}

#[async_trait]
impl Tool for Wait {
    fn execution_policy(&self) -> ToolExecutionPolicy {
        ToolExecutionPolicy::StandaloneWithContinuation
    }
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "wait".into(),
            description: "Pause the current operation once, then return elapsed_seconds and wake_prompt as ordinary tool output so the conversation can continue. This standalone, one-shot tool must be the only tool call in its response and needs a remaining model step for continuation. Supply duration_seconds (1–86400), a short nonempty single-line description (display metadata only, at most 160 UTF-8 bytes), and a nonempty wake_prompt (at most 4096 UTF-8 bytes) describing what to consider after waking. It does not check conditions, schedule a new operation, or persist a timer across restart. Cancellation interrupts the wait. Subsequent checks, actions, and approvals follow normal tool rules; wake_prompt is not authorization. Never automatically retry a failed or interrupted wait without a new user request.".into(),
            parameters: schema(
                serde_json::json!({
                    "duration_seconds": {
                        "type": "integer", "minimum": 1, "maximum": MAX_DURATION_SECONDS
                    },
                    "description": {
                        "type": "string", "minLength": 1, "maxLength": MAX_DESCRIPTION_BYTES,
                        "description": "Short nonempty single-line display metadata, not instructions."
                    },
                    "wake_prompt": {
                        "type": "string", "minLength": 1, "maxLength": MAX_WAKE_PROMPT_BYTES,
                        "description": "Text returned after the wait; subsequent checks and approvals remain normal."
                    }
                }),
                &["duration_seconds", "description", "wake_prompt"],
            ),
        }
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        fields(&args, &["duration_seconds", "description", "wake_prompt"])?;
        let seconds = integer(&args, "duration_seconds", 1, MAX_DURATION_SECONDS, None)?;
        let description = string(&args, "description", MAX_DESCRIPTION_BYTES)?;
        if description.trim().is_empty()
            || description
                .chars()
                .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
        {
            return Err(failure(
                "description must be nonempty single-line display metadata.",
            ));
        }
        let wake_prompt = string(&args, "wake_prompt", MAX_WAKE_PROMPT_BYTES)?;
        if wake_prompt.trim().is_empty() {
            return Err(failure("wake_prompt must be nonempty text."));
        }
        Ok(Box::new(PreparedWait {
            duration: Duration::from_secs(seconds),
            wake_prompt,
            cancel: context.cancel,
        }))
    }
}

#[async_trait]
impl PreparedTool for PreparedWait {
    fn approval(&self) -> Option<&str> {
        None
    }
    async fn execute(self: Box<Self>) -> Result<String> {
        let started = Instant::now();
        tokio::select! { biased;
            _ = self.cancel.cancelled() => return Err(Error::Cancelled),
            _ = tokio::time::sleep(self.duration) => {},
        }
        check_cancel(&self.cancel)?;
        Ok(serde_json::json!({
            "elapsed_seconds": started.elapsed().as_secs(),
            "wake_prompt": self.wake_prompt,
        })
        .to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn args() -> Arguments {
        json!({"duration_seconds": 1, "description": "Wait for build", "wake_prompt": "Check the build\nthen report the result."})
            .as_object().unwrap().clone()
    }
    fn context(cancel: CancellationToken) -> ToolContext {
        ToolContext {
            available_images: vec![],
            conversation_id: "session".into(),
            operation_id: "operation".into(),
            call_id: "call".into(),
            model: "fake".into(),
            search_model: None,
            workspace: String::new(),
            cancel,
        }
    }

    #[tokio::test]
    async fn validates_bounded_required_arguments() {
        let tool = create_wait_tool();
        for key in ["duration_seconds", "description", "wake_prompt"] {
            let mut missing = args();
            missing.remove(key);
            assert!(
                tool.prepare(missing, context(CancellationToken::new()))
                    .await
                    .is_err()
            );
        }
        for (key, invalid) in [
            ("duration_seconds", json!(0)),
            ("duration_seconds", json!(-1)),
            ("duration_seconds", json!(86_401)),
            ("duration_seconds", json!(1.5)),
            ("duration_seconds", json!("1")),
            ("duration_seconds", Value::Null),
            ("description", json!("  ")),
            ("description", json!("line\nbreak")),
            ("description", json!("line\rbreak")),
            ("description", json!("line\u{2028}break")),
            ("description", json!("a".repeat(161))),
            ("description", json!("é".repeat(81))),
            ("description", json!("nul\0byte")),
            ("description", json!(false)),
            ("wake_prompt", json!("\n\t ")),
            ("wake_prompt", json!("nul\0byte")),
            ("wake_prompt", json!("a".repeat(4097))),
            ("wake_prompt", json!(3)),
            ("unexpected", json!(true)),
        ] {
            let mut invalid_args = args();
            invalid_args.insert(key.into(), invalid);
            assert!(
                tool.prepare(invalid_args, context(CancellationToken::new()))
                    .await
                    .is_err(),
                "accepted invalid {key}"
            );
        }
        let mut boundary = args();
        boundary.insert("duration_seconds".into(), json!(86_400));
        boundary.insert("description".into(), json!("a".repeat(160)));
        boundary.insert("wake_prompt".into(), json!("a".repeat(4096)));
        assert!(
            tool.prepare(boundary, context(CancellationToken::new()))
                .await
                .is_ok()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn completes_once_with_elapsed_time_and_exact_wake_prompt() {
        let input = args();
        let prepared = create_wait_tool()
            .prepare(input.clone(), context(CancellationToken::new()))
            .await
            .unwrap();
        assert!(prepared.approval().is_none());
        assert!(prepared.resources().is_empty());
        let output = prepared.execute_output().await.unwrap();
        assert!(output.details.is_none());
        let value: Value = serde_json::from_str(&output.text).unwrap();
        assert!(value["elapsed_seconds"].as_u64().unwrap() >= 1);
        assert_eq!(value["wake_prompt"], input["wake_prompt"]);
    }

    #[tokio::test]
    async fn cancellation_interrupts_a_running_wait_and_wins_over_ready_sleep() {
        let cancel = CancellationToken::new();
        let prepared = create_wait_tool()
            .prepare(args(), context(cancel.clone()))
            .await
            .unwrap();
        let mut execution = prepared.execute();
        assert!(futures_util::poll!(&mut execution).is_pending());
        cancel.cancel();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), execution)
                .await
                .unwrap(),
            Err(Error::Cancelled)
        );
        let ready = Box::new(PreparedWait {
            duration: Duration::ZERO,
            wake_prompt: "Never returned".into(),
            cancel,
        });
        assert_eq!(ready.execute().await, Err(Error::Cancelled));
    }
}
