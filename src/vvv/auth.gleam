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
import gleam/uri.{type Uri, Uri}
import vvv/entra
import vvv/httpc
import vvv/shared
import wisp
import ywt
import ywt/claim
import ywt/verify_key

pub const session_cookie = "vvv-session"

pub type User {
  User(name: String, email: String)
}

pub type Session {
  Session(
    user: User,
    id_token: Option(String),
    access_token: Option(String),
    code_verifier: String,
  )
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

type State {
  State(nonce: String, code_verifier: String)
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
  into: fn(String) -> Result(v, Nil),
) -> Result(v, String) {
  result.try(envoy.get(key), into)
  |> result.replace_error(key)
}

pub fn router(
  request: wisp.Request,
  config config: Config,
  segments segments: List(String),
) -> wisp.Response {
  case request.method, segments {
    http.Get, ["login"] ->
      login_handler(
        request,
        config:,
        return_path: wisp.get_query(request)
          |> list.key_find("return_path")
          |> result.unwrap("/"),
      )

    http.Get, ["logout"] -> logout_handler(request)
    http.Post, ["callback"] -> form_post_response(request, callback_handler)
    http.Get, ["ok"] -> ok_handler(request, config:)
    _method, _segments -> wisp.not_found()
  }
}

fn authorize(config: Config) -> #(Uri, String, State) {
  let key = shared.random(32)
  let state = shared.hash(key)
  let code_verifier = shared.random(32)
  let code_challenge = shared.hash(code_verifier)
  let nonce = shared.random(32)

  let query =
    uri.query_to_string([
      #("client_id", config.client_id),
      #("redirect_uri", uri.to_string(config.redirect_uri)),
      #("response_mode", config.response_mode),
      #("response_type", config.response_type),
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
      #("client_id", config.client_id),
      #("client_secret", config.client_secret),
      #("redirect_uri", uri.to_string(config.redirect_uri)),
      #("grant_type", "authorization_code"),
      #("code_verifier", code_verifier),
      #("code", code),
      #("scope", config.scope),
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
    name: session_cookie,
    value: json.to_string(value),
    security: wisp.Signed,
    max_age:,
  )
}

fn delete_session(
  response: wisp.Response,
  request: wisp.Request,
) -> wisp.Response {
  create_session(response, request:, value: json.null(), max_age: 0)
}

fn login_handler(
  request: wisp.Request,
  return_path return_path: String,
  config config: Config,
) -> wisp.Response {
  let #(authorize_uri, session_state, oauth_state) = authorize(config)

  uri.to_string(authorize_uri)
  |> wisp.redirect
  |> create_session(
    request:,
    max_age: 30,
    value: json.object([
      #("session_state", json.string(session_state)),
      #("nonce", json.string(oauth_state.nonce)),
      #("code_verifier", json.string(oauth_state.code_verifier)),
      #("return_path", json.string(return_path)),
    ]),
  )
}

fn logout_handler(request: wisp.Request) -> wisp.Response {
  case wisp.get_cookie(request, session_cookie, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")
    Ok(..) -> wisp.redirect("/") |> delete_session(request)
  }
}

@internal
pub fn query_response(
  request: Request(wisp.Connection),
  next: fn(String, Option(String), Option(String)) -> wisp.Response,
) -> wisp.Response {
  let query = wisp.get_query(request)
  let assert Ok(state) = list.key_find(query, "state")
  let id_token = list.key_find(query, "id_token")
  let code = list.key_find(query, "code")
  next(state, option.from_result(id_token), option.from_result(code))
}

@internal
pub fn form_post_response(
  request: Request(wisp.Connection),
  next: fn(String, Option(String), Option(String)) -> wisp.Response,
) -> wisp.Response {
  use form_data <- wisp.require_form(request)
  let assert Ok(state) = list.key_find(form_data.values, "state")
  let id_token = list.key_find(form_data.values, "id_token")
  let code = list.key_find(form_data.values, "code")
  next(state, option.from_result(id_token), option.from_result(code))
}

fn callback_handler(
  state: String,
  id_token: Option(String),
  code: Option(String),
) -> wisp.Response {
  let required = [#("state", state)]
  let options = [#("id_token", id_token), #("code", code)]

  let query =
    option.Some(
      uri.query_to_string({
        use all, #(key, option) <- list.fold(options, required)
        option.map(option, fn(value) { [#(key, value), ..all] })
        |> option.unwrap(all)
      }),
    )

  let uri = uri.Uri(..uri.empty, path: "/auth/ok", query:)
  wisp.redirect(uri.to_string(uri))
}

// TODO: Feilhåndtering
fn ok_handler(request: wisp.Request, config config: Config) -> wisp.Response {
  let query = wisp.get_query(request)

  let assert Ok(#(session_state, return_path, oauth_state)) = {
    let assert Ok(session) =
      wisp.get_cookie(request:, name: session_cookie, security: wisp.Signed)

    json.parse(session, login_session_decoder())
  }

  let assert Ok(True) = {
    use state <- result.map(list.key_find(query, "state"))
    let session_state = shared.hash(session_state)
    crypto.secure_compare(<<session_state:utf8>>, <<state:utf8>>)
  }

  let assert Ok(keys) = {
    let assert Ok(request) = request.from_uri(config.jwks_uri)

    let assert Ok(response) =
      httpc.send(request.set_body(request, option.None), [])

    entra.set_missing_key_algorithm(response.body)
    |> json.parse_bits(verify_key.set_decoder())
  }

  let #(id_token, user) = case list.key_find(query, "id_token") {
    Error(Nil) -> #(json.null(), json.null())

    Ok(id_token) -> {
      // let _ =
      //   echo ywt.decode(jwt: id_token, using: decode.dynamic, keys:, claims: [
      //     claim.audience(config.client_id, []),
      //     claim.custom("nonce", oauth_state.nonce, json.string, decode.string),
      //   ])

      let assert Ok(user) =
        ywt.decode(jwt: id_token, using: user_decoder(), keys:, claims: [
          claim.audience(config.client_id, []),
          claim.custom("nonce", oauth_state.nonce, json.string, decode.string),
        ])

      #(json.string(id_token), encode_user(user))
    }
  }

  let access_token = case list.key_find(query, "code") {
    Error(Nil) -> json.null()

    Ok(code) -> {
      let assert Ok(request) =
        get_token(config, code_verifier: oauth_state.code_verifier, code:)

      let assert Ok(response) = {
        request.map(request, bytes_tree.from_string)
        |> request.map(option.Some)
        |> httpc.send([])
      }

      let assert Ok(#(access_token, _, _, _)) =
        json.parse_bits(response.body, access_token_decoder())

      json.string(access_token)
    }
  }

  wisp.redirect(return_path)
  |> create_session(
    request:,
    max_age: 60 * 60 * 24,
    value: json.object([
      #("user", user),
      #("id_token", id_token),
      #("access_token", access_token),
      #("code_verifier", json.string(oauth_state.code_verifier)),
    ]),
  )
}

fn login_session_decoder() -> Decoder(#(String, String, State)) {
  use session_state <- decode.field("session_state", decode.string)
  use nonce <- decode.field("nonce", decode.string)
  use code_verifier <- decode.field("code_verifier", decode.string)
  use return_path <- decode.field("return_path", decode.string)
  decode.success(#(session_state, return_path, State(nonce:, code_verifier:)))
}

fn access_token_decoder() -> Decoder(#(String, String, Int, String)) {
  use access_token <- decode.field("access_token", decode.string)
  use scope <- decode.field("scope", decode.string)
  use expires_in <- decode.field("expires_in", decode.int)
  use token_type <- decode.field("token_type", decode.string)
  decode.success(#(access_token, scope, expires_in, token_type))
}

fn encode_user(user: User) -> Json {
  json.object([
    #("name", json.string(user.name)),
    #("email", json.string(user.email)),
  ])
}

fn user_decoder() -> Decoder(User) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(User(name:, email:))
}

pub fn session_decoder() {
  use user <- decode.field("user", user_decoder())
  use id_token <- decode.field("id_token", decode.optional(decode.string))

  use access_token <- decode.field(
    "access_token",
    decode.optional(decode.string),
  )

  use code_verifier <- decode.field("code_verifier", decode.string)
  decode.success(Session(user:, id_token:, code_verifier:, access_token:))
}
