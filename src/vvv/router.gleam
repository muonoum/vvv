import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/function.{identity}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import lustre/element
import mist
import snag
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
      let authorize =
        oauth.authorize_uri(
          uri: config.authorize_uri,
          client_id: config.client_id,
          redirect_uri: config.redirect_uri,
          scope: ["openid", "profile", "email"],
        )

      store.save(config.store, authorize)
      wisp.redirect(uri.to_string(authorize.uri))
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
  let assert Ok(callback_state) = list.key_find(form_data.values, "state")
  let assert Ok(id_token) = list.key_find(form_data.values, "id_token")
  let assert Ok(authorize) = store.load(config.store, callback_state)

  use <- bool.guard(
    callback_state != authorize.state,
    wisp.bad_request("bad state"),
  )

  let result = {
    use keys <- result.try(get_keys(config.jwks_uri))
    use token <- result.try(get_token(config, authorize.code_verifier, code))
    echo #("access_token", token)

    let claims = [
      claim.audience(config.client_id, []),
      claim.custom(
        name: "nonce",
        value: authorize.nonce,
        decoder: decode.string,
        encode: json.string,
      ),
    ]

    let token_decoder = {
      use name <- decode.field("name", decode.string)
      use email <- decode.field("email", decode.string)
      decode.success(#(name, email))
    }

    use id_token <- result.try(
      ywt.decode(jwt: id_token, using: token_decoder, claims:, keys:)
      |> snag.map_error(string.inspect)
      |> snag.context("could not decode token"),
    )

    Ok(id_token)
  }

  case result {
    Ok(#(_name, email)) ->
      wisp.redirect("/")
      |> wisp.set_cookie(
        request:,
        name: id_cookie,
        value: email,
        security: wisp.Signed,
        max_age: 60 * 60 * 24,
      )

    Error(error) -> {
      wisp.log_error(snag.line_print(error))
      wisp.internal_server_error()
    }
  }
}

fn get_keys(keys_uri: Uri) {
  use request <- result.try(
    request.from_uri(keys_uri)
    |> snag.replace_error("could not create keys request"),
  )

  use Response(body:, ..) <- result.try(
    httpc.send(request.set_body(request, None), [])
    |> snag.map_error(string.inspect)
    |> snag.context("could not send key request"),
  )

  json.parse_bits(body, verify_key.set_decoder())
  |> snag.map_error(string.inspect)
  |> snag.context("could not parse keys")
}

fn get_token(config: Config, code_verifier: String, code: String) {
  use token_request <- result.try(
    oauth.token_request(
      uri: config.token_uri,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: config.redirect_uri,
      scope: ["openid", "profile", "email"],
      code_verifier:,
      code:,
    )
    |> snag.replace_error("could not create token request"),
  )

  use response <- result.try(
    token_request
    |> httpc.send([])
    |> snag.map_error(string.inspect)
    |> snag.context("could not send token request"),
  )

  bit_array.to_string(response.body)
  |> snag.replace_error("bad token response")
}
