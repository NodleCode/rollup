use axum::{routing::get, Router};
use tower_http::trace::TraceLayer;

mod health;

pub fn create_router() -> Router {
    Router::new()
        .route("/healthz", get(health::healthz))
        .layer(TraceLayer::new_for_http())
}
