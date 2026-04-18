import gleam/option
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component as server

pub fn page(
  page_title page_title: String,
  session_id session_id: option.Option(String),
  csp_nonce csp_nonce: String,
) -> Element(v) {
  html.html([], [
    html.head([], [
      html.title([], page_title),
      html.meta([attr.charset("utf-8")]),
      html.meta([
        attr.name("viewport"),
        attr.content("width=device-width,initial-scale=1"),
      ]),
      html.script(
        [
          attr.type_("module"),
          attr.nonce(csp_nonce),
          attr.src("/lustre/lustre-server-component.mjs"),
        ],
        "",
      ),
      html.link([attr.rel("stylesheet"), attr.href("/app.css")]),
    ]),
    html.body([], [
      server.element(
        [
          attr.class("contents"),
          case session_id {
            option.Some(session_id) -> attr.attribute("session-id", session_id)
            option.None -> attr.none()
          },
          server.route("/components/app"),
        ],
        [],
      ),
    ]),
  ])
}
