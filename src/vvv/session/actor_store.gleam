import gleam/erlang/process
import gleam/function
import gleam/otp/static_supervisor as supervisor
import gleam/result
import vvv/session
import vvv/store.{type Store}

pub fn configure(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, a)) {
  let name = process.new_name("store")
  let spec = store.supervised(name)
  let store = new(process.named_subject(name))
  let supervisor = supervisor.add(supervisor, spec)
  #(store, supervisor, fn() { Ok(Nil) })
}

fn new(store: Store(session.Data)) -> session.Store {
  session.store(load: load(store), save: save(store))
}

fn load(store: Store(session.Data)) -> fn(String) -> session.Data {
  use id: String <- function.identity
  result.lazy_unwrap(store.load(store, id), session.empty_data)
}

fn save(store: Store(session.Data)) -> fn(String, session.Data) -> String {
  use id: String, data: session.Data <- function.identity
  store.save(store, id, data)
  id
}
