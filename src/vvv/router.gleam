import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/erlang/process
import gleam/function.{identity}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import lustre/element
import vvv/auth
import vvv/component
import vvv/frontend
import vvv/session
import vvv/store
import wisp

pub fn service(
  request: wisp.Request,
  store: process.Subject(store.Message),
  oauth_config: auth.Config,
  serve_static: fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  let csrf_token = wisp.random_string(32)
  use csp_nonce <- wisp.content_security_policy_protection()
  use <- serve_static(request)
  use <- wisp.log_request(request)

  case request.method, wisp.path_segments(request) {
    http.Get, [] -> page_handler(request, store:, csrf_token:, csp_nonce:)

    http.Get, ["auth", "login"] ->
      auth.login_handler(request, store:, oauth_config:)

    http.Get, ["auth", "logout"] -> auth.logout_handler(request)
    http.Post, ["auth", "callback"] -> auth.callback_handler(request)
    http.Get, ["auth", "ok"] -> auth.ok_handler(request, store:, oauth_config:)

    _method, _segments -> wisp.not_found()
  }
}

pub fn component_router(
  next_router: fn(Request(_)) -> Response(_),
  secret_key_base: String,
  store: process.Subject(store.Message),
  app: component.Name(Option(session.User), message),
) -> fn(Request(_)) -> Response(_) {
  use request <- identity

  case wisp.path_segments(request) {
    ["components", "app"] -> {
      let session =
        request.get_cookies(request)
        |> list.key_find(auth.cookie_name)
        |> result.try(crypto.verify_signed_message(_, <<secret_key_base:utf8>>))
        |> result.try(bit_array.to_string)
        |> result.try(store.get(store, _))

      case session {
        Error(Nil) -> component.start(request, app, option.None)

        Ok(session.LoginSession(..)) ->
          component.start(request, app, option.None)

        Ok(session.UserSession(user)) -> {
          component.start(request, app, option.Some(user))
        }
      }
    }

    _else -> next_router(request)
  }
}

pub fn page_handler(
  request: wisp.Request,
  store store: process.Subject(store.Message),
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> wisp.Response {
  use request <- wisp.csrf_known_header_protection(request)

  let response =
    wisp.ok()
    |> wisp.html_body(
      element.to_document_string(frontend.page(
        page_title: "vvv",
        csrf_token:,
        csp_nonce:,
      )),
    )

  use <- bool.guard(auth.has_session(request, store), response)
  auth.delete_session(response, request)
}
