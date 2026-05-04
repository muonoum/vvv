import gleam/json
import gleam/otp/static_supervisor as supervisor
import gleam/result
import vvv/extra/log
import vvv/session.{type Session}

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  #(session.store(load:, save:), supervisor, fn() { Ok(Nil) })
}

fn load(value: String) -> Session {
  result.lazy_unwrap(parse_value(value), session.empty_session)
}

fn parse_value(value: String) -> Result(Session, Nil) {
  use error <- result.try_recover(json.parse(value, session.session_decoder()))
  log.warning("Parse session", [log.inspect("error", error)])
  Error(Nil)
}

fn save(_value: String, data: Session) -> String {
  session.to_json(data)
}
