import envoy
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/function
import gleam/json
import gleam/option
import gleam/otp/static_supervisor as supervisor
import gleam/string
import logging
import pog
import vvv/session

const create_table = "
  create table if not exists sessions (
    id text primary key,
    data jsonb not null
  );
"

const load_session = "
  select data from sessions where id = $1;
"

const save_session = "
  insert into sessions ( id, data ) values ( $1, $2 )
  on conflict ( id ) do update set data = $2;
"

pub fn new(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  let assert Ok(db_name) = envoy.get("SESSION_DB_NAME") as "SESSION_DB_NAME"
  let assert Ok(db_host) = envoy.get("SESSION_DB_HOST") as "SESSION_DB_HOST"
  let assert Ok(db_user) = envoy.get("SESSION_DB_USER") as "SESSION_DB_USER"
  let db_password = option.from_result(envoy.get("SESSION_DB_PASSWORD"))

  let name = process.new_name("store")

  let spec =
    pog.default_config(name)
    |> pog.host(db_host)
    |> pog.database(db_name)
    |> pog.user(db_user)
    |> pog.password(db_password)
    |> pog.supervised

  let connection = pog.named_connection(name)
  let store = session.store(load: load(connection), save: save(connection))
  let supervisor = supervisor.add(supervisor, spec)
  #(store, supervisor, fn() { setup(connection) })
}

fn setup(connection: pog.Connection) -> Result(Nil, String) {
  let result =
    pog.query(create_table)
    |> pog.execute(connection)

  case result {
    Error(error) -> Error(string.inspect(error))
    // TODO: Feil type for count --> pog.Returned(Table, [])
    Ok(pog.Returned(..)) -> Ok(Nil)
  }
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
    Ok(pog.Returned(rows: [], ..)) -> session.empty_data()

    Ok(pog.Returned(..) as unexpected) -> {
      logging.log(logging.Warning, string.inspect(unexpected))
      session.empty_data()
    }

    Error(error) -> {
      logging.log(logging.Warning, string.inspect(error))
      session.empty_data()
    }
  }
}

fn session_decoder() -> Decoder(session.Data) {
  use data <- decode.then(decode.at([0], decode.string))

  case parse_value(data) {
    Ok(data) -> decode.success(data)

    Error(error) -> {
      logging.log(logging.Warning, string.inspect(error))
      decode.success(session.empty_data())
    }
  }
}

fn parse_value(value: String) -> Result(session.Data, json.DecodeError) {
  json.parse(value, session.data_decoder())
}

fn save(connection: pog.Connection) -> fn(String, session.Data) -> String {
  use id, data <- function.identity

  let result =
    pog.query(save_session)
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(session.json_data(data)))
    |> pog.execute(connection)

  case result {
    Ok(pog.Returned(..)) -> Nil
    Error(error) -> logging.log(logging.Error, string.inspect(error))
  }

  id
}
