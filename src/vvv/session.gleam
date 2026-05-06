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
import vvv/extra/log
import vvv/extra/state
import vvv/web

// TODO: Rydde bort gamle sessions
pub opaque type Store {
  Store(
    load: fn(String) -> Session,
    delete: fn(String) -> Nil,
    save: fn(String, Session) -> String,
  )
}

pub opaque type Session {
  Session(data: Dict(String, String), flash: Dict(String, String))
}

pub type State(v) =
  state.State(v, Context)

pub opaque type Context {
  Context(
    id: String,
    data: Dict(String, String),
    flash: Dict(String, String),
    next_flash: Dict(String, String),
  )
}

pub type Handler =
  fn(fn() -> State(web.Response)) -> web.Response

pub fn store(
  load load: fn(String) -> Session,
  delete delete: fn(String) -> Nil,
  save save: fn(String, Session) -> String,
) -> Store {
  Store(load:, delete:, save:)
}

pub fn empty_session() -> Session {
  Session(data: dict.new(), flash: dict.new())
}

fn session_id() -> String {
  extra.random_string(32)
}

fn empty_context() -> Context {
  Context(
    id: session_id(),
    data: dict.new(),
    flash: dict.new(),
    next_flash: dict.new(),
  )
}

pub fn handler(
  request: web.Request,
  cookie cookie: String,
  store store: Store,
  signing_key signing_key: String,
) -> Handler {
  run(request, store:, cookie:, signing_key:, handler: _)
}

pub fn run(
  request: web.Request,
  store store: Store,
  cookie cookie: String,
  signing_key signing_key: String,
  handler handler: fn() -> State(web.Response),
) -> web.Response {
  let cookie_value =
    request.get_cookies(request)
    |> list.key_find(cookie)
    |> result.try(crypto.verify_signed_message(_, <<signing_key:utf8>>))
    |> result.try(bit_array.to_string)

  let last_context = case cookie_value {
    Error(Nil) -> empty_context()

    Ok(id) -> {
      let Session(data:, flash:) = store.load(id)
      Context(..empty_context(), id:, data:, flash:)
    }
  }

  let #(response, context) = state.run(handler(), last_context)

  use <- bool.guard(
    context.id == last_context.id
      && context.data == last_context.data
      && context.next_flash == last_context.flash,
    response,
  )

  let id = {
    use <- bool.guard(context.id == last_context.id, context.id)
    log.debug("Regenerate session", [])
    store.delete(last_context.id)
    context.id
  }

  log.debug("Save session", [])

  let value =
    Session(data: context.data, flash: context.next_flash)
    |> store.save(id, _)

  response.set_cookie(
    response,
    cookie,
    crypto.sign_message(<<value:utf8>>, <<signing_key:utf8>>, crypto.Sha256),
    cookie.Attributes(..cookie.defaults(http.Https), max_age: option.None),
  )
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

pub fn id() -> State(String) {
  use Context(id:, ..) <- state.bind(state.get())
  state.return(id)
}

pub fn regenerate() -> State(Nil) {
  use ctx: Context <- state.update
  Context(..ctx, id: session_id())
}

pub fn insert(key: String, value: String) -> State(Nil) {
  use Context(data:, ..) as ctx <- state.update()
  Context(..ctx, data: dict.insert(data, key, value))
}

pub fn read(key: String) -> State(Result(String, Nil)) {
  use Context(data:, ..) <- state.bind(state.get())
  state.return(dict.get(data, key))
}

pub fn delete(key: String) -> State(Nil) {
  use Context(data:, ..) as ctx <- state.update
  Context(..ctx, data: dict.delete(data, key))
}

pub fn insert_flash(key: String, value: String) -> State(Nil) {
  use Context(next_flash:, ..) as ctx <- state.update()
  Context(..ctx, next_flash: dict.insert(next_flash, key, value))
}

pub fn read_flash(key: String) -> State(Result(String, Nil)) {
  use Context(flash:, ..) <- state.bind(state.get())
  state.return(dict.get(flash, key))
}

pub fn delete_flash(key: String) -> State(Nil) {
  use Context(next_flash:, ..) as ctx <- state.update
  Context(..ctx, next_flash: dict.delete(next_flash, key))
}
