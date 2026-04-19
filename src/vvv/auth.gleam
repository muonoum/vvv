import envoy
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import vvv/entra
import vvv/httpc
import vvv/session.{type Session}
import vvv/shared
import vvv/store
import wisp
import ywt
import ywt/claim
import ywt/verify_key

pub const cookie_name = "vvv-session"

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

pub fn configure_from_environment() -> Result(Config, String) {
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

pub fn has_session(
  request: wisp.Request,
  store: process.Subject(store.Message),
) -> Bool {
  wisp.get_cookie(request, cookie_name, wisp.Signed)
  |> result.map(store.contains(store, _))
  |> result.unwrap(False)
}

fn authorize(
  uri uri: Uri,
  client_id client_id: String,
  redirect_uri redirect_uri: Uri,
  scope scope: List(String),
) -> #(Uri, String, session.Login) {
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
  #(uri, key, session.Login(nonce:, code_verifier:))
}

fn get_token(
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

pub fn create_session(
  response: wisp.Response,
  request request: wisp.Request,
  store store: process.Subject(store.Message),
  session_id session_id: String,
  value value: Session,
  max_age max_age: Int,
) -> wisp.Response {
  store.insert(store, session_id, value)

  response
  |> wisp.set_cookie(
    request:,
    name: cookie_name,
    value: session_id,
    security: wisp.Signed,
    max_age:,
  )
}

pub fn delete_session(
  response: wisp.Response,
  request: wisp.Request,
) -> wisp.Response {
  response
  |> wisp.set_cookie(
    request:,
    name: cookie_name,
    value: "",
    security: wisp.Signed,
    max_age: 0,
  )
}

pub fn login_handler(
  request: wisp.Request,
  store store: process.Subject(store.Message),
  oauth_config oauth_config: Config,
) -> wisp.Response {
  let #(authorize_uri, session_id, oauth_state) =
    authorize(
      uri: oauth_config.authorize_uri,
      client_id: oauth_config.client_id,
      redirect_uri: oauth_config.redirect_uri,
      scope: ["openid", "profile", "email"],
    )

  uri.to_string(authorize_uri)
  |> wisp.redirect
  |> create_session(
    request:,
    store:,
    session_id:,
    max_age: 30,
    value: session.LoginSession(oauth_state),
  )
}

pub fn logout_handler(request: wisp.Request) -> wisp.Response {
  use request <- wisp.csrf_known_header_protection(request)

  case wisp.get_cookie(request, cookie_name, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")
    Ok(..) -> wisp.redirect("/") |> delete_session(request)
  }
}

pub fn callback_handler(request: wisp.Request) -> wisp.Response {
  use form_data <- wisp.require_form(request)

  let assert Ok(code) = list.key_find(form_data.values, "code")
  let assert Ok(id_token) = list.key_find(form_data.values, "id_token")
  let assert Ok(state) = list.key_find(form_data.values, "state")

  let query =
    uri.query_to_string([
      #("code", code),
      #("id_token", id_token),
      #("state", state),
    ])

  let uri = uri.Uri(..uri.empty, path: "/auth/ok", query: option.Some(query))
  wisp.redirect(uri.to_string(uri))
}

pub fn ok_handler(
  request: wisp.Request,
  store store: process.Subject(store.Message),
  oauth_config oauth_config: Config,
) -> wisp.Response {
  // TODO: Feilhåndtering

  use request <- wisp.csrf_known_header_protection(request)
  let assert Ok(query) = request.get_query(request)

  let assert Ok(session_id) =
    wisp.get_cookie(request:, name: cookie_name, security: wisp.Signed)

  let assert Ok(session.LoginSession(oauth_state)) =
    store.get(store, session_id)

  let assert Ok(True) = {
    use state <- result.map(list.key_find(query, "state"))
    let session_id = shared.hashed_string(session_id)
    crypto.secure_compare(<<session_id:utf8>>, <<state:utf8>>)
  }

  let assert Ok(id_token) = list.key_find(query, "id_token")
  let assert Ok(code) = list.key_find(query, "code")

  let assert Ok(keys_request) = request.from_uri(oauth_config.jwks_uri)

  let assert Ok(keys_response) =
    httpc.send(request.set_body(keys_request, option.None), [])

  let assert Ok(keys) =
    entra.set_algorithm(keys_response.body)
    |> result.map_error(fn(error) {
      wisp.log_warning("set key algorithm: " <> string.inspect(error))
      error
    })
    |> result.unwrap(keys_response.body)
    |> json.parse_bits(verify_key.set_decoder())

  let assert Ok(#(name, email)) =
    ywt.decode(jwt: id_token, using: id_token_decoder(), keys:, claims: [
      claim.audience(oauth_config.client_id, []),
      claim.custom("nonce", oauth_state.nonce, json.string, decode.string),
    ])

  let assert Ok(token_request) =
    get_token(
      uri: oauth_config.token_uri,
      client_id: oauth_config.client_id,
      client_secret: oauth_config.client_secret,
      redirect_uri: oauth_config.redirect_uri,
      scope: ["openid", "profile", "email"],
      code_verifier: oauth_state.code_verifier,
      code:,
    )

  let assert Ok(token_response) = {
    token_request
    |> request.map(bytes_tree.from_string)
    |> request.map(option.Some)
    |> httpc.send([])
  }

  let assert Ok(#(access_token, _, _, _)) =
    json.parse_bits(token_response.body, access_token_decoder())

  wisp.redirect("/")
  |> create_session(
    request:,
    store:,
    session_id:,
    max_age: 60 * 60 * 24,
    value: session.User(name:, email:, id_token:, access_token:)
      |> session.UserSession,
  )
}

fn id_token_decoder() -> Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(#(name, email))
}

fn access_token_decoder() -> Decoder(#(String, String, Int, String)) {
  use access_token <- decode.field("access_token", decode.string)
  use scope <- decode.field("scope", decode.string)
  use expires_in <- decode.field("expires_in", decode.int)
  use token_type <- decode.field("token_type", decode.string)
  decode.success(#(access_token, scope, expires_in, token_type))
}
