use exec_agent::{Result, core::*, images::ImageStore, tools::create_image_tools};
use futures_util::stream::BoxStream;
use serde_json::{Value, json};
use std::{io::Cursor, sync::Arc};
use tokio_util::sync::CancellationToken;

struct NoGeneration(usize);
impl ChatProvider for NoGeneration {
    fn supports_image_generation(&self) -> bool {
        true
    }
    fn max_image_generation_inputs(&self) -> usize {
        self.0
    }
    fn stream(&self, _: ProviderRequest) -> BoxStream<'static, Result<ProviderEvent>> {
        panic!("No inference during preparation")
    }
}
fn context(images: Vec<ImageRef>) -> ToolContext {
    ToolContext {
        available_images: images,
        conversation_id: new_id(),
        capture_preview: None,
        operation_id: new_id(),
        call_id: new_id(),
        model: "test".into(),
        search_model: None,
        workspace: String::new(),
        cancel: CancellationToken::new(),
    }
}
fn arguments(ids: Value) -> Arguments {
    json!({"prompt":"edit", "transparent_background":false, "input_image_ids":ids})
        .as_object()
        .unwrap()
        .clone()
}

#[tokio::test]
async fn invalid_inputs_fail_preparation_without_generation() {
    let root = tempfile::tempdir().unwrap();
    let images = ImageStore::open(root.path().join("images")).await.unwrap();
    let mut bytes = Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(2, 2)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    let original = images
        .put(new_id(), "source.png".into(), bytes.into_inner())
        .await
        .unwrap();
    let tool = create_image_tools(Arc::new(NoGeneration(5)), images.clone()).remove(0);
    for ids in [
        json!("not an array"),
        json!([42]),
        json!(["/tmp/source.png"]),
        json!([original.id, original.id]),
        json!(vec![original.id.clone(); 6]),
        json!([new_id()]),
    ] {
        assert!(
            tool.prepare(arguments(ids), context(vec![original.clone()]))
                .await
                .is_err()
        );
    }
    let unsupported = create_image_tools(Arc::new(NoGeneration(0)), images).remove(0);
    assert!(
        unsupported
            .prepare(
                arguments(json!([original.id])),
                context(vec![original.clone()])
            )
            .await
            .is_err()
    );
    for ids in [Value::Null, json!([])] {
        assert!(
            unsupported
                .prepare(arguments(ids), context(vec![]))
                .await
                .is_ok()
        );
    }
    let mut corrupt = original.clone();
    corrupt.sha256 = "0".repeat(64);
    assert!(
        tool.prepare(arguments(json!([corrupt.id])), context(vec![corrupt]))
            .await
            .is_err()
    );
    let oversized: Vec<_> = (0..3)
        .map(|_| {
            let mut image = original.clone();
            image.id = new_id();
            image.byte_count = 8 * 1024 * 1024;
            image
        })
        .collect();
    let ids: Vec<_> = oversized.iter().map(|image| image.id.clone()).collect();
    let error = tool
        .prepare(arguments(json!(ids)), context(oversized))
        .await
        .err()
        .unwrap();
    assert!(matches!(error, exec_agent::Error::Tool(text) if text.contains("16 MiB")));
    let cancelled = context(vec![original.clone()]);
    let prepared = tool
        .prepare(arguments(json!([original.id])), cancelled.clone())
        .await
        .unwrap();
    cancelled.cancel.cancel();
    assert!(matches!(
        prepared.execute_output().await,
        Err(exec_agent::Error::Cancelled)
    ));
}
