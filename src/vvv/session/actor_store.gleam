import gleam/erlang/process
import gleam/function
import gleam/otp/static_supervisor as supervisor
import vvv/session.{type Session}
import vvv/store.{type Store}

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  let name = process.new_name("store")
  let subject = process.named_subject(name)

  let store =
    session.Store(
      initialise: initialise(subject),
      save: save(subject),
      load: load(subject),
      replace: replace(subject),
    )

  let supervisor = supervisor.add(supervisor, store.supervised(name))
  #(store, supervisor, fn() { Ok(Nil) })
}

fn initialise(_store: Store(Session)) -> fn(String) -> String {
  function.identity
}

fn save(store: Store(Session)) -> fn(Session) -> Result(String, Nil) {
  use session: Session <- function.identity
  store.save(store, session.id, session)
  Ok(session.id)
}

fn load(store: Store(Session)) -> fn(String) -> Result(Session, Nil) {
  use id: String <- function.identity
  store.load(store, id)
}

fn replace(
  store: Store(Session),
) -> fn(String, Session) -> Result(String, Nil) {
  use previous_id: String, session: Session <- function.identity
  store.delete(store, previous_id)
  store.save(store, session.id, session)
  Ok(session.id)
}
