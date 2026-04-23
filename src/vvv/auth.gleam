import envoy
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import vvv/entra
import vvv/extra
import vvv/httpc
import vvv/report.{type Report}
import vvv/store
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
    state: String,
    code_verifier: String,
    return_path: String,
  )
}

pub type Session {
  Session(
    user: User,
    access_token: String,
    code_verifier: String,
    id_token: String,
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
  store store: process.Subject(store.Message),
  segments segments: List(String),
) -> wisp.Response {
  case request.method, segments {
    http.Get, ["login"] -> login_handler(request, config:, store:)
    http.Get, ["logout"] -> logout_handler(request)
    http.Post, ["callback"] -> callback_handler(request)
    http.Get, ["finalize"] -> finalize_handler(request, config:, store:)
    _method, _segments -> wisp.not_found()
  }
}

fn login_handler(
  request: wisp.Request,
  config config: Config,
  store store: process.Subject(store.Message),
) -> wisp.Response {
  let session_id = extra.random(32)
  let state = extra.random(32)
  let code_verifier = extra.random(32)
  let code_challenge = extra.hash(code_verifier)
  let id_nonce = extra.random(32)

  let query =
    uri.query_to_string([
      #("client_id", config.client_id),
      #("redirect_uri", uri.to_string(config.redirect_uri)),
      #("response_mode", "form_post"),
      #("response_type", "code id_token"),
      #("scope", config.scope),
      #("code_challenge_method", "S256"),
      #("code_challenge", code_challenge),
      #("state", state),
      #("nonce", id_nonce),
    ])

  let return_path =
    wisp.get_query(request)
    |> list.key_find("return_path")
    |> result.unwrap("/")

  let authorize_uri = Uri(..config.authorize_uri, query: Some(query))
  let login = Login(id_nonce:, state:, code_verifier:, return_path:)

  store.put(store, session_id, encode_login(login))

  uri.to_string(authorize_uri)
  |> wisp.redirect
  |> wisp.set_cookie(
    request:,
    name: session_cookie,
    value: session_id,
    security: wisp.Signed,
    max_age: 60,
  )
}

fn logout_handler(request: wisp.Request) -> wisp.Response {
  let return_path =
    wisp.get_query(request)
    |> list.key_find("return_path")
    |> result.unwrap("/")

  case wisp.get_cookie(request, session_cookie, wisp.Signed) {
    Error(Nil) -> wisp.redirect(return_path)

    Ok(..) ->
      wisp.redirect(return_path)
      |> wisp.set_cookie(
        request:,
        name: session_cookie,
        value: "",
        security: wisp.Signed,
        max_age: 0,
      )
  }
}

fn callback_handler(request) -> wisp.Response {
  use form_data <- wisp.require_form(request)

  case list.key_find(form_data.values, "state") {
    Error(Nil) -> wisp.bad_request("state not found")

    Ok(state) -> {
      let id_token = list.key_find(form_data.values, "id_token")
      let code = list.key_find(form_data.values, "code")
      let required = [#("state", state)]
      let options = [#("id_token", id_token), #("code", code)]

      let query =
        uri.query_to_string({
          use all, #(key, option) <- list.fold(options, required)

          result.map(option, fn(value) { [#(key, value), ..all] })
          |> result.unwrap(all)
        })

      uri.Uri(..uri.empty, path: "/auth/finalize", query: Some(query))
      |> uri.to_string
      |> wisp.redirect
    }
  }
}

fn finalize_handler(
  request: wisp.Request,
  config config: Config,
  store store: process.Subject(store.Message),
) -> wisp.Response {
  case finalize_decoder(request:, config:, store:) {
    Ok(#(id, login, session)) -> {
      store.put(store, id, encode_session(session))
      wisp.redirect(login.return_path)
    }

    // TODO
    Error(report) ->
      string.inspect(report)
      |> wisp.bad_request
  }
}

fn finalize_decoder(
  request request: wisp.Request,
  config config: Config,
  store store: process.Subject(store.Message),
) -> Result(#(String, Login, Session), Report(Error)) {
  use id <- result.try(
    wisp.get_cookie(request:, name: session_cookie, security: wisp.Signed)
    |> report.replace_error(ErrorMessage("session cookie not found")),
  )

  use login <- result.try({
    use session <- result.try(
      store.get(store, id)
      |> report.replace_error(ErrorMessage("session not found")),
    )

    json.to_string(session)
    |> json.parse(login_decoder())
    |> report.map_error(JsonError)
    |> report.error_context(ErrorMessage("decoding of session failed"))
  })

  let query = wisp.get_query(request)

  use state <- result.try(
    list.key_find(query, "state")
    |> report.replace_error(ErrorMessage("state parameter not fond")),
  )

  use <- bool.guard(
    !crypto.secure_compare(<<login.state:utf8>>, <<state:utf8>>),
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
    ywt.decode(jwt: id_token, using: id_token_decoder(), keys:, claims: [
      claim.audience(config.client_id, []),
      claim.custom("nonce", login.id_nonce, json.string, decode.string),
    ])
    |> report.map_error(TokenError)
    |> report.error_context(ErrorMessage("decoding of id token failed")),
  )

  use access_token <- result.try({
    use code <- result.try(
      list.key_find(query, "code")
      |> report.replace_error(ErrorMessage("code parameter not found")),
    )

    get_access_token(code:, config:, login:)
  })

  let session =
    Session(user:, id_token:, access_token:, code_verifier: login.code_verifier)

  Ok(#(id, login, session))
}

fn get_signing_keys(
  request: Request(_),
) -> Result(List(VerifyKey), Report(Error)) {
  use response <- result.try(
    httpc.send(request.set_body(request, None), [])
    |> report.map_error(HttpError)
    |> report.error_context(ErrorMessage("request for signing keys failed")),
  )

  entra.set_missing_key_algorithm(response.body)
  |> json.parse_bits(verify_key.set_decoder())
  |> report.map_error(JsonError)
  |> report.error_context(ErrorMessage("decoding of signing keys failed"))
}

fn get_access_token(
  code code: String,
  config config: Config,
  login login: Login,
) -> Result(String, Report(Error)) {
  use request <- result.try({
    use request <- result.map(
      request.from_uri(config.token_uri)
      |> report.replace_error(ErrorMessage("bad token uri")),
    )

    let query =
      uri.query_to_string([
        #("client_id", config.client_id),
        #("client_secret", config.client_secret),
        #("redirect_uri", uri.to_string(config.redirect_uri)),
        #("grant_type", "authorization_code"),
        #("code_verifier", login.code_verifier),
        #("code", code),
        #("scope", config.scope),
      ])

    request
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(query)
  })

  use response <- result.try(
    request.map(request, bytes_tree.from_string)
    |> request.map(Some)
    |> httpc.send([])
    |> report.map_error(HttpError)
    |> report.error_context(ErrorMessage("request for access token failed")),
  )

  json.parse_bits(response.body, access_token_decoder())
  |> report.map_error(JsonError)
  |> report.error_context(ErrorMessage("decoding of access token failed"))
}

fn encode_login(login: Login) -> Json {
  json.object([
    #("id_nonce", json.string(login.id_nonce)),
    #("state", json.string(login.state)),
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
  use state <- decode.field("state", decode.string)
  use code_verifier <- decode.field("code_verifier", decode.string)
  use return_path <- decode.field("return_path", decode.string)
  decode.success(Login(id_nonce:, state:, code_verifier:, return_path:))
}

pub fn session_decoder() -> Decoder(Session) {
  use user <- decode.field("user", id_token_decoder())
  use id_token <- decode.field("id_token", decode.string)
  use access_token <- decode.field("access_token", decode.string)
  use code_verifier <- decode.field("code_verifier", decode.string)
  decode.success(Session(user:, code_verifier:, id_token:, access_token:))
}

fn id_token_decoder() -> Decoder(User) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(User(name:, email:))
}
