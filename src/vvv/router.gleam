import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/function.{identity}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import lustre/element
import vvv/auth
import vvv/component
import vvv/frontend
import vvv/store
import wisp

pub fn service(
  request request: wisp.Request,
  auth_config auth_config: auth.Config,
  store store: process.Subject(store.Message),
  static static: fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use <- static(request)
  use <- wisp.log_request(request)
  use csp_nonce <- wisp.content_security_policy_protection()

  case request.method, wisp.path_segments(request) {
    _method, ["auth", ..segments] ->
      auth.router(request, config: auth_config, store:, segments:)

    http.Get, [] -> page_handler(request, csp_nonce:, csrf_token: "TODO")
    _method, _segments -> wisp.not_found()
  }
}

// TODO: Wisp-websockets
pub fn component_router(
  next_router: fn(Request(_)) -> Response(_),
  app app: component.Name(Result(Option(auth.User), String), message),
  store store: process.Subject(store.Message),
  secret_key_base secret_key_base: String,
) -> fn(Request(_)) -> Response(_) {
  use request: Request(_) <- identity

  case request.method, wisp.path_segments(request) {
    http.Get, ["components", "app"] -> {
      get_user(request, store, secret_key_base)
      |> component.start(request, app, _)
    }

    _method, _segments -> next_router(request)
  }
}

fn get_user(
  request: Request(_),
  store: process.Subject(store.Message),
  secret_key_base: String,
) -> Result(Option(auth.User), String) {
  let cookies = request.get_cookies(request)

  case list.key_find(cookies, auth.session_cookie) {
    Error(Nil) -> Ok(option.None)

    Ok(cookie) -> {
      case crypto.verify_signed_message(cookie, <<secret_key_base:utf8>>) {
        Error(Nil) -> Error("could not read session cookie")

        Ok(message) ->
          bit_array.to_string(message)
          |> result.replace_error("could not decode session")
          |> result.try(fn(session_id) {
            store.get(store, session_id)
            |> result.replace_error("session not found")
            |> result.map(json.to_string)
          })
          |> result.try(fn(data) {
            json.parse(data, auth.session_decoder())
            |> result.replace_error("could not parse session")
            |> result.map(fn(session) { option.Some(session.user) })
          })
      }
    }
  }
}

fn page_handler(
  _request: wisp.Request,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> wisp.Response {
  wisp.ok()
  |> wisp.html_body(
    element.to_document_string(frontend.page(
      page_title: "vvv",
      csrf_token:,
      csp_nonce:,
    )),
  )
}
