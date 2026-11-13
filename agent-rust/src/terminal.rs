use crate::core::*;
use std::collections::{HashMap, HashSet};
pub fn terminal_text(text: &str) -> String {
    text.chars()
        .map(|c| match c as u32 {
            0..=8
            | 11..=31
            | 127..=159
            | 0x200b..=0x200f
            | 0x202a..=0x202e
            | 0x2060..=0x206f
            | 0xfeff => format!("\\u{{{:x}}}", c as u32),
            _ => c.to_string(),
        })
        .collect()
}
#[derive(Default)]
pub struct Transcript {
    lengths: HashMap<String, usize>,
    texts: HashMap<String, String>,
    approvals: HashSet<String>,
    terminal_operations: HashSet<String>,
}
impl Transcript {
    pub fn snapshot(&mut self, snapshot: &ConversationSnapshot) -> String {
        let mut output = String::new();
        for message in snapshot.messages.iter().chain(&snapshot.pending_input) {
            let previous = self.lengths.entry(message.id().into()).or_insert_with(|| {
                let role = match message {
                    Message::User { .. } => "user".into(),
                    Message::Assistant { .. } => "assistant".into(),
                    Message::Tool { outcome, .. } => format!(
                        "tool: {}",
                        serde_json::to_value(outcome).unwrap().as_str().unwrap()
                    ),
                };
                output.push_str(&format!("\n[{role}]\n"));
                0
            });
            let prior = self.texts.entry(message.id().into()).or_default();
            if message.text().starts_with(prior.as_str()) {
                output.push_str(&terminal_text(&message.text()[prior.len()..]));
            } else {
                output.push_str("\n[message revised]\n");
                output.push_str(&terminal_text(message.text()));
            }
            *prior = message.text().to_owned();
            *previous = message.text().len();
        }
        if let Some(approval) = &snapshot.approval
            && self.approvals.insert(approval.id.clone())
        {
            output.push_str(&format!(
                "\n\n[Approval {}]\nOperation: {}\nWorkspace: {}\n{}\n",
                approval.id,
                approval.operation_id,
                terminal_text(&approval.workspace),
                terminal_text(&approval.description)
            ));
        }
        if let Some(op) = &snapshot.operation
            && !op.state.active()
            && self.terminal_operations.insert(op.id.clone())
        {
            output.push_str(&format!(
                "\n[{}]{}\n",
                serde_json::to_value(op.state).unwrap().as_str().unwrap(),
                op.error
                    .as_ref()
                    .map(|e| format!(" {}", terminal_text(e)))
                    .unwrap_or_default()
            ));
        }
        if let Some(error) = &snapshot.storage_error {
            output.push_str(&format!("\n{}\n", terminal_text(error)));
        }
        output
    }
    pub fn delta(&mut self, id: &str, delta: &str) -> String {
        let mut output = String::new();
        let length = self.lengths.entry(id.into()).or_insert_with(|| {
            output.push_str("\n[assistant]\n");
            0
        });
        output.push_str(&terminal_text(delta));
        *length += delta.len();
        self.texts.entry(id.into()).or_default().push_str(delta);
        output
    }
    pub fn frame(&mut self, frame: &ServiceEvent) -> String {
        match frame {
            ServiceEvent::Snapshot { snapshot }
            | ServiceEvent::Runtime {
                snapshot: Some(snapshot),
                ..
            } => self.snapshot(snapshot),
            ServiceEvent::Runtime {
                event:
                    RuntimeEvent {
                        kind: EventKind::Text { message_id, delta },
                        ..
                    },
                ..
            } => self.delta(message_id, delta),
            _ => String::new(),
        }
    }
}
