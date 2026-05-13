import gleam/bool
import gleam/function
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleam/uri.{type Uri}
import vvv/app
import vvv/auth
import vvv/extra
import vvv/extra/state
import vvv/page
import vvv/session
import vvv/web

pub fn service(
  app_handler app_handler: fn(web.Request, app.Args) -> web.Response,
  target_origin target_origin: Uri,
  auth_config auth_config: auth.Config,
  session_store store: session.Store,
  static_handler static: fn(web.Request, fn() -> web.Response) -> web.Response,
  signing_key signing_key: String,
) -> fn(web.Request) -> web.Response {
  use request <- function.identity
  use <- web.rescue_crashes
  use <- web.log_request(request)
  use <- static(request)

  let session = session.start(request, store:, cookie_name: "vvv", signing_key:)

  case request.method, request.path_segments(request) {
    http.Get, [] -> {
      use csp_nonce <- content_security_policy()
      use <- session
      use csrf_token <- create_csrf_token
      page.handler(title: "vvv", csrf_token:, csp_nonce:)
    }

    http.Get, ["components", "app"] -> {
      use <- web.verify_origin(request, target_origin)
      use query <- parse_query(request)
      use csrf_token <- get_key(query, "csrf-token")
      use <- session
      use <- verify_csrf_token(csrf_token)
      use user <- state.bind(get_user())

      let status =
        list.key_find(query, "status")
        |> option.from_result

      app.Args(user:, status:, csrf_token:)
      |> app_handler(request, _)
      |> state.return
    }

    http.Post, ["auth", "login"] -> {
      use <- web.verify_origin(request, target_origin)
      use form <- web.form_data(request, bytes_limit: 1024)
      use csrf_token <- get_key(form, "csrf-token")
      use <- session
      use <- verify_csrf_token(csrf_token)
      auth.login_handler(request, auth_config)
    }

    http.Post, ["auth", "logout"] -> {
      use <- web.verify_origin(request, target_origin)
      use form <- web.form_data(request, bytes_limit: 1024)
      use csrf_token <- get_key(form, "csrf-token")
      use <- session
      use <- verify_csrf_token(csrf_token)
      auth.logout_handler(request)
    }

    http.Post, ["auth", "callback"] -> auth.callback_handler(request)

    http.Get, ["auth", "finalize"] -> {
      use <- session
      auth.finalize_handler(request, auth_config)
    }

    _method, _segments -> web.text_body(response.new(404), "Not Found")
  }
}

fn content_security_policy(next: fn(String) -> web.Response) -> web.Response {
  let nonce = extra.random_string(24)

  let policy = [
    "script-src 'self', script-src 'nonce-" <> nonce <> "'",
    "style-src 'self', style-src 'nonce-" <> nonce <> "'",
    "base-uri 'none'",
    "object-src 'none'",
  ]

  let header = string.join(policy, "; ")

  next(nonce)
  |> response.set_header("content-security-policy", header)
}

fn parse_query(
  request: web.Request,
  next: fn(List(#(String, String))) -> web.Response,
) -> web.Response {
  case request.get_query(request) {
    Error(Nil) -> web.text_body(response.new(400), "Bad Request")
    Ok(pairs) -> next(pairs)
  }
}

fn get_key(
  pairs: List(#(String, String)),
  key: String,
  next: fn(String) -> web.Response,
) -> web.Response {
  case list.key_find(pairs, key) {
    Error(Nil) -> web.text_body(response.new(400), "Bad Request")
    Ok(value) -> next(value)
  }
}

fn create_csrf_token(
  next: fn(String) -> session.State(web.Response),
) -> session.State(web.Response) {
  use session_id <- state.bind(session.id())
  next(extra.hash_string(session_id))
}

fn verify_csrf_token(
  csrf_token: String,
  continue: fn() -> session.State(web.Response),
) -> session.State(web.Response) {
  use expected <- create_csrf_token
  use <- bool.lazy_guard(csrf_token == expected, continue)
  state.return(web.text_body(response.new(403), "Bad CSRF token"))
}

fn get_user() -> session.State(app.User) {
  use login <- state.bind(session.read("login"))
  use <- extra.return(state.return)

  case login {
    Error(Nil) -> Ok(option.None)

    Ok(auth) ->
      case json.parse(auth, auth.session_decoder()) {
        Error(error) -> Error(string.inspect(error))
        Ok(auth.Session(user:, ..)) -> Ok(option.Some(user))
      }
  }
}
