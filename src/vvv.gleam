import envoy
import ewe
import filepath
import gleam/erlang/application
import gleam/erlang/process
import gleam/function
import gleam/http
import gleam/http/request
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/result
import logging
import lustre
import vvv/app
import vvv/auth
import vvv/extra
import vvv/router
import vvv/session/actor_store
import vvv/session/cookie_store
import vvv/session/postgres_store
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

  let supervisor = supervisor.new(supervisor.OneForOne)

  let #(session_store, supervisor, initialise_session_store) = {
    case envoy.get("SESSION_STORE") {
      Ok("cookie") -> cookie_store.new(supervisor)
      Ok("postgres") -> postgres_store.new(supervisor)
      Ok("actor") -> actor_store.new(supervisor)
      Ok(..) | Error(Nil) -> panic as "SESSION_STORE"
    }
  }

  let app = process.new_name("app")

  let app_spec =
    lustre.factory(app.component())
    |> factory.named(app)
    |> factory.supervised

  let assert Ok(auth_config) = auth.configure_from_environment()

  let handler =
    router.service(
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
    supervisor.start({
      supervisor
      |> supervisor.add(app_spec)
      |> supervisor.add(server_spec)
    })

  case initialise_session_store() {
    Error(error) -> panic as error
    Ok(Nil) -> Nil
  }

  process.sleep_forever()
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
