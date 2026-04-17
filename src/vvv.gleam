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

  let assert Ok(base_uri) = {
    use uri_string <- result.try(envoy.get("BASE_URI"))
    uri.parse(uri_string)
  }
    as "BASE_URI"

  let assert Ok(callback_uri) =
    result.try(uri.parse("/callback"), uri.merge(base_uri, _))

  let assert Ok(auth_base_uri) = {
    use uri_string <- result.try(envoy.get("AUTH_BASE_URI"))
    uri.parse(uri_string)
  }
    as "AUTH_BASE_URI"

  let assert Ok(auth_client_id) = envoy.get("AUTH_CLIENT_ID")
    as "AUTH_CLIENT_ID"

  let assert Ok(auth_client_secret) = envoy.get("AUTH_CLIENT_SECRET")
    as "AUTH_CLIENT_SECRET"

  let assert Ok(authorize_uri) =
    result.try(uri.parse("/authorize"), uri.merge(auth_base_uri, _))

  let assert Ok(token_uri) =
    result.try(uri.parse("/token"), uri.merge(auth_base_uri, _))

  let assert Ok(keys_uri) =
    result.try(uri.parse("/.well-known/jwks.json"), uri.merge(auth_base_uri, _))

  let config =
    Config(
      cookie_name: "vvv",
      client_id: auth_client_id,
      client_secret: auth_client_secret,
      auth_base_uri:,
      authorize_uri:,
      callback_uri:,
      token_uri:,
      keys_uri:,
      callback_state: wisp.random_string(8),
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
