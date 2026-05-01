import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/function
import gleam/json.{type Json}
import gleam/result
import gleam/string
import logging
import vvv/session

pub fn new() -> session.Store {
  session.store(load:, save:)
}

fn load(value: String) -> session.Data {
  use <- result.lazy_unwrap(parse_cookie(value))
  session.data(user: dict.new(), flash: dict.new())
}

fn save(data: session.Data) -> String {
  json.to_string(
    json.object([
      #("user", dict_encoder(session.user_data(data))),
      #("flash", dict_encoder(session.flash_data(data))),
    ]),
  )
}

fn dict_encoder(dict: Dict(String, String)) -> Json {
  json.dict(dict, function.identity, json.string)
}

fn parse_cookie(value: String) -> Result(session.Data, Nil) {
  use error <- result.try_recover(json.parse(value, cookie_decoder()))
  logging.log(logging.Warning, string.inspect(error))
  Error(Nil)
}

fn cookie_decoder() -> Decoder(session.Data) {
  use user <- decode.field("user", dict_decoder())
  use flash <- decode.field("flash", dict_decoder())
  decode.success(session.data(user:, flash:))
}

fn dict_decoder() -> Decoder(Dict(String, String)) {
  decode.dict(decode.string, decode.string)
}
