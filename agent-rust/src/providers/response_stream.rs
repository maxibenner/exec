use crate::{Error, ProviderFailure, Result};
use bytes::Bytes;
use futures_util::{StreamExt, stream::BoxStream};
pub type ByteStream = BoxStream<'static, Result<Bytes>>;
fn invalid() -> Error {
    Error::Provider(ProviderFailure::Response)
}
/// Bounded framing only. No reconnection, inference retry, or EOF completion.
pub fn read_sse(mut bytes: ByteStream) -> BoxStream<'static, Result<String>> {
    Box::pin(async_stream::try_stream! {
        let mut line=Vec::new();let mut data=Vec::new();let mut event_bytes=0;let mut total=0;let mut skip_lf=false;let mut first=true;
        while let Some(chunk)=bytes.next().await{let chunk=chunk?;total+=chunk.len();if total>16*1024*1024{Err(invalid())?;}
            for byte in chunk{if skip_lf{skip_lf=false;if byte==b'\n'{continue;}}
                event_bytes+=1;if event_bytes>256*1024{Err(invalid())?;}
                if byte!=b'\r'&&byte!=b'\n'{line.push(byte);continue;}
                skip_lf=byte==b'\r';let mut text=std::str::from_utf8(&line).map_err(|_|invalid())?;
                if first{first=false;text=text.strip_prefix('\u{feff}').unwrap_or(text);}
                if text.is_empty(){if !data.is_empty(){yield data.join("\n");}data.clear();event_bytes=0;}
                else{let (field,value)=text.split_once(':').unwrap_or((text,""));if field=="data"{data.push(value.strip_prefix(' ').unwrap_or(value).to_owned());}}
                line.clear();
            }
        }
        std::str::from_utf8(&line).map_err(|_|invalid())?;
    })
}
pub async fn read_json(mut bytes: ByteStream) -> Result<serde_json::Value> {
    let mut data = vec![];
    while let Some(chunk) = bytes.next().await {
        let chunk = chunk?;
        if data.len() + chunk.len() > 128 * 1024 {
            return Err(invalid());
        }
        data.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&data).map_err(|_| invalid())
}
