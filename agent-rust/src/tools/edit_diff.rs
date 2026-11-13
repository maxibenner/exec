//! A single exact replacement needs only one contextual hunk, not a diff framework.
pub(super) fn edit_diff(path: &str, before: &str, after: &str) -> (String, bool) {
    let old: Vec<_> = before.split_inclusive('\n').collect();
    let new: Vec<_> = after.split_inclusive('\n').collect();
    let prefix = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let suffix = old[prefix..]
        .iter()
        .rev()
        .zip(new[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let start = prefix.saturating_sub(3);
    let old_end = (old.len() - suffix + 3).min(old.len());
    let new_end = (new.len() - suffix + 3).min(new.len());
    let old_count = old_end - start;
    let new_count = new_end - start;
    let quote = |name: String| serde_json::to_string(&name).unwrap();
    let mut diff = format!(
        "--- {}\n+++ {}\n@@ -{},{} +{},{} @@\n",
        quote(format!("a/{path}")),
        quote(format!("b/{path}")),
        if old_count == 0 { start } else { start + 1 },
        old_count,
        if new_count == 0 { start } else { start + 1 },
        new_count
    );
    let mut line = |prefix: char, text: &str| {
        diff.push(prefix);
        diff.push_str(text);
        if !text.ends_with('\n') {
            diff.push_str("\n\\ No newline at end of file\n");
        }
    };
    for text in &old[start..prefix] {
        line(' ', text);
    }
    for text in &old[prefix..old.len() - suffix] {
        line('-', text);
    }
    for text in &new[prefix..new.len() - suffix] {
        line('+', text);
    }
    for text in &old[old.len() - suffix..old_end] {
        line(' ', text);
    }
    let truncated = diff.len() > 65536;
    if truncated {
        let mut end = 65536;
        while !diff.is_char_boundary(end) {
            end -= 1;
        }
        diff.truncate(end);
        diff.push_str("\n[Diff preview truncated; not a complete patch.]\n");
    }
    (diff, truncated)
}
