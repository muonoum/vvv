import envoy
import gleam/bool
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import logging
import vvv/entra
import vvv/extra
import vvv/extra/httpc
import vvv/extra/report.{type Report}
import vvv/extra/state
import vvv/session
import vvv/web
import ywt
import ywt/claim
import ywt/verify_key.{type VerifyKey}

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

pub fn login_handler(
  request: web.Request,
  config: Config,
) -> session.State(web.Response) {
  let state = extra.random_string(32)
  let code_verifier = extra.random_string(32)
  let code_challenge = extra.hash_string(code_verifier)
  let id_nonce = extra.random_string(32)

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
    request.get_query(request)
    |> result.unwrap([])
    |> list.key_find("return_path")
    |> result.unwrap("/")

  let authorize_uri = Uri(..config.authorize_uri, query: option.Some(query))
  let login = Login(id_nonce:, state:, code_verifier:, return_path:)
  use <- state.do(session.put("login", json.to_string(encode_login(login))))

  uri.to_string(authorize_uri)
  |> response.redirect
  |> web.empty_body
  |> state.return
}

pub fn logout_handler(request: web.Request) -> session.State(web.Response) {
  let return_path =
    request.get_query(request)
    |> result.unwrap([])
    |> list.key_find("return_path")
    |> result.unwrap("/")

  use <- state.do(session.delete("login"))

  response.redirect(return_path)
  |> web.empty_body
  |> state.return
}

pub fn callback_handler(request) -> web.Response {
  use form_data <- web.form_data(request, bytes_limit: 4096)

  case list.key_find(form_data, "state") {
    Error(Nil) ->
      response.new(400)
      |> web.text_body("Bad Request")

    Ok(state) -> {
      let code = list.key_find(form_data, "code")
      let id_token = list.key_find(form_data, "id_token")
      let options = [#("code", code), #("id_token", id_token)]
      let required = [#("state", state)]

      let query =
        uri.query_to_string({
          use all, #(key, option) <- list.fold(options, required)
          use <- extra.return(result.unwrap(_, all))
          use value <- result.map(option)
          [#(key, value), ..all]
        })

      uri.Uri(..uri.empty, path: "/auth/finalize", query: option.Some(query))
      |> uri.to_string
      |> response.redirect
      |> web.empty_body
    }
  }
}

pub fn finalize_handler(
  request: web.Request,
  config: Config,
) -> session.State(web.Response) {
  use session <- state.bind(session.get("login"))

  case session {
    Error(Nil) -> {
      logging.log(logging.Error, "login session not found")

      response.new(400)
      |> web.text_body("Bad Request")
      |> state.return
    }

    Ok(session) ->
      case finalize_decoder(request:, config:, session:) {
        Ok(#(login, session)) -> {
          use <- state.do({
            encode_session(session)
            |> json.to_string
            |> session.put("login", _)
          })

          use <- state.do(session.put_flash("status", "login ok"))

          response.redirect(login.return_path)
          |> web.empty_body
          |> state.return
        }

        // TODO
        Error(report) -> {
          logging.log(logging.Error, string.inspect(report))

          response.new(400)
          |> web.text_body("Bad Request")
          |> state.return
        }
      }
  }
}

fn finalize_decoder(
  request request: web.Request,
  config config: Config,
  session session: String,
) -> Result(#(Login, Session), Report(Error)) {
  let query =
    request.get_query(request)
    |> result.unwrap([])

  use login <- result.try({
    json.parse(session, login_decoder())
    |> report.map_error(JsonError)
    |> report.error_context(ErrorMessage("decoding of session failed"))
  })

  use state <- result.try(
    list.key_find(query, "state")
    |> report.replace_error(ErrorMessage("state parameter not fond")),
  )

  use <- bool.guard(
    !crypto.secure_compare(<<state:utf8>>, <<login.state:utf8>>),
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
    list.key_find(query, "code")
    |> report.replace_error(ErrorMessage("code parameter not found"))
    |> result.try(get_access_token(code: _, config:, login:))
  })

  let session =
    Session(user:, id_token:, access_token:, code_verifier: login.code_verifier)

  Ok(#(login, session))
}

fn get_signing_keys(
  request: Request(_),
) -> Result(List(VerifyKey), Report(Error)) {
  use response <- result.try(
    httpc.send(request.set_body(request, option.None), [])
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
    |> request.map(option.Some)
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
