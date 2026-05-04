import gleam/option.{type Option}
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import vvv/page

pub type App =
  lustre.App(page.User, Model, Message)

pub opaque type Model {
  Model(user: page.User, status: Option(String))
}

pub opaque type Message {
  StatusReceived(String)
}

pub fn component() -> App {
  lustre.component(init, update, view, options: [
    component.on_attribute_change("status", fn(status) {
      Ok(StatusReceived(status))
    }),
  ])
}

fn init(user: page.User) -> #(Model, Effect(Message)) {
  #(Model(user: user, status: option.None), effect.none())
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let StatusReceived(status) = message
  #(Model(..model, status: option.Some(status)), effect.none())
}

fn view(model: Model) -> Element(Message) {
  page.view(model.user, model.status)
}
