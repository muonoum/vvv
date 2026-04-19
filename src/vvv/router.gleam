import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
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
    http.Get, [] -> page_handler(request, csrf_token:, csp_nonce:)

    http.Get, ["auth", "login"] -> auth.login_handler(request, oauth_config:)
    http.Get, ["auth", "logout"] -> auth.logout_handler(request)

    http.Post, ["auth", "callback"] ->
      auth.form_post_response(request, auth.callback_handler)

    http.Get, ["auth", "ok"] -> auth.ok_handler(request, oauth_config:)

    _method, _segments -> wisp.not_found()
  }
}

pub fn component_router(
  next_router: fn(Request(_)) -> Response(_),
  secret_key_base: String,
  app: component.Name(Option(auth.User), message),
) -> fn(Request(_)) -> Response(_) {
  use request <- identity

  // TODO: CSRF
  // TODO: Wisp-websockets
  case wisp.path_segments(request) {
    ["components", "app"] -> {
      let session =
        request.get_cookies(request)
        |> list.key_find(auth.cookie_name)
        |> result.try(crypto.verify_signed_message(_, <<secret_key_base:utf8>>))
        |> result.try(bit_array.to_string)

      case session {
        Error(Nil) -> component.start(request, app, option.None)

        Ok(data) -> {
          let user =
            json.parse(data, {
              use name <- decode.field("name", decode.string)
              use email <- decode.field("email", decode.string)
              decode.success(auth.User(name:, email:))
            })

          component.start(request, app, option.from_result(user))
        }
      }
    }

    _else -> next_router(request)
  }
}

fn page_handler(
  request: wisp.Request,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> wisp.Response {
  use _request <- wisp.csrf_known_header_protection(request)

  wisp.ok()
  |> wisp.html_body(
    element.to_document_string(frontend.page(
      page_title: "vvv",
      csrf_token:,
      csp_nonce:,
    )),
  )
}
