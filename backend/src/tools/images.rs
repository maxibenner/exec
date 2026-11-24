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
    fn availability(&self, _: &ToolContext) -> RuntimeToolAvailability {
        if self.provider.image_generation_available() {
            RuntimeToolAvailability::available()
        } else {
            RuntimeToolAvailability::unavailable("Connect an image provider.")
        }
    }
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: "generate_image".into(),
            description: "Generate or edit one image using the connected image provider. Only call when the user requests an image or edit. For editing or visual references, pass input_image_ids from this conversation's managed image assets; order is preserved, so describe each image's role in the prompt (image 1, image 2, etc.). Omitted, null or empty inputs generate from text. The prompt and selected image contents are sent to the image provider, which may differ from the chat provider; never include secrets. Uses image quota. Every result is a new immutable managed image, not a workspace file; originals are unchanged. Do not regenerate merely to save a copy, or retry failed/interrupted generation without a new user request.".into(),
            parameters: schema(serde_json::json!({
                "prompt": {"type": "string"},
                "transparent_background": {"type": "boolean"},
                "input_image_ids": {
                    "type": "array", "items": {"type": "string"},
                    "maxItems": self.provider.max_image_generation_inputs(),
                    "description": "Ordered, unique managed image IDs from this conversation. At most 16 MiB total. Do not use paths or URLs."
                }
            }), &["prompt", "transparent_background"]),
        }
    }
    async fn prepare(
        &self,
        args: Arguments,
        context: ToolContext,
    ) -> Result<Box<dyn PreparedTool>> {
        fields(
            &args,
            &["prompt", "transparent_background", "input_image_ids"],
        )?;
        let prompt = string(&args, "prompt", 16 * 1024)?;
        let transparent_background = args
            .get("transparent_background")
            .and_then(serde_json::Value::as_bool)
            .ok_or_else(|| failure("transparent_background must be a boolean."))?;
        let ids = match args.get("input_image_ids") {
            None | Some(serde_json::Value::Null) => &[][..],
            Some(serde_json::Value::Array(ids)) => ids.as_slice(),
            _ => {
                return Err(failure(
                    "input_image_ids must be an array of managed image IDs.",
                ));
            }
        };
        let limit = self.provider.max_image_generation_inputs();
        if ids.len() > limit {
            return Err(failure(if limit == 0 {
                "The selected image provider does not support image inputs.".into()
            } else {
                format!("The selected image provider accepts at most {limit} input images.")
            }));
        }
        let mut selected = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut total_bytes = 0usize;
        for id in ids {
            let id = id
                .as_str()
                .filter(|id| valid_id(id))
                .ok_or_else(|| failure("Each input image must be a managed image ID."))?;
            if !seen.insert(id) {
                return Err(failure("Duplicate input image ID."));
            }
            let image = context
                .available_images
                .iter()
                .find(|image| image.id == id)
                .ok_or_else(|| failure("An input image is not available in this conversation."))?;
            image.validate()?;
            total_bytes = total_bytes.saturating_add(image.byte_count);
            if total_bytes > MAX_IMAGE_GENERATION_INPUT_BYTES {
                return Err(failure("Input images exceed 16 MiB combined."));
            }
            selected.push(image);
        }
        let mut input = ImageGeneration {
            prompt,
            transparent_background,
            input_images: vec![],
        };
        input.validate()?;
        for image in &selected {
            if context.cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            input
                .input_images
                .push(self.images.load(image).await.map_err(|_| {
                    failure("An input image could not be read or failed integrity checks.")
                })?);
        }
        input.validate()?;
        let provider = self
            .provider
            .image_generation_provider_id()
            .unwrap_or_else(|| "the selected image provider".into());
        let references = if selected.is_empty() {
            String::new()
        } else {
            format!(
                "\nReference images sent to {provider} (in order):\n{}\n",
                serde_json::to_string(&selected).expect("image references serialize")
            )
        };
        let approval = format!(
            "Generate an image using {provider}'s image quota.{references}\nPrompt:\n{}",
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
        if self.context.cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
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
