import gleam/erlang/process
import gleam/function
import gleam/otp/static_supervisor as supervisor
import gleam/result
import vvv/session.{type Session}
import vvv/store.{type Store}

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, a)) {
  let name = process.new_name("store")
  let subject = process.named_subject(name)

  let store =
    session.store(
      load: load(subject),
      delete: delete(subject),
      save: save(subject),
    )

  let supervisor = supervisor.add(supervisor, store.supervised(name))
  #(store, supervisor, fn() { Ok(Nil) })
}

fn load(store: Store(Session)) -> fn(String) -> Session {
  use id: String <- function.identity
  result.lazy_unwrap(store.load(store, id), session.empty_session)
}

fn delete(store: Store(Session)) -> fn(String) -> Nil {
  use id <- function.identity
  store.delete(store, id)
}

fn save(store: Store(Session)) -> fn(String, Session) -> String {
  use id, data <- function.identity
  store.save(store, id, data)
  id
}
