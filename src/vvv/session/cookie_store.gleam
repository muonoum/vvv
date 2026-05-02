import gleam/json
import gleam/result
import gleam/string
import logging
import vvv/session

pub fn new() -> session.Store {
  session.store(load:, save:)
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
