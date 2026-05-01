import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
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
  Context(value: String, data: Data, next_flash: Dict(String, String))
}

fn context_unchanged(a: Context, b: Context) -> Bool {
  a.data == b.data && a.data.flash == b.next_flash
}

type Data {
  Data(user: Dict(String, String), flash: Dict(String, String))
}

pub opaque type Store {
  Store(load: fn(String) -> Data, save: fn(Context) -> String)
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
    Error(Nil) ->
      Context(
        value: extra.random_string(32),
        data: Data(user: dict.new(), flash: dict.new()),
        next_flash: dict.new(),
      )

    Ok(value) -> {
      let data = store.load(value)
      Context(value:, data:, next_flash: dict.new())
    }
  }

  let #(response, context2) = state.run(handler(), context1)
  use <- bool.guard(context_unchanged(context1, context2), response)
  let value = store.save(context2)

  response.set_cookie(
    response,
    cookie_name,
    crypto.sign_message(<<value:utf8>>, <<signing_key:utf8>>, crypto.Sha512),
    cookie.Attributes(..cookie.defaults(http.Https), max_age: option.None),
  )
}

pub fn get(key: String) -> State(Result(String, Nil), Context) {
  use Context(data:, ..) <- state.bind(state.get())
  state.return(dict.get(data.user, key))
}

pub fn delete(key: String) -> State(Nil, Context) {
  use Context(data:, ..) as ctx <- state.update
  let data = Data(..data, user: dict.delete(data.user, key))
  Context(..ctx, data:)
}

pub fn put(key: String, value: String) -> State(Nil, Context) {
  use Context(data:, ..) as ctx <- state.update()
  let data = Data(..data, user: dict.insert(data.user, key, value))
  Context(..ctx, data:)
}

pub fn get_flash(key: String) -> State(Result(String, Nil), Context) {
  use Context(data:, ..) <- state.bind(state.get())
  state.return(dict.get(data.flash, key))
}

pub fn delete_flash(key: String) -> State(Nil, Context) {
  use Context(next_flash:, ..) as ctx <- state.update
  Context(..ctx, next_flash: dict.delete(next_flash, key))
}

pub fn put_flash(key: String, value: String) -> State(Nil, Context) {
  use Context(next_flash:, ..) as ctx <- state.update()
  Context(..ctx, next_flash: dict.insert(next_flash, key, value))
}

// COOKIE

pub fn cookie_store() -> Store {
  Store(load: load_cookie, save: save_cookie)
}

fn load_cookie(value: String) -> Data {
  use <- result.lazy_unwrap(parse_cookie(value))
  Data(user: dict.new(), flash: dict.new())
}

fn parse_cookie(value: String) -> Result(Data, Nil) {
  use error <- result.try_recover(json.parse(value, cookie_decoder()))
  logging.log(logging.Warning, string.inspect(error))
  Error(Nil)
}

fn cookie_decoder() -> Decoder(Data) {
  use user <- decode.field("user", decode.dict(decode.string, decode.string))
  use flash <- decode.field("flash", decode.dict(decode.string, decode.string))
  decode.success(Data(user:, flash:))
}

fn save_cookie(context: Context) -> String {
  json.to_string(
    json.object([
      #("user", json.dict(context.data.user, function.identity, json.string)),
      #("flash", json.dict(context.next_flash, function.identity, json.string)),
    ]),
  )
}
