import gleam/http
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/duration
import gleam/uri.{Uri}
import wisp
import ywt
import ywt/claim
import ywt/sign_key.{type SignKey}
import ywt/verify_key

pub fn service(request: wisp.Request, key: SignKey) -> wisp.Response {
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use request <- wisp.csrf_known_header_protection(request)
  use <- wisp.log_request(request)

  case request.method, wisp.path_segments(request) {
    http.Get, ["authorize"] -> authorize_handler(request)
    http.Get, ["token"] -> token_handler(request, key)

    http.Get, [".well-known", "jwks.json"] -> {
      verify_key.to_jwks([verify_key.derived(key)])
      |> json.to_string
      |> wisp.json_response(200)
    }

    _method, _segments -> wisp.not_found()
  }
}

fn authorize_handler(request: wisp.Request) -> wisp.Response {
  let query = wisp.get_query(request)
  let assert Ok(_client_id) = list.key_find(query, "client_id")
  let assert Ok(state) = list.key_find(query, "state")
  let assert Ok(redirect_uri) = list.key_find(query, "redirect_uri")
  let code = wisp.random_string(16)

  let assert Ok(redirect_uri) = {
    use uri <- result.map(uri.parse(redirect_uri))
    let query = uri.query_to_string([#("code", code), #("state", state)])
    Uri(..uri, query: Some(query))
  }

  wisp.redirect(uri.to_string(redirect_uri))
}

fn token_handler(request: wisp.Request, sign_key: SignKey) -> wisp.Response {
  let query = wisp.get_query(request)
  let assert Ok(_code) = list.key_find(query, "code")
  let payload = []

  let claims = [
    claim.subject("mock-user", []),
    claim.expires_at(max_age: duration.seconds(10), leeway: duration.seconds(5)),
  ]

  let jwt = ywt.encode(payload, claims, sign_key)
  wisp.string_body(wisp.ok(), jwt)
}
