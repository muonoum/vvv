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
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import vvv/extra
import vvv/extra/state
import vvv/web

// TODO: Regenerate id

pub fn run(
  request: web.Request,
  store store: Store,
  cookie cookie_name: String,
  signing_key signing_key: String,
  handler handler: fn() -> State(web.Response),
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
        data: dict.new(),
        flash: dict.new(),
        next_flash: dict.new(),
      )

    Ok(value) -> {
      let Session(data:, flash:) = store.load(value)
      Context(value:, data:, flash:, next_flash: dict.new())
    }
  }

  let #(response, context2) = state.run(handler(), context1)
  use <- bool.guard(!changed(context1, context2), response)

  let value =
    Session(data: context2.data, flash: context2.next_flash)
    |> store.save(context2.value, _)

  response.set_cookie(
    response,
    cookie_name,
    crypto.sign_message(<<value:utf8>>, <<signing_key:utf8>>, crypto.Sha512),
    cookie.Attributes(..cookie.defaults(http.Https), max_age: option.None),
  )
}

// STORE

pub opaque type Store {
  Store(load: fn(String) -> Session, save: fn(String, Session) -> String)
}

pub opaque type Session {
  Session(data: Dict(String, String), flash: Dict(String, String))
}

pub fn store(
  load load: fn(String) -> Session,
  save save: fn(String, Session) -> String,
) -> Store {
  Store(load:, save:)
}

pub fn empty_session() -> Session {
  Session(data: dict.new(), flash: dict.new())
}

pub fn to_json(session: Session) -> String {
  json.to_string(
    json.object([
      #("data", encode_dict(session.data)),
      #("flash", encode_dict(session.flash)),
    ]),
  )
}

fn encode_dict(dict: Dict(String, String)) -> Json {
  json.dict(dict, function.identity, json.string)
}

pub fn session_decoder() -> Decoder(Session) {
  use data <- decode.field("data", dict_decoder())
  use flash <- decode.field("flash", dict_decoder())
  decode.success(Session(data:, flash:))
}

fn dict_decoder() -> Decoder(Dict(String, String)) {
  decode.dict(decode.string, decode.string)
}

// CONTEXT

pub opaque type Context {
  Context(
    value: String,
    data: Dict(String, String),
    flash: Dict(String, String),
    next_flash: Dict(String, String),
  )
}

fn changed(a: Context, b: Context) -> Bool {
  a.data != b.data || a.flash != b.next_flash
}

// STATE

pub type State(v) =
  state.State(v, Context)

pub fn get(key: String) -> State(Result(String, Nil)) {
  use Context(data:, ..) <- state.bind(state.get())
  state.return(dict.get(data, key))
}

pub fn delete(key: String) -> State(Nil) {
  use Context(data:, ..) as ctx <- state.update
  Context(..ctx, data: dict.delete(data, key))
}

pub fn put(key: String, value: String) -> State(Nil) {
  use Context(data:, ..) as ctx <- state.update()
  Context(..ctx, data: dict.insert(data, key, value))
}

pub fn get_flash(key: String) -> State(Result(String, Nil)) {
  use Context(flash:, ..) <- state.bind(state.get())
  state.return(dict.get(flash, key))
}

pub fn delete_flash(key: String) -> State(Nil) {
  use Context(next_flash:, ..) as ctx <- state.update
  Context(..ctx, next_flash: dict.delete(next_flash, key))
}

pub fn put_flash(key: String, value: String) -> State(Nil) {
  use Context(next_flash:, ..) as ctx <- state.update()
  Context(..ctx, next_flash: dict.insert(next_flash, key, value))
}
