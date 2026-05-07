import gleam/erlang/process
import gleam/function
import gleam/otp/static_supervisor as supervisor
import gleam/result
import vvv/session.{type Session}
import vvv/store.{type Store}

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  let name = process.new_name("store")
  let subject = process.named_subject(name)

  let store =
    session.store(
      save: save(subject),
      load: load(subject),
      delete: delete(subject),
      replace: replace(subject),
    )

  let supervisor = supervisor.add(supervisor, store.supervised(name))
  #(store, supervisor, fn() { Ok(Nil) })
}

fn save(
  store: Store(Session),
) -> fn(session.Save) -> Result(String, session.Error) {
  use session.Save(id:, session:) <- function.identity
  store.save(store, id, session)
  Ok(id)
}

fn load(store: Store(Session)) -> fn(String) -> Session {
  use id: String <- function.identity
  result.lazy_unwrap(store.load(store, id), session.empty_session)
}

fn delete(store: Store(Session)) -> fn(String) -> Nil {
  use id <- function.identity
  store.delete(store, id)
}

fn replace(
  store: Store(Session),
) -> fn(session.Replace) -> Result(String, session.Error) {
  use session.Replace(next_id:, previous_id:, session:) <- function.identity
  store.delete(store, previous_id)
  store.save(store, next_id, session)
  Ok(next_id)
}
