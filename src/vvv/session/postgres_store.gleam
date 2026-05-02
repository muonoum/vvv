import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/function
import gleam/json.{type Json}
import gleam/otp/supervision
import gleam/string
import logging
import pog
import vvv/session

const create_table = "
  create table if not exists sessions ( id text primary key, data jsonb not null );
"

const load_session = "
  select data from sessions where id = $1;
"

const save_session = "
  insert into sessions ( id, data ) values ( $1, $2 ) on conflict ( id ) do update set data=$2;
"

fn log_warning(value: v) -> Nil {
  logging.log(logging.Warning, "postgres_store: " <> string.inspect(value))
}

pub fn supervised(
  name: process.Name(pog.Message),
  host host,
  database database,
  user user,
  password password,
) -> supervision.ChildSpecification(pog.Connection) {
  pog.default_config(name)
  |> pog.host(host)
  |> pog.database(database)
  |> pog.user(user)
  |> pog.password(password)
  |> pog.supervised
}

pub fn new(connection: pog.Connection) -> session.Store {
  session.store(load: load(connection), save: save(connection))
}

pub fn setup(connection: pog.Connection) -> Nil {
  // TODO
  let assert Ok(_) =
    pog.query(create_table)
    |> pog.execute(connection)

  Nil
}

fn load(connection: pog.Connection) -> fn(String) -> session.Data {
  use id: String <- function.identity

  let result =
    pog.query(load_session)
    |> pog.parameter(pog.text(id))
    |> pog.returning(session_decoder())
    |> pog.execute(connection)

  case result {
    Ok(pog.Returned(rows: [data], ..)) -> data

    Ok(unexpected) -> {
      log_warning(unexpected)
      session.empty_data()
    }

    Error(error) -> {
      log_warning(error)
      session.empty_data()
    }
  }
}

fn session_decoder() {
  use data <- decode.then(decode.at([0], decode.string))

  case parse_value(data) {
    Error(error) -> {
      log_warning(error)
      decode.success(session.empty_data())
    }

    Ok(data) -> decode.success(data)
  }
}

fn parse_value(value: String) -> Result(session.Data, json.DecodeError) {
  json.parse(value, cookie_decoder())
}

fn cookie_decoder() -> Decoder(session.Data) {
  use user <- decode.field("user", dict_decoder())
  use flash <- decode.field("flash", dict_decoder())
  decode.success(session.data(user:, flash:))
}

fn dict_decoder() -> Decoder(Dict(String, String)) {
  decode.dict(decode.string, decode.string)
}

fn save(connection: pog.Connection) -> fn(String, session.Data) -> String {
  use id: String, data: session.Data <- function.identity

  // TODO
  let assert Ok(_) =
    pog.query(save_session)
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(encode_data(data)))
    |> pog.execute(connection)

  id
}

fn encode_data(data: session.Data) -> String {
  json.to_string(
    json.object([
      #("user", encode_dict(session.user_data(data))),
      #("flash", encode_dict(session.flash_data(data))),
    ]),
  )
}

fn encode_dict(dict: Dict(String, String)) -> Json {
  json.dict(dict, function.identity, json.string)
}
