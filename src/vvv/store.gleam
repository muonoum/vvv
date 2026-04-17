import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/function
import gleam/otp/actor
import gleam/otp/supervision
import vvv/oauth

const start_timeout: Int = 10_000

const call_timeout: Int = 1000

const shutdown_timeout: Int = 1000

pub opaque type Model {
  Model(state: Dict(String, oauth.State))
}

pub opaque type Message {
  Save(subject: process.Subject(Nil), authorize: oauth.State)
  Load(subject: process.Subject(Result(oauth.State, Nil)), state: String)
}

pub fn load(
  store: process.Subject(Message),
  state: String,
) -> Result(oauth.State, Nil) {
  process.call(store, call_timeout, Load(_, state))
}

pub fn save(store: process.Subject(Message), authorize: oauth.State) -> Nil {
  process.call(store, call_timeout, Save(_, authorize))
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
    Save(subject:, authorize:) -> {
      process.send(subject, Nil)

      dict.insert(model.state, authorize.state, authorize)
      |> Model(state: _)
      |> actor.continue
    }

    Load(subject:, state:) -> {
      dict.get(model.state, state)
      |> process.send(subject, _)

      dict.delete(model.state, state)
      |> Model(state: _)
      |> actor.continue
    }
  }
}
