import gleam/option.{type Option}
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import vvv/component
import vvv/page
import vvv/web

pub opaque type Args {
  Args(user: page.User, status: Option(String))
}

pub type Component =
  component.Name(Args, Message)

pub opaque type Model {
  Model(user: page.User, status: Option(String))
}

pub type Message

pub fn component() -> lustre.App(Args, Model, Message) {
  lustre.component(init, update, view, options: [])
}

pub fn start(
  request: web.Request,
  app: Component,
  user user: page.User,
  status status: Option(String),
) -> web.Response {
  component.start(request, app, Args(user, status))
}

fn init(args: Args) -> #(Model, Effect(Message)) {
  let Args(user:, status:) = args
  #(Model(user: user, status:), effect.none())
}

fn update(model: Model, _message: Message) -> #(Model, Effect(Message)) {
  #(model, effect.none())
}

fn view(model: Model) -> Element(Message) {
  page.view(model.user, model.status)
}
