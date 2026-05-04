import ewe
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import lustre
import lustre/server_component as server
import vvv/extra/log
import vvv/web

pub type Name(argument, message) =
  process.Name(
    factory.Message(argument, process.Subject(lustre.RuntimeMessage(message))),
  )

pub fn start(
  request: web.Request,
  name: Name(argument, message),
  argument: argument,
) -> web.Response {
  let supervisor = factory.get_by_name(name)

  case factory.start_child(supervisor, argument) {
    Ok(actor.Started(pid: _, data: component)) -> service(request, component)

    Error(error) -> {
      log.error("Server component", [
        log.string("path", request.path),
        log.inspect("error", error),
      ])

      response.new(500)
      |> web.text_body("Internal Server Error")
    }
  }
}

pub fn service(
  request: web.Request,
  component: process.Subject(lustre.RuntimeMessage(message)),
) -> web.Response {
  let on_init = fn(connection, selector) {
    on_init(connection, selector, request, component)
  }

  ewe.upgrade_websocket(request, on_init:, handler:, on_close:)
}

type State(message) {
  State(
    request: web.Request,
    component: process.Subject(lustre.RuntimeMessage(message)),
    subject: process.Subject(server.ClientMessage(message)),
  )
}

fn on_init(
  _connection: ewe.WebsocketConnection,
  selector,
  request: web.Request,
  component: process.Subject(lustre.RuntimeMessage(message)),
) -> #(State(message), process.Selector(server.ClientMessage(message))) {
  log.info("Join component", [log.string("path", request.path)])
  let subject = process.new_subject()
  let selector = process.select(selector, subject)
  process.send(component, server.register_subject(subject))
  #(State(request:, component:, subject:), selector)
}

fn on_close(
  _connection: ewe.WebsocketConnection,
  state: State(message),
) -> Nil {
  log.info("Leave component", [log.string("path", state.request.path)])
  process.send(state.component, lustre.shutdown())
}

fn handler(
  connection: ewe.WebsocketConnection,
  state: State(message),
  message: ewe.WebsocketMessage(server.ClientMessage(message)),
) -> ewe.WebsocketNext(State(message), server.ClientMessage(message)) {
  case message {
    ewe.Binary(_) -> ewe.websocket_continue(state)
    ewe.Text(text) -> runtime_message(text, state)
    ewe.User(message) -> client_message(connection, message, state)
  }
}

fn runtime_message(
  text: String,
  state: State(message),
) -> ewe.WebsocketNext(State(message), server.ClientMessage(message)) {
  case json.parse(text, server.runtime_message_decoder()) {
    Ok(message) -> process.send(state.component, message)

    Error(error) ->
      log.error("Parse runtime message", [
        log.string("path", state.request.path),
        log.inspect("error", error),
      ])
  }

  ewe.websocket_continue(state)
}

fn client_message(connection, message, state: State(message)) {
  let json = json.to_string(server.client_message_to_json(message))

  case ewe.send_text_frame(connection, json) {
    Ok(Nil) -> Nil

    Error(error) ->
      log.error("Send client message", [
        log.string("path", state.request.path),
        log.inspect("error", error),
      ])
  }

  ewe.websocket_continue(state)
}
