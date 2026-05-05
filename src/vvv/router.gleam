import ewe
import gleam/bool
import gleam/function
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
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
  app app: component.Name(app.Arguments, app.Message),
  auth_config auth_config: auth.Config,
  session_store store: session.Store,
  static_handler static: fn(web.Request, fn() -> web.Response) -> web.Response,
  signing_key signing_key: String,
) -> fn(web.Request) -> web.Response {
  use request <- function.identity
  use <- web.rescue
  use <- web.log(request)
  use <- static(request)

  let session = session.handler(request, cookie: "vvv", store:, signing_key:)

  case request.method, request.path_segments(request) {
    _method, ["auth", ..segments] ->
      auth.router(request, config: auth_config, session:, segments:)

    http.Get, [] -> {
      use csp_nonce <- web.csp_nonce()
      use <- session
      let csrf_token = extra.random_string(32)
      use <- state.do(session.insert("csrf-token", csrf_token))
      page_handler(title: "vvv", csrf_token:, csp_nonce:)
    }

    http.Get, ["components", "app"] -> {
      use <- session
      use csrf_token <- state.bind(session.read("csrf-token"))

      let request_csrf_token =
        request.get_query(request)
        |> result.try(list.key_find(_, "csrf-token"))

      use <- bool.lazy_guard(request_csrf_token != csrf_token, fn() {
        response.new(403)
        |> web.text_body("Forbidden")
        |> state.return
      })

      use user <- state.bind(get_user())

      let status =
        request.get_query(request)
        |> result.try(list.key_find(_, "status"))
        |> option.from_result

      component.start(request, app, #(user, status))
      |> state.return
    }

    _method, _segments ->
      response.new(404)
      |> web.text_body("Not Found")
  }
}

fn get_user() -> session.State(page.User) {
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

fn page_handler(
  title title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(web.Response) {
  use document <- state.bind(document(title:, csrf_token:, csp_nonce:))

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
  use user <- state.bind(get_user())

  use status <- state.bind({
    session.read_flash("status")
    |> state.map(option.from_result)
  })

  use <- extra.return(state.return)
  let query = [#("csrf-token", csrf_token)]

  let app_uri =
    uri.Uri(..uri.empty, path: "/components/app", query: {
      option.Some(
        uri.query_to_string(case status {
          option.None -> query
          option.Some(status) -> [#("status", status), ..query]
        }),
      )
    })

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
      server_component.element(
        [server_component.route(uri.to_string(app_uri))],
        [],
      ),
      page.view(user, status),
    ]),
  ])
}
