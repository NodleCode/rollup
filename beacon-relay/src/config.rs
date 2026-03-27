use figment::{
    providers::{Env, Format, Toml},
    Figment,
};
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
pub struct Config {
    pub server: ServerConfig,
    pub log: LogConfig,
}

#[derive(Debug, Deserialize)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Deserialize)]
pub struct LogConfig {
    pub level: String,
    pub format: String,
}

impl Config {
    pub fn load() -> Result<Self, Box<figment::Error>> {
        let config_path = Self::default_config_path();
        Figment::new()
            .merge(Toml::file(config_path))
            .merge(Env::prefixed("APP_").split("__"))
            .extract()
            .map_err(Box::new)
    }

    pub fn listen_addr(&self) -> String {
        format!("{}:{}", self.server.host, self.server.port)
    }

    fn default_config_path() -> PathBuf {
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        PathBuf::from(manifest_dir).join("config/default.toml")
    }
}
