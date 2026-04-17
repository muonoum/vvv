import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/function
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/result
import gleam/uri

@external(erlang, "glue", "configure_proxy")
pub fn configure_proxy(
  host: String,
  port: Int,
  exceptions: List(String),
) -> Result(Nil, Dynamic)

pub type Timeout {
  Infinity
  Millis(Int)
}

pub type Option =
  fn(Config) -> Config

pub opaque type Config {
  Config(
    auto_redirect: Bool,
    ca_certs: option.Option(String),
    connect_timeout: Timeout,
    timeout: Timeout,
  )
}

const default_config = Config(
  auto_redirect: True,
  ca_certs: option.None,
  // TODO: Defaults
  connect_timeout: Millis(1000),
  timeout: Millis(10_000),
)

pub fn optional(v: option.Option(a), f: fn(a) -> fn(b) -> b) -> fn(b) -> b {
  option.map(v, f)
  |> option.unwrap(function.identity)
}

pub fn auto_redirect(enabled: Bool) -> Option {
  fn(config) { Config(..config, auto_redirect: enabled) }
}

pub fn ca_certs(path: String) -> Option {
  fn(config) { Config(..config, ca_certs: option.Some(path)) }
}

pub fn connect_timeout(timeout: Timeout) -> Option {
  fn(config) { Config(..config, connect_timeout: timeout) }
}

pub fn timeout(timeout: Timeout) -> Option {
  fn(config) { Config(..config, timeout: timeout) }
}

pub type Request(body) =
  request.Request(option.Option(body))

pub type Response =
  response.Response(BitArray)

pub opaque type Error {
  ClientError(Dynamic)
  StatusError(Int, BitArray)
}

pub fn send(
  request: Request(BytesTree),
  options: List(Option),
) -> Result(Response, Error) {
  use response <- result.try(
    glue_send(request, options)
    |> result.map_error(ClientError),
  )

  use <- bool.guard(
    response.status < 200 || response.status >= 300,
    Error(StatusError(response.status, response.body)),
  )

  Ok(response)
}

@external(erlang, "glue", "request")
fn glue_request(
  config: Config,
  method: http.Method,
  uri: String,
  headers: List(#(String, String)),
) -> Result(a, Dynamic)

@external(erlang, "glue", "request")
fn glue_request_with_body(
  config: Config,
  method: http.Method,
  uri: String,
  headers: List(#(String, String)),
  content_type: String,
  body: BytesTree,
) -> Result(a, Dynamic)

fn glue_send(
  request: Request(BytesTree),
  options: List(Option),
) -> Result(response.Response(_), Dynamic) {
  let uri = uri.to_string(request.to_uri(request))
  let config =
    list.fold(options, default_config, fn(config, update) { update(config) })

  let body = case request.method, request.body {
    http.Post, option.None -> option.Some(bytes_tree.new())
    http.Put, option.None -> option.Some(bytes_tree.new())
    http.Patch, option.None -> option.Some(bytes_tree.new())
    http.Delete, option.None -> option.Some(bytes_tree.new())
    _method, body -> body
  }

  case body {
    option.None -> glue_request(config, request.method, uri, request.headers)

    option.Some(body) -> {
      let content_type =
        request.get_header(request, "content-type")
        |> result.unwrap("application/octet-stream")

      glue_request_with_body(
        config,
        request.method,
        uri,
        request.headers,
        content_type,
        body,
      )
    }
  }
}
