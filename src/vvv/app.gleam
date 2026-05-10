import gleam/option.{type Option}
import lustre
import lustre/attribute
import lustre/component as lustre_component
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
  Model(user: User, status: Option(String), csrf_token: Option(String))
}

pub type Message {
  CsrfTokenReceived(String)
}

pub fn component() -> lustre.App(Args, Model, Message) {
  lustre.component(init:, update:, view:, options: [
    lustre_component.on_attribute_change("csrf-token", fn(csrf_token) {
      Ok(CsrfTokenReceived(csrf_token))
    }),
  ])
}

pub fn start(
  request: web.Request,
  app: Component,
  user user: User,
  status status: Option(String),
) -> web.Response {
  component.start(request, app, Args(user:, status:))
}

fn init(args: Args) -> #(Model, Effect(Message)) {
  let model =
    Model(user: args.user, status: args.status, csrf_token: option.None)

  #(model, effect.none())
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    CsrfTokenReceived(csrf_token) -> #(
      Model(..model, csrf_token: option.Some(csrf_token)),
      effect.none(),
    )
  }
}

fn view(model: Model) -> Element(Message) {
  case model.csrf_token {
    option.None -> element.none()
    option.Some(csrf_token) ->
      html.div([classes(["flex gap-2 p-4"])], case model.user {
        Ok(option.None) -> [
          login_link(csrf_token),
          login_status(model.status),
        ]

        Ok(option.Some(user)) -> [
          html.div([classes(["flex gap-2"])], [
            html.div([], [element.text(user.name)]),
            html.div([], [element.text(user.email)]),
          ]),
          logout_link(csrf_token),
          login_status(model.status),
        ]

        Error(message) -> [
          html.div([], [element.text("error: " <> echo message)]),
          login_link(csrf_token),
        ]
      })
  }
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
