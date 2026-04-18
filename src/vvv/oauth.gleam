import envoy
import gleam/http
import gleam/http/request.{type Request}
import gleam/option
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import vvv/shared

pub type Config {
  Config(
    client_id: String,
    client_secret: String,
    redirect_uri: Uri,
    authorize_uri: Uri,
    token_uri: Uri,
    jwks_uri: Uri,
  )
}

pub type State {
  State(nonce: String, code_verifier: String)
}

pub fn from_environment() -> Result(Config, String) {
  let get = fn(key) {
    envoy.get(key)
    |> result.replace_error(key)
  }

  let try = fn(key, into) {
    envoy.get(key)
    |> result.try(into)
    |> result.replace_error(key)
  }

  use client_id <- result.try(get("CLIENT_ID"))
  use client_secret <- result.try(get("CLIENT_SECRET"))
  use redirect_uri <- result.try(try("REDIRECT_URI", uri.parse))
  use authorize_uri <- result.try(try("AUTHORIZE_URI", uri.parse))
  use token_uri <- result.try(try("TOKEN_URI", uri.parse))
  use jwks_uri <- result.try(try("JWKS_URI", uri.parse))

  Ok(Config(
    client_id:,
    client_secret:,
    redirect_uri:,
    authorize_uri:,
    token_uri:,
    jwks_uri:,
  ))
}

pub fn authorize(
  uri uri: Uri,
  client_id client_id: String,
  redirect_uri redirect_uri: Uri,
  scope scope: List(String),
) -> #(Uri, String, State) {
  let key = shared.random_string(32)
  let state = shared.hashed_string(key)
  let code_verifier = shared.random_string(32)
  let code_challenge = shared.hashed_string(code_verifier)
  let nonce = shared.random_string(32)

  let query =
    uri.query_to_string([
      #("response_type", "code id_token"),
      #("client_id", client_id),
      #("redirect_uri", uri.to_string(redirect_uri)),
      #("response_mode", "form_post"),
      #("scope", string.join(scope, " ")),
      #("code_challenge_method", "S256"),
      #("code_challenge", code_challenge),
      #("state", state),
      #("nonce", nonce),
    ])

  let uri = Uri(..uri, query: option.Some(query))
  #(uri, key, State(nonce:, code_verifier:))
}

pub fn get_token(
  uri uri: Uri,
  client_id client_id: String,
  client_secret client_secret: String,
  redirect_uri redirect_uri: Uri,
  scope scope: List(String),
  code_verifier code_verifier: String,
  code code: String,
) -> Result(Request(String), Nil) {
  use request <- result.try(request.from_uri(uri))

  let query =
    uri.query_to_string([
      #("grant_type", "authorization_code"),
      #("client_id", client_id),
      #("client_secret", client_secret),
      #("scope", string.join(scope, " ")),
      #("redirect_uri", uri.to_string(redirect_uri)),
      #("code_verifier", code_verifier),
      #("code", code),
    ])

  request
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(query)
  |> Ok
}
