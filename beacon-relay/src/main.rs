mod config;
mod error;
mod routes;
mod telemetry;

use tokio::net::TcpListener;
use tokio::signal;

#[tokio::main]
async fn main() {
    let cfg = config::Config::load().expect("failed to load configuration");

    telemetry::init_tracing(&cfg.log.level, &cfg.log.format);

    let app = routes::create_router();
    let addr = cfg.listen_addr();

    let listener = TcpListener::bind(&addr)
        .await
        .expect("failed to bind TCP listener");

    tracing::info!(addr = %addr, "beacon-relay listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }

    tracing::info!("shutdown signal received, starting graceful shutdown");
}
