import gleam/option.{type Option}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import vvv/auth

pub type User =
  Result(Option(auth.User), String)

pub type Status =
  Result(String, Nil)

pub fn view(user: User, status: Status) -> Element(message) {
  html.div([attribute.class("flex gap-2 p-4")], case user {
    Error(message) -> [
      login(),
      html.div([], [element.text("error: " <> message)]),
      login_status(status),
    ]

    Ok(option.Some(user)) -> [
      logout(),
      html.div([], [element.text(user.name <> "—" <> user.email)]),
      login_status(status),
    ]

    Ok(option.None) -> [login(), login_status(status)]
  })
}

fn login() -> Element(message) {
  html.a([attribute.class("underline"), attribute.href("/auth/login")], [
    element.text("login"),
  ])
}

fn logout() -> Element(message) {
  html.a([attribute.class("underline"), attribute.href("/auth/logout")], [
    element.text("logout"),
  ])
}

fn login_status(status: Status) -> Element(message) {
  case status {
    Error(Nil) -> element.none()

    Ok(message) ->
      html.div([attribute.class("font-bold text-green-700")], [
        element.text(message),
      ])
  }
}
