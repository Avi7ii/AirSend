use axum::{
    extract::DefaultBodyLimit, routing::{get, post}, Extension, Json, Router
};
use tower_http::limit::RequestBodyLimitLayer;
use std::net::SocketAddr;
use tokio::net::TcpListener;

use crate::{discovery::http::register_device, transfer::upload::{register_prepare_upload, register_upload}, Client};

impl Client {
    pub async fn start_http_server(&self) -> crate::error::Result<()> {
        let app = self.create_router();
        let addr = SocketAddr::from(([0, 0, 0, 0], self.port));

        let listener = TcpListener::bind(&addr).await?;
        println!("HTTP server listening on {}", addr);

        axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;
        Ok(())
    }

    fn create_router(&self) -> Router {
        let peers = self.peers.clone();
        let device = self.device.clone();

        Router::new()
            .route("/api/localsend/v2/register", post(register_device))
            .route("/api/localsend/v2/info", get(move || {
                let device = device.clone();
                async move { Json(device) }
            }))
            .route("/api/localsend/v2/prepare-upload", post(register_prepare_upload))
            .route("/api/localsend/v2/upload", post(register_upload))
            .layer(DefaultBodyLimit::disable())
            .layer(RequestBodyLimitLayer::new(1024 * 1024 * 1024))
            .layer(Extension(self.device.clone()))
            .layer(Extension(self.sessions.clone()))
            .layer(Extension(self.download_dir.clone()))
            .with_state(peers)

    }
}
