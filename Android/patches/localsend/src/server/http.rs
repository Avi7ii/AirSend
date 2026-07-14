use axum::{
    body::Body,
    extract::DefaultBodyLimit,
    http::Request,
    routing::{get, post},
    Extension, Json, Router,
};
use hyper::body::Incoming;
use hyper_util::{
    rt::{TokioExecutor, TokioIo},
    server::conn::auto::Builder,
    service::TowerToHyperService,
};
use rustls::{
    pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer},
    ServerConfig,
};
use std::{future::poll_fn, io, net::SocketAddr, sync::Arc};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tower::{Service, ServiceExt as _};
use tower_http::limit::RequestBodyLimitLayer;

use crate::{
    discovery::http::register_device,
    transfer::upload::{register_cancel, register_prepare_upload, register_upload},
    Client,
};

impl Client {
    pub async fn start_http_server(&self) -> crate::error::Result<()> {
        if let Some(tls_config) = self.build_tls_server_config()? {
            return self.start_https_server(tls_config).await;
        }

        self.start_plain_http_server().await
    }

    fn build_tls_server_config(&self) -> crate::error::Result<Option<Arc<ServerConfig>>> {
        let Some(identity) = self.tls_identity.as_ref() else {
            return Ok(None);
        };

        let cert_chain = CertificateDer::pem_slice_iter(identity.cert_pem.as_slice())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|err| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("Invalid cert PEM: {err}"),
                )
            })?;
        let private_key =
            PrivateKeyDer::from_pem_slice(identity.key_pem.as_slice()).map_err(|err| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("Invalid key PEM: {err}"),
                )
            })?;

        let mut server_config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(cert_chain, private_key)
            .map_err(|err| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("Invalid TLS identity: {err}"),
                )
            })?;
        server_config.alpn_protocols = vec![b"http/1.1".to_vec()];

        Ok(Some(Arc::new(server_config)))
    }

    async fn start_plain_http_server(&self) -> crate::error::Result<()> {
        let app = self.create_router();
        let addr = SocketAddr::from(([0, 0, 0, 0], self.port));

        let listener = TcpListener::bind(&addr).await?;
        tracing::info!("HTTP server listening on {}", addr);

        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await?;
        Ok(())
    }

    async fn start_https_server(&self, tls_config: Arc<ServerConfig>) -> crate::error::Result<()> {
        let app = self.create_router();
        let addr = SocketAddr::from(([0, 0, 0, 0], self.port));
        let listener = TcpListener::bind(&addr).await?;
        let acceptor = TlsAcceptor::from(tls_config);
        let mut make_service = app.into_make_service_with_connect_info::<SocketAddr>();

        tracing::info!("HTTPS server listening on {}", addr);

        loop {
            let (tcp_stream, remote_addr) = listener.accept().await?;
            let acceptor = acceptor.clone();

            poll_fn(|cx| Service::<SocketAddr>::poll_ready(&mut make_service, cx))
                .await
                .unwrap_or_else(|err| match err {});

            let tower_service = make_service
                .call(remote_addr)
                .await
                .unwrap_or_else(|err| match err {})
                .map_request(|req: Request<Incoming>| req.map(Body::new));

            tokio::spawn(async move {
                let tls_stream = match acceptor.accept(tcp_stream).await {
                    Ok(stream) => stream,
                    Err(err) => {
                        tracing::warn!("TLS handshake error from {}: {}", remote_addr, err);
                        return;
                    }
                };

                let io = TokioIo::new(tls_stream);
                let hyper_service = TowerToHyperService::new(tower_service);

                if let Err(err) = Builder::new(TokioExecutor::new())
                    .serve_connection_with_upgrades(io, hyper_service)
                    .await
                {
                    tracing::warn!("HTTPS connection error from {}: {}", remote_addr, err);
                }
            });
        }
    }

    fn create_router(&self) -> Router {
        let peers = self.peers.clone();
        let device = self.device.clone();

        Router::new()
            .route("/api/localsend/v2/register", post(register_device))
            .route(
                "/api/localsend/v2/info",
                get(move || {
                    let device = device.clone();
                    async move { Json(device) }
                }),
            )
            .route(
                "/api/localsend/v2/prepare-upload",
                post(register_prepare_upload),
            )
            .route("/api/localsend/v2/upload", post(register_upload))
            .route("/api/localsend/v2/cancel", post(register_cancel))
            .layer(DefaultBodyLimit::disable())
            .layer(RequestBodyLimitLayer::new(1024 * 1024 * 1024))
            .layer(Extension(self.device.clone()))
            .layer(Extension(self.sessions.clone()))
            .layer(Extension(self.download_dir.clone()))
            .layer(Extension(self.incoming_handler.clone()))
            .with_state(peers)
    }
}
