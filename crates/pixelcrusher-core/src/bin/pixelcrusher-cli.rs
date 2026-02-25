use std::io::{self, Read, Write};
use std::path::PathBuf;

use anyhow::{Context, Result};
use pixelcrusher_core::contracts::{
    CliProcessRequest, CliStreamEvent, FinishedPayload, StatusPayload,
};
use pixelcrusher_core::processing::process_asset;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let Some(command) = args.next() else {
        print_usage();
        return Ok(());
    };

    match command.as_str() {
        "diagnostics" => {
            let as_json = args.any(|arg| arg == "--json");
            let diagnostics = pixelcrusher_core::optimizer::diagnostics();
            if as_json {
                println!("{}", serde_json::to_string(&diagnostics)?);
            } else {
                for tool in diagnostics {
                    let state = if tool.is_available { "ok" } else { "missing" };
                    let source = tool.resolved_path.unwrap_or_else(|| "-".to_string());
                    let resolution = tool
                        .resolution
                        .map(|entry| match entry {
                            pixelcrusher_core::model::ToolResolutionKind::EnvironmentOverride => {
                                "environment_override"
                            }
                            pixelcrusher_core::model::ToolResolutionKind::Bundled => "bundled",
                            pixelcrusher_core::model::ToolResolutionKind::HostPath => "host_path",
                        })
                        .unwrap_or("-");
                    println!(
                        "{:<10} {:<8} {:<20} {}",
                        tool.tool, state, resolution, source
                    );
                }
            }
        }
        "process" => {
            let mut input = String::new();
            io::stdin()
                .read_to_string(&mut input)
                .context("failed to read process request from stdin")?;

            let request: CliProcessRequest = serde_json::from_str(input.trim())
                .context("failed to decode JSON process request")?;

            emit_event(CliStreamEvent::Status(StatusPayload {
                phase: "discovery".to_string(),
                message: "Inspecting input".to_string(),
                progress_percent: 10,
            }))?;
            emit_event(CliStreamEvent::Status(StatusPayload {
                phase: "transform".to_string(),
                message: "Transforming image".to_string(),
                progress_percent: 45,
            }))?;
            emit_event(CliStreamEvent::Status(StatusPayload {
                phase: "optimize".to_string(),
                message: "Running optimizer pipeline".to_string(),
                progress_percent: 80,
            }))?;

            let input_path = PathBuf::from(&request.input_path);
            let output_dir = PathBuf::from(&request.output_dir);

            let result =
                process_asset(input_path.as_path(), output_dir.as_path(), &request.options);

            match result {
                Ok(report) => {
                    emit_event(CliStreamEvent::Status(StatusPayload {
                        phase: "complete".to_string(),
                        message: "Done".to_string(),
                        progress_percent: 100,
                    }))?;
                    emit_event(CliStreamEvent::Finished(FinishedPayload {
                        success: true,
                        report: Some(report),
                        error: None,
                    }))?;
                }
                Err(err) => {
                    emit_event(CliStreamEvent::Status(StatusPayload {
                        phase: "failed".to_string(),
                        message: "Failed".to_string(),
                        progress_percent: 100,
                    }))?;
                    emit_event(CliStreamEvent::Finished(FinishedPayload {
                        success: false,
                        report: None,
                        error: Some(err.to_string()),
                    }))?;
                    std::process::exit(1);
                }
            }
        }
        "--help" | "-h" | "help" => print_usage(),
        other => {
            anyhow::bail!("unknown command: {other}");
        }
    }

    Ok(())
}

fn emit_event(event: CliStreamEvent) -> Result<()> {
    let line = serde_json::to_string(&event)?;
    println!("{line}");
    io::stdout().flush()?;
    Ok(())
}

fn print_usage() {
    println!("pixelcrusher-cli\n");
    println!("Commands:");
    println!("  diagnostics [--json]        Print optimizer tool diagnostics");
    println!("  process                     Read process request JSON from stdin");
}
