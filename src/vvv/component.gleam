import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{type Option, Some}
import gleam/otp/factory_supervisor as factory
import gleam/string
import lustre
import lustre/server_component as server
import mist
import wisp

pub type Name(argument, message) =
  process.Name(
    factory.Message(argument, process.Subject(lustre.RuntimeMessage(message))),
  )

pub fn service(
  request: Request(mist.Connection),
  component: process.Subject(lustre.RuntimeMessage(message)),
) -> Response(mist.ResponseData) {
  let on_init = on_init(_, request, component)
  mist.websocket(request:, on_init:, on_close:, handler:)
}

type State(message) {
  State(
    request: Request(mist.Connection),
    component: process.Subject(lustre.RuntimeMessage(message)),
    subject: process.Subject(server.ClientMessage(message)),
  )
}

fn on_init(
  _connection: mist.WebsocketConnection,
  request: Request(mist.Connection),
  component: process.Subject(lustre.RuntimeMessage(message)),
) -> #(State(message), Option(process.Selector(server.ClientMessage(message)))) {
  wisp.log_info("Join " <> request.path)

  let subject = process.new_subject()
  let selector = process.new_selector() |> process.select(subject)
  process.send(component, server.register_subject(subject))
  #(State(request:, component:, subject:), Some(selector))
}

fn on_close(state: State(message)) -> Nil {
  wisp.log_info("Leave " <> state.request.path)
  process.send(state.component, lustre.shutdown())
}

fn handler(
  state: State(message),
  message: mist.WebsocketMessage(server.ClientMessage(message)),
  connection: mist.WebsocketConnection,
) -> mist.Next(State(message), server.ClientMessage(message)) {
  case message {
    mist.Closed | mist.Shutdown -> mist.stop()
    mist.Binary(_) -> mist.continue(state)
    mist.Text(text) -> runtime_message(text, state)
    mist.Custom(message) -> client_message(connection, message, state)
  }
}

fn runtime_message(
  text: String,
  state: State(message),
) -> mist.Next(State(message), server.ClientMessage(message)) {
  case json.parse(text, server.runtime_message_decoder()) {
    Ok(message) -> process.send(state.component, message)

    Error(error) ->
      log_error([
        "Parse runtime message",
        state.request.path,
        string.inspect(error),
      ])
  }

  mist.continue(state)
}

fn client_message(connection, message, state: State(message)) {
  let json = json.to_string(server.client_message_to_json(message))

  case mist.send_text_frame(connection, json) {
    Ok(Nil) -> Nil

    Error(error) ->
      log_error([
        "Send client message",
        state.request.path,
        string.inspect(error),
      ])
  }

  mist.continue(state)
}

fn log_error(parts: List(String)) -> Nil {
  wisp.log_error(string.join(parts, ": "))
}
