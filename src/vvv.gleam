import envoy
import filepath
import gleam/erlang/application
import gleam/erlang/process
import gleam/function.{identity}
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/uri
import lustre
import mist
import vvv/components/app
import vvv/config.{Config}
import vvv/router
import vvv/store
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(priv_directory) = application.priv_directory("vvv")

  let http_address = result.unwrap(envoy.get("HTTP_ADDRESS"), "localhost")

  let assert Ok(http_port) = result.try(envoy.get("HTTP_PORT"), int.parse)
    as "HTTP_PORT"

  let secret_key_base = {
    use <- result.lazy_unwrap(envoy.get("SECRET_KEY_BASE"))
    wisp.random_string(64)
  }

  let assert Ok(client_id) = envoy.get("CLIENT_ID") as "CLIENT_ID"

  let assert Ok(client_secret) = envoy.get("CLIENT_SECRET") as "CLIENT_SECRET"

  let assert Ok(redirect_uri) =
    envoy.get("REDIRECT_URI")
    |> result.try(uri.parse)
    as "REDIRECT_URI"

  let assert Ok(authorize_uri) =
    envoy.get("AUTHORIZE_URI")
    |> result.try(uri.parse)
    as "AUTHORIZE_URI"

  let assert Ok(jwks_uri) =
    envoy.get("JWKS_URI")
    |> result.try(uri.parse)
    as "JWKS_URI"

  let assert Ok(token_uri) =
    envoy.get("TOKEN_URI")
    |> result.try(uri.parse)
    as "TOKEN_URI"

  let store_name = process.new_name("vvv-store")
  let store_spec = store.supervised(store_name)
  let store = process.named_subject(store_name)

  let config =
    Config(
      store:,
      client_id:,
      client_secret:,
      redirect_uri:,
      authorize_uri:,
      jwks_uri:,
      token_uri:,
    )

  let app_component_name = process.new_name("vvv")

  let server_spec =
    router.service(_, config, static_handler(priv_directory))
    |> wisp_mist.handler(secret_key_base)
    |> router.component_router(app_component_name)
    |> mist.new
    |> mist.bind(http_address)
    |> mist.port(http_port)
    |> mist.supervised

  let app_spec =
    app.component()
    |> lustre.factory
    |> factory.named(app_component_name)
    |> factory.supervised

  let assert Ok(_) =
    supervisor.start({
      supervisor.new(supervisor.OneForOne)
      |> supervisor.add(store_spec)
      |> supervisor.add(app_spec)
      |> supervisor.add(server_spec)
    })

  process.sleep_forever()
}

fn static_handler(
  priv_directory: String,
) -> fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response {
  let app = filepath.join(priv_directory, "static")

  let assert Ok(lustre) =
    application.priv_directory("lustre")
    |> result.map(filepath.join(_, "static"))
    as "lustre/static"

  use request, then <- identity
  use <- wisp.serve_static(request, under: "/", from: app)
  use <- wisp.serve_static(request, under: "/lustre", from: lustre)
  then()
}
