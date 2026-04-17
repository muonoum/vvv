import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/static_supervisor as supervisor
import gleam/result
import mist
import mock_auth/router
import wisp
import wisp/wisp_mist
import ywt
import ywt/algorithm

pub fn main() -> Nil {
  wisp.configure_logger()

  let http_address = result.unwrap(envoy.get("HTTP_ADDRESS"), "localhost")

  let assert Ok(http_port) = result.try(envoy.get("HTTP_PORT"), int.parse)
    as "HTTP_PORT"

  let secret_key_base = {
    use <- result.lazy_unwrap(envoy.get("SECRET_KEY_BASE"))
    wisp.random_string(64)
  }

  let key = ywt.generate_key(algorithm.es384)

  let server_spec =
    router.service(_, key)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.bind(http_address)
    |> mist.port(http_port)
    |> mist.supervised

  let assert Ok(_) =
    supervisor.start({
      supervisor.new(supervisor.OneForOne)
      |> supervisor.add(server_spec)
    })

  process.sleep_forever()
}
