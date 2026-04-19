import gleam/bit_array
import gleam/crypto
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
import wisp

pub fn service(
  request: wisp.Request,
  auth_config: auth.Config,
  serve_static: fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use csp_nonce <- wisp.content_security_policy_protection()
  use <- serve_static(request)
  use <- wisp.log_request(request)
  use <- auth.router(request, auth_config)

  case request.method, wisp.path_segments(request) {
    http.Get, [] | http.Get, ["other"] -> {
      use request <- wisp.csrf_known_header_protection(request)
      page_handler(request, csrf_token: "TODO", csp_nonce:)
    }

    _method, _segments -> wisp.not_found()
  }
}

// TODO: Wisp-websockets
pub fn component_router(
  next_router: fn(Request(_)) -> Response(_),
  secret_key_base: String,
  app: component.Name(Option(auth.User), message),
) -> fn(Request(_)) -> Response(_) {
  use request <- identity

  case wisp.path_segments(request) {
    ["components", "app"] -> {
      get_user(request, secret_key_base)
      |> component.start(request, app, _)
    }

    _else -> next_router(request)
  }
}

fn get_user(request: Request(_), secret_key_base: String) -> Option(auth.User) {
  request.get_cookies(request)
  |> list.key_find(auth.cookie_name)
  |> result.try(crypto.verify_signed_message(_, <<secret_key_base:utf8>>))
  |> result.try(bit_array.to_string)
  |> option.from_result
  |> option.then(fn(data) {
    json.parse(data, auth.user_decoder())
    |> option.from_result
  })
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
