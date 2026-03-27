use tracing_subscriber::{fmt, EnvFilter};

pub fn init_tracing(level: &str, format: &str) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(level));

    match format {
        "json" => {
            fmt().with_env_filter(filter).json().init();
        }
        _ => {
            fmt().with_env_filter(filter).init();
        }
    }
}
