import envoy
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/function
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import pog
import vvv/extra
import vvv/extra/log
import vvv/session.{type Session, Session}

const create_table_sql = "
  create table if not exists sessions (
    id text primary key,
    updated_at timestamp without time zone not null,
    data jsonb not null
  );
"

const create_update_function_sql = "
  create or replace function update_session()
  returns trigger
  language plpgsql
  as $$
    begin
      new.updated_at = now() at time zone 'utc';
      return new;
    end;
  $$;
"

const create_update_trigger_sql = "
  create or replace trigger update_session
  before insert or update on sessions
  for each row execute function update_session();
"

const load_session_sql = "
  select data from sessions where id = $1;
"

const delete_session_sql = "
  delete from sessions where id = $1;
"

const save_session_sql = "
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

  let store =
    session.Store(
      initialise: initialise(connection),
      save: save(connection),
      load: load(connection),
      replace: replace(connection),
    )

  let supervisor = supervisor.add(supervisor, spec)
  #(store, supervisor, fn() { setup(connection) })
}

fn initialise(_connection: pog.Connection) -> fn(String) -> String {
  function.identity
}

fn setup(connection: pog.Connection) -> Result(Nil, String) {
  use <- extra.return(result.map_error(_, string.inspect))
  use connection <- pog.transaction(connection)

  use Nil, query <- list.try_fold(from: Nil, over: [
    create_table_sql,
    create_update_function_sql,
    create_update_trigger_sql,
  ])

  pog.execute(pog.query(query), connection)
  |> result.replace(Nil)
}

fn save(connection: pog.Connection) -> fn(Session) -> Result(String, Nil) {
  use session <- function.identity

  case save_session(connection, session) {
    Ok(pog.Returned(..)) -> Ok(session.id)

    Error(error) -> {
      log.error("Save session", [log.inspect("error", error)])
      Error(Nil)
    }
  }
}

fn load(connection: pog.Connection) -> fn(String) -> Result(Session, Nil) {
  use id: String <- function.identity

  case load_session(connection, id) {
    Ok(pog.Returned(rows: [session], ..)) -> Ok(session)
    Ok(pog.Returned(rows: [], ..)) -> Error(Nil)
    Ok(pog.Returned(..)) -> Error(Nil)

    Error(error) -> {
      log.warning("Failed to load session", [log.inspect("error", error)])
      Error(Nil)
    }
  }
}

fn replace(
  connection: pog.Connection,
) -> fn(String, Session) -> Result(String, Nil) {
  use previous_id, session <- function.identity

  let result = {
    use connection <- pog.transaction(connection)
    use _ <- result.try(delete_session(connection, previous_id))
    save_session(connection, session)
  }

  case result {
    Ok(pog.Returned(..)) -> Ok(session.id)

    Error(error) -> {
      log.error("Replace session", [log.inspect("error", error)])
      Error(Nil)
    }
  }
}

fn save_session(
  connection: pog.Connection,
  session: Session,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query(save_session_sql)
  |> pog.parameter(pog.text(session.id))
  |> pog.parameter(pog.text(json.to_string(encode_session(session))))
  |> pog.execute(connection)
}

fn encode_session(session: Session) -> Json {
  json.object([
    #("data", json.dict(session.data, function.identity, json.string)),
    #("flash", json.dict(session.flash, function.identity, json.string)),
  ])
}

fn load_session(
  connection: pog.Connection,
  id: String,
) -> Result(pog.Returned(Session), pog.QueryError) {
  pog.query(load_session_sql)
  |> pog.parameter(pog.text(id))
  |> pog.returning(session_decoder(id))
  |> pog.execute(connection)
}

fn session_decoder(id: String) -> Decoder(Session) {
  use string <- decode.then(decode.at([0], decode.string))

  case json.parse(string, data_decoder(id)) {
    Ok(session) -> decode.success(session)

    Error(error) -> {
      log.warning("Decode session", [log.inspect("error", error)])
      decode.success(session.empty_session(id))
    }
  }
}

fn data_decoder(id: String) -> Decoder(Session) {
  use data <- decode.field("data", decode.dict(decode.string, decode.string))
  use flash <- decode.field("flash", decode.dict(decode.string, decode.string))
  decode.success(Session(id:, data:, flash:))
}

fn delete_session(
  connection: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query(delete_session_sql)
  |> pog.parameter(pog.text(id))
  |> pog.execute(connection)
}
