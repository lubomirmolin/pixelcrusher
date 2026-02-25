use std::collections::HashMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::{OnceLock, RwLock};

use crate::model::{ToolAvailability, ToolResolutionKind};

const REQUIRED_TOOLS: [&str; 5] = ["cjpeg", "pngquant", "pngcrush", "svgo", "gifsicle"];
const OPTIONAL_TOOLS: [&str; 2] = ["zopflipng", "pngout"];

static RUNTIME_BUNDLED_TOOLS_DIR: OnceLock<RwLock<Option<PathBuf>>> = OnceLock::new();

pub fn set_runtime_bundled_tools_dir(path: Option<PathBuf>) {
    let lock = RUNTIME_BUNDLED_TOOLS_DIR.get_or_init(|| RwLock::new(None));
    if let Ok(mut guard) = lock.write() {
        *guard = path;
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedTool {
    pub executable: PathBuf,
    pub source: ToolResolutionKind,
}

#[derive(Debug, Clone)]
pub struct ToolResolver {
    environment: HashMap<String, String>,
    search_paths: Vec<PathBuf>,
    bundled_tools_dir: Option<PathBuf>,
}

impl ToolResolver {
    #[cfg(test)]
    pub fn new(
        environment: HashMap<String, String>,
        search_paths: Vec<PathBuf>,
        bundled_tools_dir: Option<PathBuf>,
    ) -> Self {
        Self {
            environment,
            search_paths,
            bundled_tools_dir,
        }
    }

    pub fn from_process_environment() -> Self {
        let environment: HashMap<String, String> = std::env::vars().collect();
        let search_paths = environment
            .get("PATH")
            .map(|v| std::env::split_paths(v).collect::<Vec<_>>())
            .unwrap_or_default();

        let bundled_tools_dir = default_bundled_tools_dir(&environment);

        Self {
            environment,
            search_paths,
            bundled_tools_dir,
        }
    }

    pub fn detect_statuses(&self) -> Vec<ToolAvailability> {
        REQUIRED_TOOLS
            .iter()
            .chain(OPTIONAL_TOOLS.iter())
            .map(|tool_name| {
                let resolved = self.resolve_named(tool_name);
                ToolAvailability {
                    tool: (*tool_name).to_string(),
                    is_available: resolved.is_some(),
                    resolved_path: resolved
                        .as_ref()
                        .map(|entry| entry.executable.display().to_string()),
                    resolution: resolved.map(|entry| entry.source),
                }
            })
            .collect()
    }

    pub fn resolve_named(&self, tool_name: &str) -> Option<ResolvedTool> {
        if let Some(override_path) = self.environment_override(tool_name)
            && is_executable(&override_path)
        {
            return Some(ResolvedTool {
                executable: override_path,
                source: ToolResolutionKind::EnvironmentOverride,
            });
        }

        if let Some(bundled) = self.find_bundled(tool_name) {
            return Some(ResolvedTool {
                executable: bundled,
                source: ToolResolutionKind::Bundled,
            });
        }

        if let Some(host) = self.find_on_host_path(tool_name) {
            return Some(ResolvedTool {
                executable: host,
                source: ToolResolutionKind::HostPath,
            });
        }

        None
    }

    fn environment_override(&self, tool_name: &str) -> Option<PathBuf> {
        let key = format!(
            "PIXELCRUSHER_{}_PATH",
            tool_name.to_ascii_uppercase().replace('-', "_")
        );

        self.environment
            .get(&key)
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
    }

    fn find_bundled(&self, tool_name: &str) -> Option<PathBuf> {
        let root = self.bundled_tools_dir.as_ref()?;
        for candidate_name in candidate_executable_names(tool_name) {
            let candidate = root.join("bin").join(candidate_name);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }

        None
    }

    fn find_on_host_path(&self, tool_name: &str) -> Option<PathBuf> {
        if let Ok(found) = which::which(tool_name) {
            return Some(found);
        }

        for dir in &self.search_paths {
            for candidate_name in candidate_executable_names(tool_name) {
                let candidate = dir.join(candidate_name);
                if is_executable(&candidate) {
                    return Some(candidate);
                }
            }
        }

        None
    }
}

fn candidate_executable_names(tool_name: &str) -> Vec<String> {
    #[cfg(windows)]
    {
        vec![
            tool_name.to_string(),
            format!("{tool_name}.exe"),
            format!("{tool_name}.cmd"),
            format!("{tool_name}.bat"),
        ]
    }

    #[cfg(not(windows))]
    {
        vec![tool_name.to_string()]
    }
}

fn runtime_bundled_tools_dir_override() -> Option<PathBuf> {
    let lock = RUNTIME_BUNDLED_TOOLS_DIR.get_or_init(|| RwLock::new(None));
    lock.read().ok().and_then(|guard| guard.clone())
}

fn default_bundled_tools_dir(environment: &HashMap<String, String>) -> Option<PathBuf> {
    if let Some(override_dir) = environment.get("PIXELCRUSHER_BUNDLED_TOOLS_DIR")
        && !override_dir.trim().is_empty()
    {
        let path = PathBuf::from(override_dir);
        if path.exists() {
            return Some(path);
        }
    }

    if let Some(override_path) = runtime_bundled_tools_dir_override()
        && override_path.exists()
    {
        return Some(override_path);
    }

    if let Ok(current_exe) = std::env::current_exe()
        && let Some(parent) = current_exe.parent()
    {
        let mut candidates = vec![
            parent.join("../Resources/BundledTools"),
            parent.join("resources/BundledTools"),
        ];

        if let Some(executable_stem) = current_exe.file_stem().and_then(|s| s.to_str()) {
            candidates.push(
                parent
                    .join("../lib")
                    .join(executable_stem)
                    .join("resources/BundledTools"),
            );
        }

        for candidate in candidates {
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };

    if !metadata.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        let mode = metadata.permissions().mode();
        mode & 0o111 != 0
    }

    #[cfg(not(unix))]
    {
        true
    }
}
