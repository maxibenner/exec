use super::*;
use crate::{check_cancel, manager::AgentManager};
use std::sync::Weak;

struct Delegate {
    manager: Weak<AgentManager>,
    provider: Arc<dyn ChatProvider>,
    tools: Vec<Arc<dyn Tool>>,
}
pub(crate) fn create_delegate_tool(
    manager: &Arc<AgentManager>,
    provider: Arc<dyn ChatProvider>,
    tools: Vec<Arc<dyn Tool>>,
) -> Arc<dyn Tool> {
    Arc::new(Delegate {
        manager: Arc::downgrade(manager),
        provider,
        tools,
    })
}
#[async_trait]
impl Tool for Delegate {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "delegate".into(),
            description: "Delegate a bounded task to a new sub-agent session and wait for its final response. The child inherits this session's model, workspace, instructions and approval policy, but not its transcript. Supply all necessary context in task. Child tools use normal approvals. Sessions share files; this is not filesystem isolation. Sub-agents cannot delegate, have at most 16 model steps, and at most eight may be created per parent turn. Cancellation stops the child. Results are bounded; inspect the child session for the full transcript. Do not retry failed or interrupted delegation without a new user request.".into(),
            parameters: schema(serde_json::json!({"task":{"type":"string"}}), &["task"]),
        }
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        fields(&args, &["task"])?;
        let task = string(&args, "task", 16 * 1024)?;
        if task.trim().is_empty() {
            return Err(failure("Delegation requires a nonempty task."));
        }
        let manager = self.manager.upgrade().ok_or(Error::Internal)?;
        if manager.get(&context.conversation_id)?.parent().is_some() {
            return Err(failure("Sub-agents cannot delegate."));
        }
        let provider = self.provider.clone();
        let tools = self.tools.clone();
        Ok(Box::new(Action {
            resources: vec![],
            details: None,
            approval: None,
            execute: Box::new(move || {
                Box::pin(async move {
                    let (child, instructions) = manager
                        .create_child(&context, &task, provider, tools)
                        .await?;
                    check_cancel(&context.cancel)?;
                    // No automatic title inference and no inherited provider context.
                    let mut submission = child.submit_with_instructions(task, instructions)?;
                    let operation = tokio::select! { biased;
                        _ = context.cancel.cancelled() => {
                            child.cancel(&submission.operation_id);
                            // Keep owning the child until its tools have finished cleanup.
                            let _ = submission.completion.await;
                            return Err(Error::Cancelled);
                        }
                        result = &mut submission.completion => result.map_err(|_| Error::Internal)?,
                    };
                    check_cancel(&context.cancel)?;
                    if operation.state != OperationState::Completed {
                        return Err(failure(format!(
                            "Sub-agent session {} {}. It may have had effects; inspect its transcript.",
                            child.id,
                            if operation.state == OperationState::Interrupted {
                                "was interrupted"
                            } else {
                                "failed"
                            }
                        )));
                    }
                    let snapshot = child.snapshot();
                    let answer = snapshot
                        .messages
                        .iter()
                        .rev()
                        .find_map(|message| match message {
                            Message::Assistant {
                                text,
                                calls,
                                status: MessageStatus::Completed,
                                ..
                            } if calls.is_empty() => Some(text.as_str()),
                            _ => None,
                        })
                        .unwrap_or("");
                    let mut end = answer.len().min(32 * 1024);
                    while !answer.is_char_boundary(end) {
                        end -= 1;
                    }
                    let truncated = if end < answer.len() {
                        "\n[Response truncated; open the child session for the full response.]"
                    } else {
                        ""
                    };
                    Ok(format!(
                        "Child session: {}\n\n{}{}",
                        child.id,
                        &answer[..end],
                        truncated
                    ))
                })
            }),
        }))
    }
}
