import gleam/function
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component
import vvv/app
import vvv/auth
import vvv/extra
import vvv/extra/state
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
  use csp_nonce <- content_security_policy()
  use <- static(request)
  let session = session.handler(request, cookie: "vvv", store:, signing_key:)

  case request.method, request.path_segments(request) {
    http.Get, [] -> {
      use <- session
      use csrf_token <- create_csrf_token
      page_handler(title: "vvv", csrf_token:, csp_nonce:)
    }

    http.Get, ["components", "app"] -> {
      use <- web.verify_origin(request, target_origin)
      use <- session

      use csrf_token <- verify_csrf_token({
        web.get_query_key(request, "csrf-token")
      })

      use user <- state.bind(get_user())
      let status = get_status(request)
      state.return(app_handler(request, app.Args(user:, status:, csrf_token:)))
    }

    http.Post, ["auth", "login"] -> {
      use <- web.verify_origin(request, target_origin)
      use form_data <- web.form_data(request, bytes_limit: 4096)
      use <- session
      use _ <- verify_csrf_token(list.key_find(form_data, "csrf-token"))
      auth.login_handler(request, auth_config)
    }

    http.Post, ["auth", "logout"] -> {
      use <- web.verify_origin(request, target_origin)
      use form_data <- web.form_data(request, bytes_limit: 4096)
      use <- session
      use _ <- verify_csrf_token(list.key_find(form_data, "csrf-token"))
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

fn create_csrf_token(
  next: fn(String) -> session.State(web.Response),
) -> session.State(web.Response) {
  use session_id <- state.bind(session.id())
  let csrf_token = extra.hash_string(session_id)
  next(csrf_token)
}

fn verify_csrf_token(
  csrf_token: Result(String, Nil),
  next: fn(String) -> session.State(web.Response),
) -> session.State(web.Response) {
  use session_id <- state.bind(session.id())
  let expected_csrf_token = extra.hash_string(session_id)

  case csrf_token {
    Ok(csrf_token) if csrf_token == expected_csrf_token -> next(csrf_token)

    Ok(_csrf_token) ->
      response.new(403)
      |> web.text_body("Bad CSRF token")
      |> state.return

    Error(Nil) ->
      response.new(403)
      |> web.text_body("Missing CSRF token")
      |> state.return
  }
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

fn get_status(request: web.Request) -> Option(String) {
  request.get_query(request)
  |> result.try(list.key_find(_, "status"))
  |> option.from_result
}

fn page_handler(
  title title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(web.Response) {
  use page <- state.bind(page(title:, csrf_token:, csp_nonce:))

  state.return(
    response.new(200)
    |> web.html_body(element.to_document_string_tree(page)),
  )
}

fn page(
  title title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(Element(message)) {
  use status <- state.bind({
    session.read_flash("status")
    |> state.map(option.from_result)
  })

  let app_uri =
    Uri(..uri.empty, path: "/components/app", query: {
      option.Some(
        uri.query_to_string(case status {
          option.Some(status) -> [#("status", status)]
          option.None -> []
        }),
      )
    })

  state.return(
    html.html([], [
      html.head([], [
        html.title([], title),
        html.meta([attribute.charset("utf-8")]),
        html.meta([attribute.name("csrf-token"), attribute.content(csrf_token)]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width,initial-scale=1"),
        ]),
        html.link([
          attribute.rel("stylesheet"),
          attribute.href("/app.css"),
          attribute.nonce(csp_nonce),
        ]),
        html.script(
          [
            attribute.type_("module"),
            attribute.src("/lustre/lustre-server-component.mjs"),
            attribute.nonce(csp_nonce),
          ],
          "",
        ),
      ]),
      html.body([], [
        server_component.element(
          [server_component.route(uri.to_string(app_uri))],
          [],
        ),
      ]),
    ]),
  )
}
