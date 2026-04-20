import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import vvv/auth

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
  html.div([attribute.class("flex gap-2 p-4")], case model.user {
    Error(message) -> [
      html.div([attribute.class("flex flex-col gap-2")], [
        html.a([attribute.class("underline"), attribute.href("/auth/login")], [
          element.text("login"),
        ]),
        html.div([], [element.text("error: " <> message)]),
      ]),
    ]

    Ok(option.Some(user)) -> [
      html.div([], [
        element.text(user.name <> "—" <> user.email),
      ]),
      html.a([attribute.class("underline"), attribute.href("/auth/logout")], [
        element.text("logout"),
      ]),
    ]

    Ok(option.None) -> [
      html.a([attribute.class("underline"), attribute.href("/auth/login")], [
        element.text("login"),
      ]),
    ]
  })
}
