import gleam/function
import gleam/result
import vvv/session
import vvv/store.{type Store}

pub fn new(store: Store(session.Data)) -> session.Store {
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
