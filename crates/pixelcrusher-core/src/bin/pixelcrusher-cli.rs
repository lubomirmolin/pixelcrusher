use std::io::{self, Read, Write};
use std::path::PathBuf;

use anyhow::{Context, Result};
use pixelcrusher_core::processing::process_file;
use pixelcrusher_core::types::{ProcessOptions, ProcessResult};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
struct ProcessRequest {
    input_path: String,
    output_dir: String,
    #[serde(default)]
    options: ProcessOptions,
}

#[derive(Debug, Serialize)]
struct StatusEvent<'a> {
    r#type: &'a str,
    state: &'a str,
    message: &'a str,
    progress: u8,
}

#[derive(Debug, Serialize)]
struct ResultEvent {
    r#type: &'static str,
    ok: bool,
    result: Option<ProcessResult>,
    error: Option<String>,
}

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
                    let state = if tool.available { "ok" } else { "missing" };
                    let source = tool.source.unwrap_or_else(|| "-".to_string());
                    let kind = tool.source_kind.unwrap_or_else(|| "-".to_string());
                    println!("{:<10} {:<8} {:<20} {}", tool.name, state, kind, source);
                }
            }
        }
        "process" => {
            let as_json = args.any(|arg| arg == "--json");
            if !as_json {
                anyhow::bail!("process currently requires --json and JSON request on stdin");
            }

            let mut input = String::new();
            io::stdin()
                .read_to_string(&mut input)
                .context("failed to read process request from stdin")?;

            let request: ProcessRequest = serde_json::from_str(input.trim())
                .context("failed to decode JSON process request")?;

            emit_status("diagnosing", "Diagnosing input", 10)?;
            emit_status("processing", "Processing image", 45)?;
            emit_status("optimizing", "Optimizing output", 80)?;

            let input_path = PathBuf::from(&request.input_path);
            let output_dir = PathBuf::from(&request.output_dir);

            let result = process_file(input_path.as_path(), output_dir.as_path(), &request.options);

            match result {
                Ok(report) => {
                    emit_status("done", "Done", 100)?;
                    emit_result(ResultEvent {
                        r#type: "result",
                        ok: true,
                        result: Some(report),
                        error: None,
                    })?;
                }
                Err(err) => {
                    emit_status("failed", "Failed", 100)?;
                    emit_result(ResultEvent {
                        r#type: "result",
                        ok: false,
                        result: None,
                        error: Some(err.to_string()),
                    })?;
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

fn emit_status(state: &str, message: &str, progress: u8) -> Result<()> {
    let line = serde_json::to_string(&StatusEvent {
        r#type: "status",
        state,
        message,
        progress,
    })?;
    println!("{line}");
    io::stdout().flush()?;
    Ok(())
}

fn emit_result(event: ResultEvent) -> Result<()> {
    let line = serde_json::to_string(&event)?;
    println!("{line}");
    io::stdout().flush()?;
    Ok(())
}

fn print_usage() {
    println!("pixelcrusher-cli\n");
    println!("Commands:");
    println!("  diagnostics [--json]        Print optimizer tool diagnostics");
    println!("  process --json              Read process request JSON from stdin");
}
