import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/function
import gleam/otp/actor
import gleam/otp/supervision
import vvv/session.{type Session}

const start_timeout: Int = 10_000

const call_timeout: Int = 1000

const shutdown_timeout: Int = 1000

pub opaque type Model {
  Model(state: Dict(String, Session))
}

pub opaque type Message {
  Insert(subject: process.Subject(Nil), id: String, session: Session)
  Contains(subject: process.Subject(Bool), id: String)
  Get(subject: process.Subject(Result(Session, Nil)), id: String)
}

pub fn insert(
  store: process.Subject(Message),
  id: String,
  session: Session,
) -> Nil {
  process.call(store, call_timeout, Insert(_, id:, session:))
}

pub fn contains(store: process.Subject(Message), id: String) -> Bool {
  process.call(store, call_timeout, Contains(_, id))
}

pub fn get(
  store: process.Subject(Message),
  id: String,
) -> Result(Session, Nil) {
  process.call(store, call_timeout, Get(_, id))
}

pub fn start(
  name: process.Name(Message),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(start_timeout, init)
  |> actor.named(name)
  |> actor.on_message(update())
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
) -> supervision.ChildSpecification(process.Subject(Message)) {
  supervision.ChildSpecification(
    start: fn() { start(name) },
    restart: supervision.Permanent,
    significant: False,
    child_type: supervision.Worker(shutdown_timeout),
  )
}

pub fn init(
  subject: process.Subject(Message),
) -> Result(actor.Initialised(Model, Message, process.Subject(Message)), String) {
  Model(state: dict.new())
  |> actor.initialised
  |> actor.returning(subject)
  |> Ok
}

fn update() -> fn(Model, Message) -> actor.Next(Model, Message) {
  use model: Model, message: Message <- function.identity

  case message {
    Insert(subject:, id:, session:) -> {
      process.send(subject, Nil)

      dict.insert(model.state, id, session)
      |> Model(state: _)
      |> actor.continue
    }

    Contains(subject:, id:) -> {
      dict.has_key(model.state, id)
      |> process.send(subject, _)

      actor.continue(model)
    }

    Get(subject:, id:) -> {
      dict.get(model.state, id)
      |> process.send(subject, _)

      actor.continue(model)
    }
  }
}
