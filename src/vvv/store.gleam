import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/json.{type Json}
import gleam/otp/actor
import gleam/otp/supervision

const start_timeout: Int = 10_000

const call_timeout: Int = 1000

const shutdown_timeout: Int = 1000

pub opaque type Model {
  Model(state: Dict(String, Json))
}

pub opaque type Message {
  Put(subject: process.Subject(Nil), key: String, data: Json)
  Get(subject: process.Subject(Result(Json, Nil)), key: String)
}

pub fn put(store: process.Subject(Message), key: String, data: Json) -> Nil {
  process.call(store, call_timeout, Put(_, key:, data:))
}

pub fn get(store: process.Subject(Message), key: String) -> Result(Json, Nil) {
  process.call(store, call_timeout, Get(_, key:))
}

pub fn start(
  name: process.Name(Message),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(start_timeout, init)
  |> actor.named(name)
  |> actor.on_message(update)
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
) -> supervision.ChildSpecification(process.Subject(Message)) {
  supervision.ChildSpecification(
    start: fn() { start(name) },
    child_type: supervision.Worker(shutdown_timeout),
    restart: supervision.Permanent,
    significant: False,
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

fn update(model: Model, message: Message) -> actor.Next(Model, Message) {
  case message {
    Put(subject:, key:, data:) -> {
      process.send(subject, Nil)

      dict.insert(model.state, key, data)
      |> Model(state: _)
      |> actor.continue
    }

    Get(subject:, key:) -> {
      dict.get(model.state, key)
      |> process.send(subject, _)

      actor.continue(model)
    }
  }
}
