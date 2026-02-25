use std::path::Path;

use crate::constants::SUPPORTED_IMAGE_EXTENSIONS;

pub(crate) fn is_supported_image_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            let lowered = extension.to_ascii_lowercase();
            SUPPORTED_IMAGE_EXTENSIONS
                .iter()
                .any(|supported| *supported == lowered)
        })
        .unwrap_or(false)
}
