import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/function
import gleam/http
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/result
import vvv/extra/log
import vvv/extra/state
import vvv/store
import vvv/web

pub type Store {
  Store(
    initialise: fn(String) -> String,
    load: fn(String) -> Result(Session, Nil),
    save: fn(Session) -> Result(String, Nil),
    replace: fn(String, Session) -> Result(String, Nil),
  )
}

pub type Session {
  Session(id: String, data: Dict(String, String), flash: Dict(String, String))
}

pub type State(v) =
  state.State(v, Context)

pub type Context {
  Context(
    id: String,
    data: Dict(String, String),
    flash: Dict(String, String),
    next_flash: Dict(String, String),
  )
}

pub type Handler =
  fn(fn() -> State(web.Response)) -> web.Response

pub fn make_id() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base64_url_encode(False)
}

pub fn empty_session(id: String) -> Session {
  Session(id:, data: dict.new(), flash: dict.new())
}

fn empty_context(id: String) -> Context {
  Context(id:, data: dict.new(), flash: dict.new(), next_flash: dict.new())
}

pub fn start(
  request: web.Request,
  cookie_name cookie_name: String,
  signing_key signing_key: String,
  store store: Store,
) -> Handler {
  use handler <- function.identity

  let cookie_value =
    request.get_cookies(request)
    |> list.key_find(cookie_name)
    |> result.try(crypto.verify_signed_message(_, <<signing_key:utf8>>))
    |> result.try(bit_array.to_string)

  let set_cookie = fn(response, value) {
    response.set_cookie(
      response,
      cookie_name,
      crypto.sign_message(<<value:utf8>>, <<signing_key:utf8>>, crypto.Sha256),
      cookie.Attributes(..cookie.defaults(http.Https), max_age: option.None),
    )
  }

  case cookie_value {
    Error(Nil) -> {
      let context = empty_context(make_id())
      use response <- run_session(store:, context:, set_cookie:, handler:)
      let value = store.initialise(context.id)
      log.debug("Initialise session", [])
      set_cookie(response, value)
    }

    Ok(value) -> {
      let Session(id:, data:, flash:) = {
        log.debug("Load session", [])
        use <- result.lazy_unwrap(store.load(value))
        log.warning("Fallback to empty session", [])
        empty_session(value)
      }

      let context = Context(..empty_context(id), data:, flash:)
      use response <- run_session(store:, context:, set_cookie:, handler:)
      response
    }
  }
}

fn run_session(
  store store: Store,
  context context1: Context,
  set_cookie set_cookie: fn(web.Response, String) -> web.Response,
  handler handler: fn() -> State(web.Response),
  default default: fn(web.Response) -> web.Response,
) -> web.Response {
  let #(response, context2) = state.run(handler(), context1)
  // use <- bool.guard(response.status >= 400, response)

  let session =
    Session(id: context2.id, data: context2.data, flash: context2.next_flash)

  let id_changed = context1.id != context2.id

  use <- bool.lazy_guard(id_changed, fn() {
    let assert Ok(value) = store.replace(context1.id, session)
    log.debug("Replace session", [])
    set_cookie(response, value)
  })

  let content_changed =
    context1.data != context2.data || context1.next_flash != context2.flash

  use <- bool.lazy_guard(content_changed, fn() {
    let assert Ok(value) = store.save(session)
    log.debug("Save session", [])
    set_cookie(response, value)
  })

  default(response)
}

pub fn id() -> State(String) {
  use Context(id:, ..) <- state.bind(state.get())
  state.return(id)
}

pub fn replace() -> State(Nil) {
  use ctx <- state.bind(state.get())
  state.put(Context(..ctx, id: make_id()))
}

pub fn insert(key: String, value: String) -> State(Nil) {
  use Context(data:, ..) as ctx <- state.bind(state.get())
  state.put(Context(..ctx, data: dict.insert(data, key, value)))
}

pub fn read(key: String) -> State(Result(String, Nil)) {
  use Context(data:, ..) <- state.bind(state.get())
  state.return(dict.get(data, key))
}

pub fn delete(key: String) -> State(Nil) {
  use Context(data:, ..) as ctx <- state.bind(state.get())
  state.put(Context(..ctx, data: dict.delete(data, key)))
}

pub fn insert_flash(key: String, value: String) -> State(Nil) {
  use Context(next_flash:, ..) as ctx <- state.bind(state.get())
  state.put(Context(..ctx, next_flash: dict.insert(next_flash, key, value)))
}

pub fn read_flash(key: String) -> State(Result(String, Nil)) {
  use Context(flash:, ..) <- state.bind(state.get())
  state.return(dict.get(flash, key))
}

pub fn delete_flash(key: String) -> State(Nil) {
  use Context(next_flash:, ..) as ctx <- state.bind(state.get())
  state.put(Context(..ctx, next_flash: dict.delete(next_flash, key)))
}
