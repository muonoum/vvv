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
import gleam/uri
import lustre/element
import mist
import vvv/component
import vvv/config.{type Config}
import vvv/extra/httpc
import vvv/frontend
import vvv/oauth
import vvv/store
import wisp
import ywt
import ywt/claim
import ywt/verify_key

const id_cookie = "vvv-id"

pub fn service(
  request: wisp.Request,
  config: Config,
  serve_static: fn(wisp.Request, fn() -> wisp.Response) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use csp_nonce <- wisp.content_security_policy_protection()
  use <- serve_static(request)
  use <- wisp.log_request(request)

  case request.method, wisp.path_segments(request) {
    http.Get, [] -> {
      use request <- wisp.csrf_known_header_protection(request)
      top_handler(request, config, csp_nonce)
    }

    http.Get, ["logout"] -> {
      use request <- wisp.csrf_known_header_protection(request)
      logout_handler(request)
    }

    http.Post, ["callback"] -> callback_handler(request, config)
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
  case wisp.get_cookie(request, id_cookie, wisp.Signed) {
    Ok(user_id) ->
      wisp.ok()
      |> wisp.html_body(
        frontend.page(page_title: "vvv", user_id:, csp_nonce:)
        |> element.to_document_string,
      )

    Error(Nil) -> {
      let #(uri, key, state) =
        oauth.authorize(
          uri: config.authorize_uri,
          client_id: config.client_id,
          redirect_uri: config.redirect_uri,
          scope: ["openid", "profile", "email"],
        )

      store.save(config.store, key, state)
      wisp.redirect(uri.to_string(uri))
    }
  }
}

fn logout_handler(request: wisp.Request) -> wisp.Response {
  case wisp.get_cookie(request, id_cookie, wisp.Signed) {
    Error(Nil) -> wisp.redirect("/")

    Ok(value) ->
      wisp.redirect("/")
      |> wisp.set_cookie(
        request:,
        name: id_cookie,
        value:,
        security: wisp.Signed,
        max_age: 0,
      )
  }
}

fn callback_handler(request: wisp.Request, config: Config) -> wisp.Response {
  use form_data <- wisp.require_form(request)

  let assert Ok(code) = list.key_find(form_data.values, "code")
  let assert Ok(id_token) = list.key_find(form_data.values, "id_token")

  let assert Ok(state) =
    list.key_find(form_data.values, "state")
    |> result.try(store.load(config.store, _))

  let assert Ok(keys_request) = request.from_uri(config.jwks_uri)

  let assert Ok(keys_response) =
    httpc.send(request.set_body(keys_request, option.None), [])

  let assert Ok(keys) =
    json.parse_bits(keys_response.body, verify_key.set_decoder())

  let assert Ok(#(_name, email)) =
    ywt.decode(jwt: id_token, using: id_token_decoder(), keys:, claims: [
      claim.audience(config.client_id, []),
      claim.custom("nonce", state.nonce, json.string, decode.string),
    ])

  let assert Ok(token_request) =
    oauth.get_token(
      uri: config.token_uri,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: config.redirect_uri,
      scope: ["openid", "profile", "email"],
      code_verifier: state.code_verifier,
      code:,
    )

  let assert Ok(token_response) = {
    token_request
    |> request.map(bytes_tree.from_string)
    |> request.map(option.Some)
    |> httpc.send([])
  }

  let assert Ok(#(access_token, _, _, _)) =
    json.parse_bits(token_response.body, access_token_decoder())

  echo #("access_token", access_token)

  wisp.redirect("/")
  |> wisp.set_cookie(
    request:,
    name: id_cookie,
    value: email,
    security: wisp.Signed,
    max_age: 60 * 60 * 24,
  )
}

fn id_token_decoder() -> Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(#(name, email))
}

fn access_token_decoder() -> Decoder(#(String, String, Int, String)) {
  use access_token <- decode.field("access_token", decode.string)
  use scope <- decode.field("scope", decode.string)
  use expires_in <- decode.field("expires_in", decode.int)
  use token_type <- decode.field("token_type", decode.string)
  decode.success(#(access_token, scope, expires_in, token_type))
}
