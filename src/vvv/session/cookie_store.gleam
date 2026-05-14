import gleam/json
import gleam/otp/static_supervisor as supervisor
import gleam/result
import vvv/extra/log
import vvv/session.{type Session}

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  let store = session.Store(initialise:, save:, load:, replace:)
  #(store, supervisor, fn() { Ok(Nil) })
}

fn initialise(id: String) -> String {
  session.empty_session(id)
  |> session.to_json
  |> json.to_string
}

fn save(session: Session) -> Result(String, Nil) {
  session.to_json(session)
  |> json.to_string
  |> Ok
}

fn load(value: String) -> Result(Session, Nil) {
  use error <- result.try_recover(json.parse(value, session.decoder()))
  log.warning("Failed to load session", [log.inspect("error", error)])
  Error(Nil)
}

fn replace(_previous_id: String, session: Session) -> Result(String, Nil) {
  session.to_json(session)
  |> json.to_string
  |> Ok
}
