import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import vvv/auth

pub opaque type Model {
  Model(user: Option(auth.User))
}

pub type Message

pub fn component() -> lustre.App(Option(auth.User), Model, Message) {
  lustre.component(init, update, view, options: [])
}

fn init(user: Option(auth.User)) -> #(Model, Effect(Message)) {
  #(Model(user:), effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  html.div([attribute.class("flex gap-2 p-4")], case model.user {
    option.Some(user) -> [
      html.div([], [
        element.text(user.name <> "—" <> user.email),
      ]),
      html.a([attribute.class("underline"), attribute.href("/auth/logout")], [
        element.text("logout"),
      ]),
    ]

    option.None -> [
      html.a([attribute.class("underline"), attribute.href("/auth/login")], [
        element.text("login"),
      ]),
    ]
  })
}
