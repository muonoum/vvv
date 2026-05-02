import envoy
import ewe
import filepath
import gleam/erlang/application
import gleam/erlang/process
import gleam/function
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/option
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import logging
import lustre
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component
import vvv/app
import vvv/auth
import vvv/component
import vvv/extra
import vvv/page
import vvv/session
import vvv/session/actor_store
import vvv/session/cookie_store
import vvv/state
import vvv/store
import vvv/web

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  let http_address =
    envoy.get("HTTP_ADDRESS")
    |> result.unwrap("localhost")

  let assert Ok(http_port) =
    envoy.get("HTTP_PORT")
    |> result.try(int.parse)
    as "HTTP_PORT"

  let signing_key = {
    use <- result.lazy_unwrap(envoy.get("SIGNING_KEY"))
    extra.random_string(64)
  }

  let supervisor = static_supervisor.new(static_supervisor.OneForOne)
  let #(session_store, supervisor) = configure_sessions(supervisor)

  let app = process.new_name("app")

  let app_spec =
    lustre.factory(app.component())
    |> factory_supervisor.named(app)
    |> factory_supervisor.supervised

  let assert Ok(auth_config) = auth.configure_from_environment()

  let handler =
    router(
      app:,
      auth_config:,
      session_store:,
      static_handler: static_handler(),
      signing_key:,
    )

  let server_spec =
    ewe.new(handler)
    |> ewe.bind(http_address)
    |> ewe.listening(http_port)
    |> ewe.supervised

  let assert Ok(_) =
    static_supervisor.start({
      supervisor
      |> static_supervisor.add(app_spec)
      |> static_supervisor.add(server_spec)
    })

  process.sleep_forever()
}

fn configure_sessions(
  supervisor: static_supervisor.Builder,
) -> #(session.Store, static_supervisor.Builder) {
  case envoy.get("SESSION_STORE") {
    Ok("cookie") -> #(cookie_store.new(), supervisor)

    Ok("actor") -> {
      let store_name = process.new_name("store")
      let store_spec = store.supervised(store_name)

      let session_store =
        process.named_subject(store_name)
        |> actor_store.new

      #(session_store, static_supervisor.add(supervisor, store_spec))
    }

    Ok(..) | Error(Nil) -> panic as "SESSION_STORE"
  }
}

fn router(
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

  let session = session.run(
    request,
    store:,
    cookie: "vvv",
    signing_key:,
    handler: _,
  )

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

fn static_handler() -> fn(web.Request, fn() -> web.Response) -> web.Response {
  let assert Ok(app_static) =
    application.priv_directory("vvv")
    |> result.map(filepath.join(_, "static"))
    as "app/static"

  let assert Ok(lustre_static) =
    application.priv_directory("lustre")
    |> result.map(filepath.join(_, "static"))
    as "lustre/static"

  let app_assets = web.load_assets(app_static)
  let lustre_assets = web.load_assets(lustre_static)
  use request: web.Request, next: fn() -> web.Response <- function.identity

  case request.method, request.path_segments(request) {
    http.Get, ["lustre", ..segments] ->
      web.serve_assets(lustre_assets, request:, segments:, next:)

    http.Get, segments ->
      web.serve_assets(app_assets, request:, segments:, next:)

    _method, _segments -> next()
  }
}
