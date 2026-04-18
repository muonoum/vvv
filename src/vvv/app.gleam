import gleam/erlang/process
import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import vvv/session
import vvv/store

pub opaque type Model {
  Model(store: process.Subject(store.Message), user: Option(session.User))
}

pub opaque type Message {
  SessionIdReceived(String)
}

pub fn component() -> lustre.App(process.Subject(store.Message), Model, Message) {
  lustre.component(init, update, view, options: [
    component.on_attribute_change("session-id", fn(string) {
      Ok(SessionIdReceived(string))
    }),
  ])
}

fn init(store: process.Subject(store.Message)) -> #(Model, Effect(Message)) {
  let model = Model(store:, user: option.None)
  #(model, effect.none())
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    SessionIdReceived(session_id) -> {
      let assert Ok(session.UserSession(user)) =
        store.get(model.store, session_id)

      let model = Model(..model, user: option.Some(user))
      #(model, effect.none())
    }
  }
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
