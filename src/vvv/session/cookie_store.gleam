import gleam/json
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import logging
import vvv/session

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  #(session.store(load:, save:), supervisor, fn() { Ok(Nil) })
}

fn load(value: String) -> session.Data {
  result.lazy_unwrap(parse_value(value), session.empty_data)
}

fn parse_value(value: String) -> Result(session.Data, Nil) {
  use error <- result.try_recover(json.parse(value, session.data_decoder()))
  logging.log(logging.Warning, string.inspect(error))
  Error(Nil)
}

fn save(_value: String, data: session.Data) -> String {
  session.json_data(data)
}
