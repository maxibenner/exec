use super::*;
use crate::{check_cancel, manager::AgentManager};
use std::sync::Weak;

async fn run_child(
    child: Arc<Conversation>,
    task: String,
    instructions: Option<String>,
    cancel: tokio_util::sync::CancellationToken,
    limit: usize,
) -> Result<String> {
    check_cancel(&cancel)?;
    // No automatic title inference and no inherited provider context.
    let mut submission = child.submit_with_instructions(task, instructions)?;
    let operation = tokio::select! { biased;
        _ = cancel.cancelled() => {
            child.cancel(&submission.operation_id);
            // Keep owning the child until its tools have finished cleanup.
            let _ = submission.completion.await;
            return Err(Error::Cancelled);
        }
        result = &mut submission.completion => result.map_err(|_| Error::Internal)?,
    };
    check_cancel(&cancel)?;
    if operation.state != OperationState::Completed {
        return Err(failure(format!(
            "Sub-agent session {} {}. It may have had effects. Its session is removed after this result is saved.",
            child.id,
            if operation.state == OperationState::Interrupted {
                "was cancelled by user"
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
    let mut end = answer.len().min(limit);
    while !answer.is_char_boundary(end) {
        end -= 1;
    }
    let truncated = if end < answer.len() {
        "\n[Response truncated to the delegation output limit.]"
    } else {
        ""
    };
    Ok(format!(
        "Child session: {}\n\n{}{}",
        child.id,
        &answer[..end],
        truncated
    ))
}

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
        let parameters = schema(
            serde_json::json!({
            "task": {"type": "string"},
            "title": title_schema(),
            "tasks": {
                "type": "array", "minItems": 1, "maxItems": 8,
                "items": {
                    "type": "object",
                    "properties": {"task": {"type": "string"}, "title": title_schema()},
                    "required": ["task", "title"],
                    "additionalProperties": false
                }
            }
            }),
            &[],
        );
        ToolDefinition {
            name: "delegate".into(),
            description: "Delegate tasks to sub-agent sessions and wait for their final responses. Supply one task with a required concise title, or a tasks array of {task, title} objects to run up to eight independent tasks concurrently in one call. Use a super concise title (2–5 words, at most 60 characters) describing what each child will do. Titles must be nonempty and single-line. Each child inherits this session's model, workspace, instructions and approval policy, but not its transcript. Supply all necessary context in each task. Child tools use normal approvals. Sessions share files; this is not filesystem isolation: avoid conflicting edits. Sub-agents cannot delegate. Each session has its own independent model-step budget (128 steps per turn); child steps do not consume the parent or sibling budgets. At most eight sub-agents may be created per parent turn. Cancellation stops all children and waits for cleanup. Results are bounded and returned in task order. Child sessions are deleted after their results, including failures and user cancellations, are saved in this session. A failed child does not retry or cancel siblings. Do not retry failed or interrupted delegation without a new user request.".into(),
            parameters,
        }
    }
    async fn result_saved(&self, conversation_id: &str, call_id: &str) -> Result<()> {
        let manager = self.manager.upgrade().ok_or(Error::Internal)?;
        let children = manager.list()?;
        for child in children {
            if child.metadata.parent.as_ref().is_some_and(|parent| {
                parent.session_id == conversation_id && parent.tool_call_id == call_id
            }) && child
                .operation
                .as_ref()
                .is_some_and(|op| !op.state.active())
            {
                manager
                    .delete_returned_child(&child.id, conversation_id, call_id)
                    .await?;
            }
        }
        Ok(())
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        fields(&args, &["task", "title", "tasks"])?;
        let tasks = match (args.get("task"), args.get("tasks")) {
            (Some(_), None) => vec![parse_task(&args)?],
            (None, Some(value)) if !args.contains_key("title") => {
                let values = value
                    .as_array()
                    .ok_or_else(|| failure("tasks must be an array."))?;
                if values.is_empty() || values.len() > 8 {
                    return Err(failure("Delegation requires one to eight tasks."));
                }
                values
                    .iter()
                    .map(|value| {
                        let task = value.as_object().ok_or_else(|| {
                            failure("Each task must be an object with task and title.")
                        })?;
                        fields(task, &["task", "title"])?;
                        parse_task(task)
                    })
                    .collect::<Result<Vec<_>>>()?
            }
            _ => return Err(failure("Supply exactly one of task or tasks.")),
        };
        let (tasks, titles): (Vec<_>, Vec<_>) = tasks.into_iter().unzip();
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
                    let children = manager
                        .create_children(&context, &titles, provider, tools)
                        .await?;
                    let limit = 32 * 1024 / children.len();
                    // join_all retains every executor through cancellation and cleanup;
                    // never fail fast and abandon a sibling that may have had effects.
                    let executions =
                        children
                            .into_iter()
                            .zip(tasks)
                            .map(|((child, instructions), task)| {
                                run_child(child, task, instructions, context.cancel.clone(), limit)
                            });
                    let results = futures_util::future::join_all(executions).await;
                    check_cancel(&context.cancel)?;
                    if results.len() == 1 {
                        return results.into_iter().next().ok_or(Error::Internal)?;
                    }
                    Ok(results.into_iter().enumerate().map(|(index, result)| {
                        let text = result.unwrap_or_else(|error| match error {
                            Error::Tool(message) => format!("{message}\nDo not retry without a new user request."),
                            _ => "Sub-agent failed or was interrupted; it may have had effects. Inspect child sessions. Do not retry without a new user request.".into(),
                        });
                        format!("Task {}\n{text}", index + 1)
                    }).collect::<Vec<_>>().join("\n\n"))
                })
            }),
        }))
    }
}

fn title_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "string", "minLength": 1, "maxLength": 60,
        "description": "Super concise title describing the sub-agent task: use 2–5 words, at most 60 characters, on one line without control characters."
    })
}

fn parse_task(args: &Arguments) -> Result<(String, String)> {
    let task = string(args, "task", 16 * 1024)?;
    if task.trim().is_empty() {
        return Err(failure("Each task must be nonempty."));
    }
    let title = args
        .get("title")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| failure("Each task requires a string title."))?;
    if title.trim().is_empty()
        || title.chars().count() > 60
        || title
            .chars()
            .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
    {
        return Err(failure(
            "Each title must be nonempty, single-line, contain no control characters, and be at most 60 characters.",
        ));
    }
    Ok((task, title.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_preserve_explicit_text_and_count_characters_not_bytes() {
        for title in ["X".to_owned(), "é".repeat(60)] {
            let args = serde_json::json!({"task": "A longer task, not the title", "title": title});
            let (task, saved_title) = parse_task(args.as_object().unwrap()).unwrap();
            assert_eq!(task, "A longer task, not the title");
            assert_eq!(saved_title, title);
        }
    }
}
