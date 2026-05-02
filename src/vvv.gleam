import envoy
import ewe
import filepath
import gleam/erlang/application
import gleam/erlang/process
import gleam/function
import gleam/http
import gleam/http/request
import gleam/int
import gleam/option
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/result
import logging
import lustre
import pog
import vvv/app
import vvv/auth
import vvv/extra
import vvv/router
import vvv/session
import vvv/session/actor_store
import vvv/session/cookie_store
import vvv/session/postgres_store
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
  let #(session_store, supervisor, setup_store) = configure_sessions(supervisor)

  let app = process.new_name("app")

  let app_spec =
    lustre.factory(app.component())
    |> factory_supervisor.named(app)
    |> factory_supervisor.supervised

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
    static_supervisor.start({
      supervisor
      |> static_supervisor.add(app_spec)
      |> static_supervisor.add(server_spec)
    })

  setup_store()
  process.sleep_forever()
}

fn configure_sessions(
  supervisor: static_supervisor.Builder,
) -> #(session.Store, static_supervisor.Builder, fn() -> Nil) {
  case envoy.get("SESSION_STORE") {
    Ok("cookie") -> #(cookie_store.new(), supervisor, fn() { Nil })

    Ok("postgres") -> {
      // TODO
      let assert Ok(host) = envoy.get("DB_HOST") as "DB_HOST"
      let assert Ok(user) = envoy.get("DB_USER") as "DB_USER"
      let assert Ok(database) = envoy.get("DB_DATABASE") as "DB_DATABASE"
      let password = option.from_result(envoy.get("DB_PASSWORD"))

      let store_name = process.new_name("store")

      let store_spec =
        postgres_store.supervised(
          store_name,
          host:,
          database:,
          user:,
          password:,
        )

      let connection = pog.named_connection(store_name)
      let store = postgres_store.new(connection)
      let supervisor = static_supervisor.add(supervisor, store_spec)
      #(store, supervisor, fn() { postgres_store.setup(connection) })
    }

    Ok("actor") -> {
      let store_name = process.new_name("store")
      let store_spec = store.supervised(store_name)
      let store = actor_store.new(process.named_subject(store_name))
      let supervisor = static_supervisor.add(supervisor, store_spec)
      #(store, supervisor, fn() { Nil })
    }

    Ok(..) | Error(Nil) -> panic as "SESSION_STORE"
  }
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
