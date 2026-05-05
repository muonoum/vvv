import gleam/option.{type Option}
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import vvv/page

pub type Arguments =
  #(page.User, Option(String))

pub type App =
  lustre.App(Arguments, Model, Message)

pub opaque type Model {
  Model(user: page.User, status: Option(String))
}

pub type Message

pub fn component() -> App {
  lustre.component(init, update, view, options: [])
}

fn init(args: Arguments) -> #(Model, Effect(Message)) {
  let #(user, status) = args
  #(Model(user: user, status:), effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  page.view(model.user, model.status)
}
