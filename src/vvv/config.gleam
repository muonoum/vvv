import gleam/uri.{type Uri}

pub type Config {
  Config(
    cookie_name: String,
    client_id: String,
    client_secret: String,
    authorize_uri: Uri,
    callback_uri: Uri,
    token_uri: Uri,
    keys_uri: Uri,
    callback_state: String,
  )
}
