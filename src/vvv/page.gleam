import gleam/http/response
import gleam/option
import gleam/uri.{Uri}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component
import vvv/extra/state
import vvv/session
import vvv/web

pub fn handler(
  title title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(web.Response) {
  use page <- state.bind(page(title:, csrf_token:, csp_nonce:))

  state.return(
    response.new(200)
    |> web.html_body(element.to_document_string_tree(page)),
  )
}

fn page(
  title title: String,
  csrf_token csrf_token: String,
  csp_nonce csp_nonce: String,
) -> session.State(Element(message)) {
  use status <- state.bind(session.read("status"))

  let app_uri =
    Uri(..uri.empty, path: "/components/app", query: {
      option.Some(
        uri.query_to_string(case status {
          Ok(status) -> [#("status", status)]
          Error(Nil) -> []
        }),
      )
    })

  state.return(
    html.html([], [
      html.head([], [
        html.title([], title),
        html.meta([attribute.charset("utf-8")]),
        html.meta([attribute.name("csrf-token"), attribute.content(csrf_token)]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width,initial-scale=1"),
        ]),
        html.link([
          attribute.rel("stylesheet"),
          attribute.href("/app.css"),
          attribute.nonce(csp_nonce),
        ]),
        html.script(
          [
            attribute.type_("module"),
            attribute.src("/lustre/lustre-server-component.min.mjs"),
            attribute.nonce(csp_nonce),
          ],
          "",
        ),
      ]),
      html.body([], [
        server_component.element(
          [server_component.route(uri.to_string(app_uri))],
          [],
        ),
      ]),
    ]),
  )
}
