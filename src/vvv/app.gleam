import gleam/option.{type Option}
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import vvv/auth
import vvv/component
import vvv/page

type Argument =
  Result(Option(auth.User), String)

pub type Component =
  component.Name(Argument, Message)

pub type App =
  lustre.App(Result(Option(auth.User), String), Model, Message)

pub opaque type Model {
  Model(user: Result(Option(auth.User), String))
}

pub type Message

pub fn component() -> App {
  lustre.component(init, update, view, options: [])
}

fn init(user: Result(Option(auth.User), String)) -> #(Model, Effect(Message)) {
  #(Model(user:), effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  page.view(model.user, Error(Nil))
}
