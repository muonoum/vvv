import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/function.{identity}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleam/uri
import lustre/element
import mist
import vvv/component
import vvv/frontend
import vvv/httpc
import vvv/oauth
import vvv/session
import vvv/shared
import vvv/store
import wisp
import ywt
import ywt/claim
import ywt/verify_key

const session_cookie = "vvv-session"

pub fn service(
  request: wisp.Request,
  store: process.Subject(store.Message),
  oauth_config: oauth.Config,
  serve_static: fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use csp_nonce <- wisp.content_security_policy_protection()
  use <- serve_static(request)
  use <- wisp.log_request(request)

  case request.method, wisp.path_segments(request) {
    http.Get, [] -> root_handler(request, store:, csp_nonce:)

    http.Get, ["auth", "login"] ->
      auth_login_handler(request, store:, oauth_config:)

    http.Get, ["auth", "logout"] -> auth_logout_handler(request)
    http.Post, ["auth", "callback"] -> auth_callback_handler(request)
    http.Get, ["auth", "ok"] -> auth_ok_handler(request, store:, oauth_config:)

    _method, _segments -> wisp.not_found()
  }
}

pub fn component_router(
  next_router: fn(Request(_)) -> Response(_),
  store: process.Subject(store.Message),
  app: component.Name(process.Subject(store.Message), message),
) -> fn(Request(_)) -> Response(_) {
  use request <- identity

  case wisp.path_segments(request) {
    ["components", "app"] -> component_service(request, app, store)
    _else -> next_router(request)
  }
}

fn component_service(
  request: Request(mist.Connection),
  name: component.Name(argument, message),
  argument: argument,
) -> Response(mist.ResponseData) {
  let supervisor = factory_supervisor.get_by_name(name)

  case factory_supervisor.start_child(supervisor, argument) {
    Ok(actor.Started(pid: _, data: component)) ->
      component.service(request, component)

    Error(error) -> {
      let message = ["Server component", request.path, string.inspect(error)]
      wisp.log_error(string.join(message, ": "))

      response.new(500)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

fn render_page(session_id: Option(String), csp_nonce: String) -> wisp.Response {
  wisp.ok()
  |> wisp.html_body(
    element.to_document_string(frontend.page(
      page_title: "vvv",
      session_id:,
      csp_nonce:,
    )),
  )
}

fn create_session(
  response: wisp.Response,
  request request: wisp.Request,
  store store: process.Subject(store.Message),
  session_id session_id: String,
  value value: session.Session,
  max_age max_age: Int,
) -> wisp.Response {
  store.insert(store, session_id, value)

  response
  |> wisp.set_cookie(
    request:,
    name: session_cookie,
    value: session_id,
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
    name: session_cookie,
    value: "",
    security: wisp.Signed,
    max_age: 0,
  )
}

fn root_handler(
  request: wisp.Request,
  store store: process.Subject(store.Message),
  csp_nonce csp_nonce: String,
) -> wisp.Response {
  use request <- wisp.csrf_known_header_protection(request)

  case wisp.get_cookie(request, session_cookie, wisp.Signed) {
    Error(Nil) -> render_page(option.None, csp_nonce)

    Ok(session_id) -> {
      case store.contains(store, session_id) {
        True -> render_page(option.Some(session_id), csp_nonce)

        False ->
          render_page(option.None, csp_nonce)
          |> delete_session(request)
      }
    }
  }
}

fn auth_login_handler(
  request: wisp.Request,
  store store: process.Subject(store.Message),
  oauth_config oauth_config: oauth.Config,
) -> wisp.Response {
  let #(authorize_uri, session_id, oauth_state) =
    oauth.authorize(
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

fn auth_logout_handler(request: wisp.Request) -> wisp.Response {
  use request <- wisp.csrf_known_header_protection(request)

  case wisp.get_cookie(request, session_cookie, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")
    Ok(..) -> wisp.redirect("/") |> delete_session(request)
  }
}

fn auth_callback_handler(request: wisp.Request) -> wisp.Response {
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

fn auth_ok_handler(
  request: Request(wisp.Connection),
  store store: process.Subject(store.Message),
  oauth_config oauth_config: oauth.Config,
) -> Response(wisp.Body) {
  use request <- wisp.csrf_known_header_protection(request)
  let assert Ok(query) = request.get_query(request)

  let assert Ok(session_id) =
    wisp.get_cookie(request:, name: session_cookie, security: wisp.Signed)

  let assert Ok(True) = {
    use state <- result.map(list.key_find(query, "state"))
    let session_id = shared.hashed_string(session_id)
    crypto.secure_compare(<<session_id:utf8>>, <<state:utf8>>)
  }

  let assert Ok(id_token) = list.key_find(query, "id_token")
  let assert Ok(code) = list.key_find(query, "code")

  let assert Ok(session.LoginSession(oauth_state)) =
    store.get(store, session_id)

  let assert Ok(keys_request) = request.from_uri(oauth_config.jwks_uri)

  let assert Ok(keys_response) =
    httpc.send(request.set_body(keys_request, option.None), [])

  let assert Ok(keys) =
    json.parse_bits(keys_response.body, verify_key.set_decoder())

  let assert Ok(#(name, email)) =
    ywt.decode(jwt: id_token, using: id_token_decoder(), keys:, claims: [
      claim.audience(oauth_config.client_id, []),
      claim.custom("nonce", oauth_state.nonce, json.string, decode.string),
    ])

  let assert Ok(token_request) =
    oauth.get_token(
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
