import ewe
import gleam/function
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component
import vvv/app
import vvv/auth
import vvv/component
import vvv/extra
import vvv/extra/state
import vvv/page
import vvv/session
import vvv/web

pub fn service(
  app app: app.Component,
  auth_config auth_config: auth.Config,
  session_store store: session.Store,
  static_handler static: fn(web.Request, fn() -> web.Response) -> web.Response,
  signing_key signing_key: String,
) -> fn(web.Request) -> web.Response {
  use request <- function.identity
  use <- web.rescue
  use <- web.log(request)
  use <- static(request)

  let session = session.handler(request, store:, cookie: "vvv", signing_key:)

  case request.method, request.path_segments(request) {
    http.Get, [] -> {
      use csp_nonce <- web.csp_nonce()
      use <- session
      page_handler(title: "vvv", csrf_token: "TODO", csp_nonce:)
    }

    http.Get, ["auth", "login"] -> {
      use <- session
      auth.login_handler(request, auth_config)
    }

    http.Get, ["auth", "logout"] -> {
      use <- session
      auth.logout_handler(request)
    }

    http.Post, ["auth", "callback"] -> auth.callback_handler(request)

    http.Get, ["auth", "finalize"] -> {
      use <- session
      auth.finalize_handler(request, auth_config)
    }

    http.Get, ["components", "app"] -> {
      use <- session
      use #(user, _status) <- state.bind(get_login())
      state.return(component.start(request, app, user))
    }

    _method, _segments ->
      response.new(404)
      |> web.text_body("Not Found")
  }
}

fn get_login() -> session.State(#(page.User, page.Status)) {
  use login <- state.bind(session.get("login"))
  use status <- state.bind(session.get_flash("status"))

  let user = case login {
    Error(Nil) -> Ok(option.None)

    Ok(auth) ->
      case json.parse(auth, auth.session_decoder()) {
        Error(error) -> Error(string.inspect(error))
        Ok(auth.Session(user:, ..)) -> Ok(option.Some(user))
      }
  }

  state.return(#(user, status))
}

fn page_handler(
  title _title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(web.Response) {
  use document <- state.bind(document(title: "vvv", csrf_token:, csp_nonce:))

  state.return(
    response.new(200)
    |> response.set_header("content-type", "text/html; charset=utf-8")
    |> response.set_body(
      ewe.StringTreeData(element.to_document_string_tree(document)),
    ),
  )
}

fn document(
  title title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(Element(message)) {
  use #(user, status) <- state.bind(get_login())
  use <- extra.return(state.return)

  html.html([], [
    html.head([], [
      html.title([], title),
      html.meta([attribute.charset("utf-8")]),
      html.meta([attribute.name("csrf-token"), attribute.content(csrf_token)]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width,initial-scale=1"),
      ]),
      html.link([attribute.rel("stylesheet"), attribute.href("/app.css")]),
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
      server_component.element([server_component.route("/components/app")], []),
      page.view(user, status),
    ]),
  ])
}
