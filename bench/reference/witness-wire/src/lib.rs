pub mod direct;
use serde_json::Value as Json;
pub const MAX_BYTES: usize = 256 << 20;
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
