import envoy
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/http/request.{type Request}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import vvv/entra
import vvv/httpc
import vvv/shared
import wisp
import ywt
import ywt/claim
import ywt/verify_key

pub const cookie_name = "vvv-session"

pub type User {
  User(name: String, email: String)
}

pub type Config {
  Config(
    client_id: String,
    client_secret: String,
    redirect_uri: Uri,
    authorize_uri: Uri,
    token_uri: Uri,
    jwks_uri: Uri,
    response_mode: String,
    response_type: String,
    scope: String,
  )
}

pub type State {
  State(nonce: String, code_verifier: String)
}

pub fn user_decoder() {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(User(name:, email:))
}

pub fn configure_from_environment() -> Result(Config, String) {
  use client_id <- result.try(get_key("CLIENT_ID"))
  use client_secret <- result.try(get_key("CLIENT_SECRET"))
  use redirect_uri <- result.try(try_key("REDIRECT_URI", uri.parse))
  use authorize_uri <- result.try(try_key("AUTHORIZE_URI", uri.parse))
  use token_uri <- result.try(try_key("TOKEN_URI", uri.parse))
  use jwks_uri <- result.try(try_key("JWKS_URI", uri.parse))
  use response_mode <- result.try(get_key("RESPONSE_MODE"))
  use response_type <- result.try(get_key("RESPONSE_TYPE"))
  use scope <- result.try(get_key("SCOPE"))

  Ok(Config(
    client_id:,
    client_secret:,
    redirect_uri:,
    authorize_uri:,
    token_uri:,
    jwks_uri:,
    response_mode:,
    response_type:,
    scope:,
  ))
}

fn get_key(key: String) -> Result(String, String) {
  envoy.get(key)
  |> result.replace_error(key)
}

fn try_key(
  key: String,
  into: fn(String) -> Result(a, Nil),
) -> Result(a, String) {
  result.try(envoy.get(key), into)
  |> result.replace_error(key)
}

fn authorize(config: Config) -> #(Uri, String, State) {
  let key = shared.random_string(32)
  let state = shared.hashed_string(key)
  let code_verifier = shared.random_string(32)
  let code_challenge = shared.hashed_string(code_verifier)
  let nonce = shared.random_string(32)

  let query =
    uri.query_to_string([
      #("response_type", config.response_type),
      #("client_id", config.client_id),
      #("redirect_uri", uri.to_string(config.redirect_uri)),
      #("response_mode", config.response_mode),
      #("scope", config.scope),
      #("code_challenge_method", "S256"),
      #("code_challenge", code_challenge),
      #("state", state),
      #("nonce", nonce),
    ])

  let uri = Uri(..config.authorize_uri, query: option.Some(query))
  #(uri, key, State(nonce:, code_verifier:))
}

fn get_token(
  config: Config,
  code_verifier code_verifier: String,
  code code: String,
) -> Result(Request(String), Nil) {
  use request <- result.try(request.from_uri(config.token_uri))

  let query =
    uri.query_to_string([
      #("grant_type", "authorization_code"),
      #("client_id", config.client_id),
      #("client_secret", config.client_secret),
      #("scope", config.scope),
      #("redirect_uri", uri.to_string(config.redirect_uri)),
      #("code_verifier", code_verifier),
      #("code", code),
    ])

  request
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(query)
  |> Ok
}

fn create_session(
  response: wisp.Response,
  request request: wisp.Request,
  value value: Json,
  max_age max_age: Int,
) -> wisp.Response {
  response
  |> wisp.set_cookie(
    request:,
    name: cookie_name,
    value: json.to_string(value),
    security: wisp.Signed,
    max_age:,
  )
}

fn delete_session(
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
  auth_config auth_config: Config,
) -> wisp.Response {
  let #(authorize_uri, session_id, oauth_state) = authorize(auth_config)

  uri.to_string(authorize_uri)
  |> wisp.redirect
  |> create_session(
    request:,
    max_age: 30,
    value: json.object([
      #("session_id", json.string(session_id)),
      #("nonce", json.string(oauth_state.nonce)),
      #("code_verifier", json.string(oauth_state.code_verifier)),
    ]),
  )
}

pub fn logout_handler(request: wisp.Request) -> wisp.Response {
  use request <- wisp.csrf_known_header_protection(request)

  case wisp.get_cookie(request, cookie_name, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")
    Ok(..) -> wisp.redirect("/") |> delete_session(request)
  }
}

pub fn query_response(
  request: Request(wisp.Connection),
  next: fn(String, String, Option(String)) -> wisp.Response,
) -> wisp.Response {
  let assert Ok(query) = request.get_query(request)
  let assert Ok(id_token) = list.key_find(query, "id_token")
  let assert Ok(state) = list.key_find(query, "state")
  let code = list.key_find(query, "code") |> option.from_result
  next(id_token, state, code)
}

pub fn form_post_response(
  request: Request(wisp.Connection),
  next: fn(String, String, Option(String)) -> wisp.Response,
) -> wisp.Response {
  use form_data <- wisp.require_form(request)
  let assert Ok(id_token) = list.key_find(form_data.values, "id_token")
  let assert Ok(state) = list.key_find(form_data.values, "state")
  let code = list.key_find(form_data.values, "code") |> option.from_result
  next(id_token, state, code)
}

pub fn callback_handler(
  id_token: String,
  state: String,
  code: Option(String),
) -> wisp.Response {
  let parameters = [#("id_token", id_token), #("state", state)]

  let query =
    option.Some(uri.query_to_string(
      option.map(code, fn(code) { [#("code", code), ..parameters] })
      |> option.unwrap(parameters),
    ))

  let uri = uri.Uri(..uri.empty, path: "/auth/ok", query:)
  wisp.redirect(uri.to_string(uri))
}

pub fn ok_handler(
  request: wisp.Request,
  auth_config auth_config: Config,
) -> wisp.Response {
  // TODO: Feilhåndtering

  use request <- wisp.csrf_known_header_protection(request)
  let assert Ok(query) = request.get_query(request)

  //
  // Session
  //

  let assert Ok(session) =
    wisp.get_cookie(request:, name: cookie_name, security: wisp.Signed)

  let assert Ok(#(session_id, oauth_state)) =
    json.parse(session, {
      use session_id <- decode.field("session_id", decode.string)
      use nonce <- decode.field("nonce", decode.string)
      use code_verifier <- decode.field("code_verifier", decode.string)
      decode.success(#(session_id, State(nonce:, code_verifier:)))
    })

  //
  // State
  //

  let assert Ok(True) = {
    use state <- result.map(list.key_find(query, "state"))
    let session_id = shared.hashed_string(session_id)
    crypto.secure_compare(<<session_id:utf8>>, <<state:utf8>>)
  }

  //
  // Keys
  //

  let assert Ok(keys_request) = request.from_uri(auth_config.jwks_uri)

  let assert Ok(keys_response) =
    httpc.send(request.set_body(keys_request, option.None), [])

  let assert Ok(keys) =
    entra.set_key_algorithm(keys_response.body)
    |> result.map_error(fn(error) {
      wisp.log_warning("set key algorithm: " <> string.inspect(error))
      error
    })
    |> result.unwrap(keys_response.body)
    |> json.parse_bits(verify_key.set_decoder())

  //
  // ID
  //

  let assert Ok(id_token) = list.key_find(query, "id_token")

  // let _ =
  //   echo ywt.decode(jwt: id_token, using: decode.dynamic, keys:, claims: [
  //     claim.audience(auth_config.client_id, []),
  //     claim.custom("nonce", oauth_state.nonce, json.string, decode.string),
  //   ])

  let assert Ok(#(name, email)) =
    ywt.decode(jwt: id_token, using: id_token_decoder(), keys:, claims: [
      claim.audience(auth_config.client_id, []),
      claim.custom("nonce", oauth_state.nonce, json.string, decode.string),
    ])

  //
  // Access
  //

  let access_token = case list.key_find(query, "code") {
    Error(Nil) -> json.null()

    Ok(code) -> {
      let assert Ok(token_request) =
        get_token(auth_config, code_verifier: oauth_state.code_verifier, code:)

      let assert Ok(token_response) = {
        token_request
        |> request.map(bytes_tree.from_string)
        |> request.map(option.Some)
        |> httpc.send([])
      }

      let assert Ok(#(access_token, _, _, _)) =
        json.parse_bits(token_response.body, access_token_decoder())

      json.string(access_token)
    }
  }

  //
  // Return
  //

  wisp.redirect("/")
  |> create_session(
    request:,
    max_age: 60 * 60 * 24,
    value: json.object([
      #("name", json.string(name)),
      #("email", json.string(email)),
      #("id_token", json.string(id_token)),
      #("code_verifier", json.string(oauth_state.code_verifier)),
      #("access_token", access_token),
    ]),
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
