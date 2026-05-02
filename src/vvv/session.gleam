import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/result
import vvv/extra
import vvv/state
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
        user_data: dict.new(),
        flash: dict.new(),
        next_flash: dict.new(),
      )

    Ok(value) -> {
      let Data(user:, flash:) = store.load(value)
      Context(value:, user_data: user, flash:, next_flash: dict.new())
    }
  }

  let #(response, context2) = state.run(handler(), context1)
  use <- bool.guard(!changed(context1, context2), response)

  let value =
    store.save(
      context2.value,
      Data(user: context2.user_data, flash: context2.next_flash),
    )

  response.set_cookie(
    response,
    cookie_name,
    crypto.sign_message(<<value:utf8>>, <<signing_key:utf8>>, crypto.Sha512),
    cookie.Attributes(..cookie.defaults(http.Https), max_age: option.None),
  )
}

// STORE

pub opaque type Store {
  Store(load: fn(String) -> Data, save: fn(String, Data) -> String)
}

pub opaque type Data {
  Data(user: Dict(String, String), flash: Dict(String, String))
}

pub fn store(
  load load: fn(String) -> Data,
  save save: fn(String, Data) -> String,
) -> Store {
  Store(load:, save:)
}

pub fn empty_data() -> Data {
  Data(user: dict.new(), flash: dict.new())
}

pub fn data(
  user user: Dict(String, String),
  flash flash: Dict(String, String),
) -> Data {
  Data(user:, flash:)
}

pub fn user_data(data: Data) -> Dict(String, String) {
  data.user
}

pub fn flash_data(data: Data) -> Dict(String, String) {
  data.flash
}

// CONTEXT

pub opaque type Context {
  Context(
    value: String,
    user_data: Dict(String, String),
    flash: Dict(String, String),
    next_flash: Dict(String, String),
  )
}

fn changed(a: Context, b: Context) -> Bool {
  a.user_data != b.user_data || a.flash != b.next_flash
}

// STATE

pub type State(v) =
  state.State(v, Context)

pub fn get(key: String) -> State(Result(String, Nil)) {
  use Context(user_data:, ..) <- state.bind(state.get())
  state.return(dict.get(user_data, key))
}

pub fn delete(key: String) -> State(Nil) {
  use Context(user_data:, ..) as ctx <- state.update
  Context(..ctx, user_data: dict.delete(user_data, key))
}

pub fn put(key: String, value: String) -> State(Nil) {
  use Context(user_data:, ..) as ctx <- state.update()
  Context(..ctx, user_data: dict.insert(user_data, key, value))
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
