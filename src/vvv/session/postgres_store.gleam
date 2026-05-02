import gleam/dynamic/decode
import gleam/erlang/process
import gleam/function
import gleam/json
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
  insert into sessions ( id, data ) values ( $1, $2 ) on conflict ( id ) do update set data = $2;
"

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
      logging.log(logging.Warning, string.inspect(unexpected))
      session.empty_data()
    }

    Error(error) -> {
      logging.log(logging.Warning, string.inspect(error))
      session.empty_data()
    }
  }
}

fn session_decoder() {
  use data <- decode.then(decode.at([0], decode.string))

  case parse_value(data) {
    Error(error) -> {
      logging.log(logging.Warning, string.inspect(error))
      decode.success(session.empty_data())
    }

    Ok(data) -> decode.success(data)
  }
}

fn parse_value(value: String) -> Result(session.Data, json.DecodeError) {
  json.parse(value, session.data_decoder())
}

fn save(connection: pog.Connection) -> fn(String, session.Data) -> String {
  use id: String, data: session.Data <- function.identity

  // TODO
  let assert Ok(_) =
    pog.query(save_session)
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(session.json_data(data)))
    |> pog.execute(connection)

  id
}
