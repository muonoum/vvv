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
  Args(user: User, status: Option(String))
}

pub type User =
  Result(Option(auth.User), String)

pub type Component =
  component.Name(Args, Message)

pub opaque type Model {
  Model(user: User, status: Option(String))
}

pub type Message

pub fn component() -> lustre.App(Args, Model, Message) {
  lustre.component(init, update, view, options: [])
}

pub fn start(
  request: web.Request,
  app: Component,
  user user: User,
  status status: Option(String),
) -> web.Response {
  component.start(request, app, Args(user, status))
}

fn init(args: Args) -> #(Model, Effect(Message)) {
  #(Model(user: args.user, status: args.status), effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  html.div([classes(["flex gap-2 p-4"])], case model.user {
    Ok(option.None) -> [login_link(), login_status(model.status)]

    Ok(option.Some(user)) -> [
      html.div([classes(["flex gap-2"])], [
        html.div([], [element.text(user.name)]),
        html.div([], [element.text(user.email)]),
      ]),
      logout_link(),
      login_status(model.status),
    ]

    Error(message) -> [
      html.div([], [element.text("error: " <> message)]),
      login_link(),
    ]
  })
}

fn login_link() -> Element(message) {
  html.a([attribute.class("underline"), attribute.href("/auth/login")], [
    element.text("login"),
  ])
}

fn logout_link() -> Element(message) {
  html.a([attribute.class("underline"), attribute.href("/auth/logout")], [
    element.text("logout"),
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
