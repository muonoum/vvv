import envoy
import filepath
import gleam/erlang/application
import gleam/erlang/process
import gleam/function
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/result
import lustre
import mist
import vvv/app
import vvv/oauth
import vvv/router
import vvv/store
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let http_address = envoy.get("HTTP_ADDRESS") |> result.unwrap("localhost")
  let assert Ok(http_port) = envoy.get("HTTP_PORT") |> result.try(int.parse)
    as "HTTP_PORT"

  let secret_key_base = {
    use <- result.lazy_unwrap(envoy.get("SECRET_KEY_BASE"))
    wisp.random_string(64)
  }

  let assert Ok(oauth_config) = oauth.from_environment()

  let app_name = process.new_name("app")
  let store_name = process.new_name("store")
  let store = process.named_subject(store_name)

  let store_spec = store.supervised(store_name)

  let app_spec =
    app.component()
    |> lustre.factory
    |> factory.named(app_name)
    |> factory.supervised

  let server_spec =
    router.service(_, store, oauth_config, static_handler())
    |> wisp_mist.handler(secret_key_base)
    |> router.component_router(store, app_name)
    |> mist.new
    |> mist.bind(http_address)
    |> mist.port(http_port)
    |> mist.supervised

  let assert Ok(_) =
    supervisor.start({
      supervisor.new(supervisor.OneForOne)
      |> supervisor.add(store_spec)
      |> supervisor.add(app_spec)
      |> supervisor.add(server_spec)
    })

  process.sleep_forever()
}

fn static_handler() -> fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response {
  let assert Ok(priv_directory) = application.priv_directory("vvv")
  let app = filepath.join(priv_directory, "static")

  let assert Ok(lustre) =
    application.priv_directory("lustre")
    |> result.map(filepath.join(_, "static"))
    as "lustre/static"

  use request, next <- function.identity
  use <- wisp.serve_static(request, under: "/", from: app)
  use <- wisp.serve_static(request, under: "/lustre", from: lustre)
  next()
}
