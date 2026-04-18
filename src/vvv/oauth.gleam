import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request}
import gleam/option
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}

pub type State {
  State(nonce: String, code_verifier: String)
}

fn random_string(length: Int) -> String {
  crypto.strong_random_bytes(length)
  |> bit_array.base64_url_encode(False)
}

pub fn authorize(
  uri uri: Uri,
  client_id client_id: String,
  redirect_uri redirect_uri: Uri,
  scope scope: List(String),
) -> #(Uri, String, State) {
  let code_verifier = random_string(32)

  let code_challenge =
    crypto.hash(crypto.Sha256, <<code_verifier:utf8>>)
    |> bit_array.base64_url_encode(False)

  let state = random_string(32)
  let nonce = random_string(32)

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
  #(uri, state, State(nonce:, code_verifier:))
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

  use request <- result.try(request.from_uri(uri))

  request
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(query)
  |> Ok
}
