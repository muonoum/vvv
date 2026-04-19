import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import vvv/session

pub opaque type Model {
  Model(user: Option(session.User))
}

pub type Message

pub fn component() -> lustre.App(Option(session.User), Model, Message) {
  lustre.component(init, update, view, options: [])
}

fn init(user: Option(session.User)) -> #(Model, Effect(Message)) {
  #(Model(user:), effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  case model.user {
    option.Some(user) ->
      html.div([attribute.class("flex gap-2 p-4")], [
        html.div([], [element.text(user.name)]),
        html.div([], [element.text("—")]),
        html.a([attribute.class("underline"), attribute.href("/auth/logout")], [
          element.text("logout"),
        ]),
      ])

    option.None ->
      html.div([attribute.class("flex gap-2 p-4")], [
        html.a([attribute.class("underline"), attribute.href("/auth/login")], [
          element.text("login"),
        ]),
      ])
  }
}
