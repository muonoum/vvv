import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import vvv/auth
import vvv/component
import vvv/extra.{classes}

pub type Args {
  Args(user: User, status: Option(String), csrf_token: String)
}

pub type User =
  Result(Option(auth.User), String)

pub type Component =
  component.Name(Args, Message)

pub opaque type Model {
  Model(user: User, status: Option(String), csrf_token: String)
}

pub type Message

pub fn component() -> lustre.App(Args, Model, Message) {
  lustre.component(init:, update:, view:, options: [])
}

fn init(args: Args) -> #(Model, Effect(Message)) {
  let Args(user:, status:, csrf_token:) = args
  let model = Model(user:, status:, csrf_token:)
  #(model, effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  html.div([classes(["flex gap-2 p-4"])], case model.user {
    Ok(option.None) -> [
      login_link(model.csrf_token),
      login_status(model.status),
    ]

    Ok(option.Some(user)) -> [
      html.div([classes(["flex gap-2"])], [
        html.div([], [element.text(user.name)]),
        html.div([], [element.text(user.email)]),
      ]),
      logout_link(model.csrf_token),
      login_status(model.status),
    ]

    Error(message) -> [
      html.div([], [element.text("error: " <> echo message)]),
      login_link(model.csrf_token),
    ]
  })
}

fn login_status(status: Option(String)) -> Element(message) {
  case status {
    option.None -> element.none()

    option.Some(status) ->
      html.div([attribute.class("font-bold text-green-700")], [
        element.text(status),
      ])
  }
}

fn login_link(csrf_token: String) -> Element(message) {
  button_link("/auth/login", csrf_token:, content: [element.text("login")])
}

fn logout_link(csrf_token: String) -> Element(message) {
  button_link("/auth/logout", csrf_token:, content: [element.text("logout")])
}

fn button_link(
  action: String,
  csrf_token csrf_token: String,
  content content: List(Element(message)),
) -> Element(message) {
  html.form([attribute.method("POST"), attribute.action(action)], [
    html.input([
      attribute.type_("hidden"),
      attribute.name("csrf-token"),
      attribute.value(csrf_token),
    ]),
    html.button(
      [attribute.type_("submit"), classes(["underline cursor-pointer"])],
      content,
    ),
  ])
}
