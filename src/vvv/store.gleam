import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/supervision

const start_timeout: Int = 10_000

const call_timeout: Int = 1000

const shutdown_timeout: Int = 1000

pub type Store(data) =
  process.Subject(Message(data))

pub opaque type Model(data) {
  Model(state: Dict(String, data))
}

pub opaque type Message(data) {
  Save(key: String, data: data)
  Load(subject: process.Subject(Result(data, Nil)), key: String)
}

pub fn save(store: Store(data), key: String, data: data) -> Nil {
  process.send(store, Save(key:, data:))
}

pub fn load(store: Store(data), key: String) -> Result(data, Nil) {
  process.call(store, call_timeout, Load(_, key:))
}

pub fn start(
  name: process.Name(Message(data)),
) -> Result(actor.Started(Store(data)), actor.StartError) {
  actor.new_with_initialiser(start_timeout, init)
  |> actor.named(name)
  |> actor.on_message(update)
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message(data)),
) -> supervision.ChildSpecification(Store(data)) {
  supervision.ChildSpecification(
    start: fn() { start(name) },
    child_type: supervision.Worker(shutdown_timeout),
    restart: supervision.Permanent,
    significant: False,
  )
}

pub fn init(
  subject: Store(data),
) -> Result(actor.Initialised(Model(data), Message(data), Store(data)), String) {
  Model(state: dict.new())
  |> actor.initialised
  |> actor.returning(subject)
  |> Ok
}

fn update(
  model: Model(data),
  message: Message(data),
) -> actor.Next(Model(data), Message(data)) {
  case message {
    Save(key:, data:) ->
      dict.insert(model.state, key, data)
      |> Model(state: _)
      |> actor.continue

    Load(subject:, key:) -> {
      dict.get(model.state, key)
      |> process.send(subject, _)

      actor.continue(model)
    }
  }
}
