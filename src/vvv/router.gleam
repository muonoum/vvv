import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/dynamic/decode.{type Decoder}
import gleam/function.{identity}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import lustre/element
import mist
import vvv/component
import vvv/config.{type Config}
import vvv/extra/httpc
import vvv/frontend
import wisp
import ywt
import ywt/verify_key

type Error {
  UnknownError
  HttpError(httpc.Error)
  JsonError(json.DecodeError)
  JwtError(ywt.ParseError)
}

pub fn service(
  request: wisp.Request,
  config: Config,
  serve_static: fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use request <- wisp.csrf_known_header_protection(request)
  use csp_nonce <- wisp.content_security_policy_protection()
  use <- serve_static(request)
  use <- wisp.log_request(request)

  case request.method, wisp.path_segments(request) {
    http.Get, [] -> top_handler(request, config, csp_nonce)
    http.Get, ["logout"] -> logout_handler(request, config)
    http.Get, ["callback"] -> callback_handler(request, config)
    _method, _segments -> wisp.not_found()
  }
}

pub fn component_router(
  next_router: fn(Request(_)) -> Response(_),
  app: component.Name(Nil, message),
) -> fn(Request(_)) -> Response(_) {
  use request <- identity

  case wisp.path_segments(request) {
    ["components", "app"] -> component_service(request, app, Nil)
    _else -> next_router(request)
  }
}

fn component_service(
  request: Request(mist.Connection),
  name: component.Name(argument, message),
  argument: argument,
) -> Response(mist.ResponseData) {
  let supervisor = factory_supervisor.get_by_name(name)

  case factory_supervisor.start_child(supervisor, argument) {
    Ok(actor.Started(pid: _, data: component)) ->
      component.service(request, component)

    Error(error) -> {
      let message = ["Server component", request.path, string.inspect(error)]
      wisp.log_error(string.join(message, ": "))

      response.new(500)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

fn top_handler(
  request: wisp.Request,
  config: Config,
  csp_nonce: String,
) -> wisp.Response {
  case wisp.get_cookie(request, config.cookie_name, wisp.Signed) {
    Ok(user_id) ->
      wisp.ok()
      |> wisp.html_body(
        frontend.page(page_title: "vvv", user_id:, csp_nonce:)
        |> element.to_document_string,
      )

    Error(Nil) -> {
      let query =
        option.Some(
          uri.query_to_string([
            #("client_id", config.client_id),
            #("redirect_uri", uri.to_string(config.callback_uri)),
            #("state", config.callback_state),
          ]),
        )

      uri.Uri(..config.authorize_uri, query:)
      |> uri.to_string
      |> wisp.redirect
    }
  }
}

fn logout_handler(request: wisp.Request, config: Config) -> wisp.Response {
  case wisp.get_cookie(request, config.cookie_name, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")

    Ok(value) ->
      wisp.redirect("/")
      |> wisp.set_cookie(
        request:,
        name: config.cookie_name,
        value:,
        security: wisp.Signed,
        max_age: 0,
      )
  }
}

fn callback_handler(request: wisp.Request, config: Config) -> wisp.Response {
  let query = wisp.get_query(request)
  let assert Ok(code) = list.key_find(query, "code")
  let assert Ok(callback_state) = list.key_find(query, "state")

  use <- bool.guard(
    callback_state != config.callback_state,
    wisp.bad_request("bad state"),
  )

  let result = {
    use keys <- result.try(get_keys(config.keys_uri))
    use token <- result.try(get_token(config, code))

    use user_id <- result.try(
      ywt.decode(jwt: token, using: token_decoder(), claims: [], keys:)
      |> result.map_error(JwtError),
    )

    Ok(user_id)
  }

  case result {
    Ok(user_id) ->
      wisp.redirect("/")
      |> wisp.set_cookie(
        request:,
        name: config.cookie_name,
        value: user_id,
        security: wisp.Signed,
        max_age: 60 * 60 * 24,
      )

    Error(error) -> {
      wisp.log_error(string.inspect(error))
      wisp.internal_server_error()
    }
  }
}

fn get_keys(keys_uri: Uri) {
  use request <- result.try(
    request.from_uri(keys_uri)
    |> result.replace_error(UnknownError),
  )

  use response <- result.try(
    httpc.send(request.set_body(request, option.None), [])
    |> result.map_error(HttpError),
  )

  json.parse_bits(response.body, verify_key.set_decoder())
  |> result.map_error(JsonError)
}

fn get_token(config: Config, code: String) {
  use request <- result.try(
    request.from_uri(config.token_uri)
    |> result.replace_error(UnknownError),
  )

  let credentials =
    <<config.client_id:utf8, ":":utf8, config.client_secret:utf8>>
    |> bit_array.base64_url_encode(True)

  use response <- result.try(
    request
    |> request.set_query([#("code", code)])
    |> request.set_header("authorization", "Basic " <> credentials)
    |> request.set_body(option.None)
    |> httpc.send([])
    |> result.map_error(HttpError),
  )

  bit_array.to_string(response.body)
  |> result.replace_error(UnknownError)
}

fn token_decoder() -> Decoder(String) {
  use sub <- decode.field("sub", decode.string)
  decode.success(sub)
}
