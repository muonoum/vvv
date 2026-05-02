import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/function
import gleam/json
import gleam/option.{type Option}
import gleam/otp/static_supervisor as supervisor
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

pub fn configure(
  supervisor: supervisor.Builder,
) -> #(session.Store, supervisor.Builder, fn() -> Result(Nil, String)) {
  // TODO
  let assert Ok(database) = envoy.get("DB_DATABASE") as "DB_DATABASE"
  let assert Ok(host) = envoy.get("DB_HOST") as "DB_HOST"
  let assert Ok(user) = envoy.get("DB_USER") as "DB_USER"
  let password = option.from_result(envoy.get("DB_PASSWORD"))

  let naem = process.new_name("store")
  let spec = supervised(naem, database:, host:, user:, password:)
  let connection = pog.named_connection(naem)
  let store = new(connection)
  let supervisor = supervisor.add(supervisor, spec)
  #(store, supervisor, fn() { setup(connection) })
}

fn supervised(
  name: process.Name(pog.Message),
  database database: String,
  host host: String,
  user user: String,
  password password: Option(String),
) -> supervision.ChildSpecification(pog.Connection) {
  pog.default_config(name)
  |> pog.host(host)
  |> pog.database(database)
  |> pog.user(user)
  |> pog.password(password)
  |> pog.supervised
}

fn new(connection: pog.Connection) -> session.Store {
  session.store(load: load(connection), save: save(connection))
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

fn session_decoder() {
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
  use id: String, data: session.Data <- function.identity

  let result =
    pog.query(save_session)
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(session.json_data(data)))
    |> pog.execute(connection)

  case result {
    Error(error) -> logging.log(logging.Error, string.inspect(error))
    Ok(pog.Returned(count: 1, rows: [])) -> Nil

    Ok(pog.Returned(..) as unexpected) ->
      logging.log(logging.Error, string.inspect(unexpected))
  }

  id
}
