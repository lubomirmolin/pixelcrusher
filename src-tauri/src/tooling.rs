use pixelcrusher_core::model::{ToolAvailability, ToolResolutionKind};

use crate::models::ToolStatusSnapshot;

pub(crate) fn map_tool_status(tool: ToolAvailability) -> ToolStatusSnapshot {
    let source_kind = tool.resolution.map(|resolution| match resolution {
        ToolResolutionKind::EnvironmentOverride => "environment_override".to_string(),
        ToolResolutionKind::Bundled => "bundled".to_string(),
        ToolResolutionKind::HostPath => "host_path".to_string(),
    });

    ToolStatusSnapshot {
        name: tool.tool,
        available: tool.is_available,
        source: tool.resolved_path,
        source_kind,
    }
}
