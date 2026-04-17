import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

pub opaque type Model {
  Model(user_id: Option(String))
}

pub opaque type Message {
  UserNameReceived(String)
}

pub fn component() -> lustre.App(Nil, Model, Message) {
  lustre.component(init, update, view, options: [
    component.on_attribute_change("user_id", fn(string) {
      Ok(UserNameReceived(string))
    }),
  ])
}

fn init(_flags) -> #(Model, Effect(Message)) {
  let model = Model(user_id: None)
  #(model, effect.none())
}

fn update(_model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserNameReceived(user_id) -> #(Model(user_id: Some(user_id)), effect.none())
  }
}

fn view(model: Model) -> Element(Message) {
  html.div([attribute.class("flex gap-2 p-4")], [
    html.div([], [element.text(string.inspect(model.user_id))]),
    html.div([], [element.text("—")]),
    html.a([attribute.class("underline"), attribute.href("/logout")], [
      element.text("login"),
    ]),
  ])
}
