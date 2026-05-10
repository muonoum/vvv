import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import vvv/auth
import vvv/component
import vvv/extra.{classes}
import vvv/web

pub opaque type Args {
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

pub fn start(
  request: web.Request,
  app: Component,
  user user: User,
  status status: Option(String),
  csrf_token csrf_token: String,
) -> web.Response {
  component.start(request, app, Args(user:, status:, csrf_token:))
}

fn init(args: Args) -> #(Model, Effect(Message)) {
  #(
    Model(user: args.user, status: args.status, csrf_token: args.csrf_token),
    effect.none(),
  )
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

fn login_link(csrf_token: String) -> Element(message) {
  html.form([attribute.method("POST"), attribute.action("/auth/login")], [
    html.input([
      attribute.type_("hidden"),
      attribute.name("csrf-token"),
      attribute.value(csrf_token),
    ]),
    html.button(
      [attribute.type_("submit"), classes(["underline cursor-pointer"])],
      [element.text("login")],
    ),
  ])
}

fn logout_link(csrf_token: String) -> Element(message) {
  html.form([attribute.method("POST"), attribute.action("/auth/logout")], [
    html.input([
      attribute.type_("hidden"),
      attribute.name("csrf-token"),
      attribute.value(csrf_token),
    ]),
    html.button(
      [attribute.type_("submit"), classes(["underline cursor-pointer"])],
      [element.text("logout")],
    ),
  ])
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
