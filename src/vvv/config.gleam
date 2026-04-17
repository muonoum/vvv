import gleam/erlang/process
import gleam/uri.{type Uri}
import vvv/store

pub type Config {
  Config(
    store: process.Subject(store.Message),
    client_id: String,
    client_secret: String,
    redirect_uri: Uri,
    authorize_uri: Uri,
    jwks_uri: Uri,
    token_uri: Uri,
  )
}
