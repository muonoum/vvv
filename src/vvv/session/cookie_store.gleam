import gleam/dynamic/decode.{type Decoder}
import gleam/function
import gleam/json.{type Json}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import vvv/extra/log
import vvv/session.{type Session, Session}

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  let store = session.Store(initialise:, save:, load:, replace:)
  #(store, supervisor, fn() { Ok(Nil) })
}

fn initialise(id: String) -> String {
  session.empty_session(id)
  |> encode_session
  |> json.to_string
}

fn save(session: Session) -> Result(String, Nil) {
  encode_session(session)
  |> json.to_string
  |> Ok
}

fn load(value: String) -> Result(Session, Nil) {
  use error <- result.try_recover(json.parse(value, session_decoder()))
  log.warning("Load session failed", [log.inspect("error", error)])
  Error(Nil)
}

fn replace(_previous_id: String, session: Session) -> Result(String, Nil) {
  encode_session(session)
  |> json.to_string
  |> Ok
}

pub fn encode_session(session: Session) -> Json {
  json.object([
    #("id", json.string(session.id)),
    #("data", json.dict(session.data, function.identity, json.string)),
    #("flash", json.dict(session.flash, function.identity, json.string)),
  ])
}

fn session_decoder() -> Decoder(Session) {
  use id <- decode.field("id", decode.string)
  use data <- decode.field("data", decode.dict(decode.string, decode.string))
  use flash <- decode.field("flash", decode.dict(decode.string, decode.string))
  decode.success(Session(id:, data:, flash:))
}
