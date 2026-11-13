use super::*;
use crate::images::ImageStore;
struct GenerateImage {
    provider: Arc<dyn ChatProvider>,
    images: Arc<ImageStore>,
}
pub fn create_image_tools(
    provider: Arc<dyn ChatProvider>,
    images: Arc<ImageStore>,
) -> Vec<Arc<dyn Tool>> {
    if provider.supports_image_generation() {
        vec![Arc::new(GenerateImage { provider, images })]
    } else {
        vec![]
    }
}
struct PreparedImage {
    provider: Arc<dyn ChatProvider>,
    images: Arc<ImageStore>,
    id: String,
    input: ImageGeneration,
    context: ToolContext,
    approval: String,
}
#[async_trait]
impl Tool for GenerateImage {
    fn available(&self, _: &ToolContext) -> bool {
        self.provider.image_generation_available()
    }
    fn definition(&self) -> ToolDefinition {
        ToolDefinition{name:"generate_image".into(),description:"Generate one image using the connected image-generation subscription. Only call when the user requests an image. The prompt is sent to the provider; never include secrets. Uses image quota. The result is an immutable managed image, not a workspace file. Do not modify it, regenerate merely to save a copy, or retry failed/interrupted generation without a new user request.".into(),parameters:schema(serde_json::json!({"prompt":{"type":"string"},"transparent_background":{"type":"boolean"}}),&["prompt","transparent_background"])}
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        fields(&args, &["prompt", "transparent_background"])?;
        let prompt = string(&args, "prompt", 16 * 1024)?;
        let transparent_background = args
            .get("transparent_background")
            .and_then(serde_json::Value::as_bool)
            .ok_or_else(|| failure("transparent_background must be a boolean."))?;
        let input = ImageGeneration {
            prompt,
            transparent_background,
        };
        input.validate()?;
        let approval = format!(
            "Generate an image using the selected provider’s image quota. Prompt:\n{}",
            input.prompt
        );
        Ok(Box::new(PreparedImage {
            provider: self.provider.clone(),
            images: self.images.clone(),
            id: new_id(),
            input,
            context,
            approval,
        }))
    }
}
#[async_trait]
impl PreparedTool for PreparedImage {
    fn approval(&self) -> Option<&str> {
        Some(&self.approval)
    }
    fn resources(&self) -> Vec<ResourceRef> {
        vec![ResourceRef {
            id: self.id.clone(),
            call_id: self.context.call_id.clone(),
            kind: ResourceKind::Image,
        }]
    }
    async fn execute(self: Box<Self>) -> Result<String> {
        Ok(self.execute_output().await?.text)
    }
    async fn execute_output(self: Box<Self>) -> Result<ToolOutput> {
        let generated = self
            .provider
            .generate_image(self.input, self.context.cancel)
            .await?;
        let image = self
            .images
            .put(self.id, "Generated image".into(), generated.bytes)
            .await?;
        let text = format!(
            "Generated image asset {} ({}×{}, {}). Managed source is read-only; use the image asset API to read/copy it. No workspace file was created.",
            image.id, image.width, image.height, image.media_type
        );
        Ok(ToolOutput {
            text,
            details: Some(ToolDetails::Image {
                image,
                origin: "generated".into(),
            }),
        })
    }
}
