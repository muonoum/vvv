import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/function
import gleam/http
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import vvv/extra
import vvv/state.{type State}
import vvv/web

// TODO: Regenerate id
pub opaque type Context {
  Context(id: String, data: Dict(String, String))
}

pub opaque type Store {
  Store(load: fn(String) -> Dict(String, String), save: fn(Context) -> String)
}

pub fn run(
  request: web.Request,
  cookie cookie_name: String,
  store store: Store,
  signing_key signing_key: String,
  handler handler: fn() -> State(web.Response, Context),
) -> web.Response {
  let value =
    request.get_cookies(request)
    |> list.key_find(cookie_name)
    |> result.try(crypto.verify_signed_message(_, <<signing_key:utf8>>))
    |> result.try(bit_array.to_string)

  let context1 = case value {
    Error(Nil) -> Context(id: extra.random_string(32), data: dict.new())
    Ok(value) -> Context(id: value, data: store.load(value))
  }

  let #(response, context2) = state.run(handler(), context1)
  use <- bool.guard(context1 == context2, response)
  let value = store.save(context2)

  let cookie_value =
    crypto.sign_message(<<value:utf8>>, <<signing_key:utf8>>, crypto.Sha512)

  response.set_cookie(
    response,
    cookie_name,
    cookie_value,
    cookie.Attributes(..cookie.defaults(http.Https), max_age: option.None),
  )
}

pub fn get(key: String) -> State(Result(String, Nil), Context) {
  use Context(data:, ..) <- state.bind(state.get())
  state.return(dict.get(data, key))
}

pub fn delete(key: String) -> State(Nil, Context) {
  use Context(data:, ..) as ctx <- state.update
  Context(..ctx, data: dict.delete(data, key))
}

pub fn put(key: String, value: String) -> State(Nil, Context) {
  use Context(data:, ..) as ctx <- state.update()
  Context(..ctx, data: dict.insert(data, key, value))
}

// COOKIE

pub fn cookie_store() -> Store {
  Store(load: load_cookie, save: save_cookie)
}

fn load_cookie(value: String) -> Dict(String, String) {
  parse_cookie(value)
  |> result.lazy_unwrap(dict.new)
}

fn parse_cookie(value: String) -> Result(Dict(String, String), Nil) {
  let decoder = decode.dict(decode.string, decode.string)
  use error <- result.try_recover(json.parse(value, decoder))
  logging.log(logging.Warning, string.inspect(error))
  Error(Nil)
}

fn save_cookie(context: Context) -> String {
  json.dict(context.data, function.identity, json.string)
  |> json.to_string
}
