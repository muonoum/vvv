import envoy
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/http/request.{type Request}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import vvv/entra
import vvv/httpc
import vvv/report.{type Report}
import vvv/shared
import wisp
import ywt
import ywt/claim
import ywt/verify_key.{type VerifyKey}

pub const session_cookie: String = "vvv-session"

pub type Config {
  Config(
    client_id: String,
    client_secret: String,
    redirect_uri: Uri,
    authorize_uri: Uri,
    token_uri: Uri,
    jwks_uri: Uri,
    scope: String,
  )
}

pub type Login {
  Login(
    id_nonce: String,
    state_verifier: String,
    code_verifier: String,
    return_path: String,
  )
}

pub type Session {
  Session(
    user: User,
    id_token: String,
    access_token: String,
    code_verifier: String,
  )
}

pub type User {
  User(name: String, email: String)
}

type Error {
  ErrorMessage(String)
  HttpError(httpc.Error)
  JsonError(json.DecodeError)
  TokenError(ywt.ParseError)
}

pub fn configure_from_environment() -> Result(Config, String) {
  use client_id <- result.try(get_key("CLIENT_ID"))
  use client_secret <- result.try(get_key("CLIENT_SECRET"))
  use redirect_uri <- result.try(try_key("REDIRECT_URI", uri.parse))
  use authorize_uri <- result.try(try_key("AUTHORIZE_URI", uri.parse))
  use token_uri <- result.try(try_key("TOKEN_URI", uri.parse))
  use jwks_uri <- result.try(try_key("JWKS_URI", uri.parse))
  use scope <- result.try(get_key("SCOPE"))

  Ok(Config(
    client_id:,
    client_secret:,
    redirect_uri:,
    authorize_uri:,
    token_uri:,
    jwks_uri:,
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
    http.Get, ["login"] -> {
      let return_path =
        wisp.get_query(request)
        |> list.key_find("return_path")
        |> result.unwrap("/")

      login_handler(request, config:, return_path:)
    }

    http.Get, ["logout"] -> logout_handler(request)
    http.Post, ["callback"] -> callback_handler(request)
    http.Get, ["finalize"] -> finalize_handler(request, config:)
    _method, _segments -> wisp.not_found()
  }
}

fn authorize(config: Config, return_path: String) -> #(Uri, Login) {
  let state_verifier = shared.random(32)
  let state_challenge = shared.hash(state_verifier)
  let code_verifier = shared.random(32)
  let code_challenge = shared.hash(code_verifier)
  let id_nonce = shared.random(32)

  let query =
    uri.query_to_string([
      #("client_id", config.client_id),
      #("redirect_uri", uri.to_string(config.redirect_uri)),
      #("response_mode", "form_post"),
      #("response_type", "code id_token"),
      #("scope", config.scope),
      #("code_challenge_method", "S256"),
      #("code_challenge", code_challenge),
      #("state", state_challenge),
      #("nonce", id_nonce),
    ])

  let uri = Uri(..config.authorize_uri, query: Some(query))
  let login = Login(id_nonce:, state_verifier:, code_verifier:, return_path:)
  #(uri, login)
}

fn get_token(
  config: Config,
  code code: String,
  code_verifier code_verifier: String,
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

fn put_session(
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
  put_session(response, request:, value: json.null(), max_age: 0)
}

fn login_handler(
  request: wisp.Request,
  return_path return_path: String,
  config config: Config,
) -> wisp.Response {
  let #(authorize_uri, login) = authorize(config, return_path)

  uri.to_string(authorize_uri)
  |> wisp.redirect
  |> put_session(request:, max_age: 30, value: encode_login(login))
}

fn logout_handler(request: wisp.Request) -> wisp.Response {
  case wisp.get_cookie(request, session_cookie, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")
    Ok(..) -> wisp.redirect("/") |> delete_session(request)
  }
}

fn callback_handler(request) -> wisp.Response {
  use form_data <- wisp.require_form(request)

  case list.key_find(form_data.values, "state") {
    Error(Nil) -> wisp.bad_request("state not found")

    Ok(state) -> {
      let required = [#("state", state)]
      let id_token = list.key_find(form_data.values, "id_token")
      let code = list.key_find(form_data.values, "code")
      let options = [#("id_token", id_token), #("code", code)]

      let query =
        uri.query_to_string({
          use all, #(key, option) <- list.fold(options, required)

          result.map(option, fn(value) { [#(key, value), ..all] })
          |> result.unwrap(all)
        })

      let uri = uri.Uri(..uri.empty, path: "/auth/finalize", query: Some(query))
      wisp.redirect(uri.to_string(uri))
    }
  }
}

fn finalize_handler(
  request: wisp.Request,
  config config: Config,
) -> wisp.Response {
  case finalize_decoder(request:, config:) {
    Ok(#(login, session)) ->
      wisp.redirect(login.return_path)
      |> put_session(
        request:,
        max_age: 60 * 60 * 24,
        value: encode_session(session),
      )

    // TODO
    Error(report) ->
      string.inspect(report)
      |> wisp.bad_request
  }
}

fn finalize_decoder(
  request request: wisp.Request,
  config config: Config,
) -> Result(#(Login, Session), Report(Error)) {
  use login <- result.try({
    use session <- result.try(
      wisp.get_cookie(request:, name: session_cookie, security: wisp.Signed)
      |> report.replace_error(ErrorMessage("session cookie not found")),
    )

    json.parse(session, login_decoder())
    |> report.map_error(JsonError)
    |> report.error_context(ErrorMessage("could not parse login state"))
  })

  let query = wisp.get_query(request)

  use received_state <- result.try(
    list.key_find(query, "state")
    |> report.replace_error(ErrorMessage("state parameter not fond")),
  )

  use <- bool.guard(
    <<shared.hash(login.state_verifier):utf8>>
      |> crypto.secure_compare(<<received_state:utf8>>)
      |> bool.negate,
    report.error(ErrorMessage("state parameter mismatch")),
  )

  use keys <- result.try({
    request.from_uri(config.jwks_uri)
    |> report.replace_error(ErrorMessage("bad jwks uri"))
    |> result.try(get_signing_keys)
  })

  use id_token <- result.try(
    list.key_find(query, "id_token")
    |> report.replace_error(ErrorMessage("id_token parameter not found")),
  )

  use user <- result.try(
    ywt.decode(jwt: id_token, using: user_decoder(), keys:, claims: [
      claim.audience(config.client_id, []),
      claim.custom("nonce", login.id_nonce, json.string, decode.string),
    ])
    |> report.map_error(TokenError)
    |> report.error_context(ErrorMessage("could not decode id token")),
  )

  use access_token <- result.try({
    use code <- result.try(
      list.key_find(query, "code")
      |> report.replace_error(ErrorMessage("code parameter not found")),
    )

    get_access_token(code, config, login)
  })

  let session =
    Session(user:, id_token:, access_token:, code_verifier: login.code_verifier)

  Ok(#(login, session))
}

fn get_signing_keys(
  request: Request(_),
) -> Result(List(VerifyKey), Report(Error)) {
  use response <- result.try(
    httpc.send(request.set_body(request, None), [])
    |> report.map_error(HttpError)
    |> report.error_context(ErrorMessage("jwks request failed")),
  )

  entra.set_missing_key_algorithm(response.body)
  |> json.parse_bits(verify_key.set_decoder())
  |> report.map_error(JsonError)
  |> report.error_context(ErrorMessage("jwks decoding failed"))
}

fn get_access_token(
  code: String,
  config: Config,
  login: Login,
) -> Result(String, Report(Error)) {
  use request <- result.try(
    get_token(config, code:, code_verifier: login.code_verifier)
    |> report.replace_error(ErrorMessage(
      "could not create access token request",
    )),
  )

  use response <- result.try(
    request.map(request, bytes_tree.from_string)
    |> request.map(Some)
    |> httpc.send([])
    |> report.map_error(HttpError)
    |> report.error_context(ErrorMessage("access token request failed")),
  )

  json.parse_bits(response.body, access_token_decoder())
  |> report.map_error(JsonError)
  |> report.error_context(ErrorMessage("access token decoding failed"))
}

fn encode_login(login: Login) -> Json {
  json.object([
    #("id_nonce", json.string(login.id_nonce)),
    #("state_verifier", json.string(login.state_verifier)),
    #("code_verifier", json.string(login.code_verifier)),
    #("return_path", json.string(login.return_path)),
  ])
}

fn encode_session(session: Session) -> Json {
  json.object([
    #("access_token", json.string(session.access_token)),
    #("code_verifier", json.string(session.code_verifier)),
    #("id_token", json.string(session.id_token)),
    #("user", encode_user(session.user)),
  ])
}

fn encode_user(user: User) -> Json {
  json.object([
    #("email", json.string(user.email)),
    #("name", json.string(user.name)),
  ])
}

fn access_token_decoder() -> Decoder(String) {
  use access_token <- decode.field("access_token", decode.string)
  use _scope <- decode.field("scope", decode.string)
  use _expires_in <- decode.field("expires_in", decode.int)
  use _token_type <- decode.field("token_type", decode.string)
  decode.success(access_token)
}

fn login_decoder() -> Decoder(Login) {
  use id_nonce <- decode.field("id_nonce", decode.string)
  use state_verifier <- decode.field("state_verifier", decode.string)
  use code_verifier <- decode.field("code_verifier", decode.string)
  use return_path <- decode.field("return_path", decode.string)

  let state = Login(id_nonce:, state_verifier:, code_verifier:, return_path:)
  decode.success(state)
}

pub fn session_decoder() -> Decoder(Session) {
  use user <- decode.field("user", user_decoder())
  use id_token <- decode.field("id_token", decode.string)
  use access_token <- decode.field("access_token", decode.string)
  use code_verifier <- decode.field("code_verifier", decode.string)
  decode.success(Session(user:, code_verifier:, id_token:, access_token:))
}

fn user_decoder() -> Decoder(User) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(User(name:, email:))
}
