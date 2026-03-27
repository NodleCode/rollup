use axum::http::StatusCode;
use http_body_util::BodyExt;
use tower::ServiceExt;

#[tokio::test]
async fn test_healthz_returns_200() {
    let app = beacon_relay::routes::create_router();

    let request = axum::http::Request::builder()
        .method("GET")
        .uri("/healthz")
        .body(axum::body::Body::empty())
        .expect("failed to build request");

    let response = app
        .oneshot(request)
        .await
        .expect("failed to execute request");

    assert_eq!(response.status(), StatusCode::OK);

    let body = response
        .into_body()
        .collect()
        .await
        .expect("failed to read body")
        .to_bytes();

    let json: serde_json::Value =
        serde_json::from_slice(&body).expect("response is not valid JSON");

    assert_eq!(json["status"], "ok");
}

#[tokio::test]
async fn test_unknown_route_returns_404() {
    let app = beacon_relay::routes::create_router();

    let request = axum::http::Request::builder()
        .method("GET")
        .uri("/nonexistent")
        .body(axum::body::Body::empty())
        .expect("failed to build request");

    let response = app
        .oneshot(request)
        .await
        .expect("failed to execute request");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
