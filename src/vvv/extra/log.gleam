import gleam/int
import gleam/list
import gleam/string
import logging

pub opaque type Field {
  Field(key: String, value: Value)
}

pub opaque type Value {
  String(String)
  Int(Int)
}

pub fn configure(level: logging.LogLevel) -> Nil {
  logging.configure()
  logging.set_level(level)
}

pub fn string(key: String, value: String) -> Field {
  Field(key:, value: String(value))
}

pub fn int(key: String, value: Int) -> Field {
  Field(key:, value: Int(value))
}

pub fn inspect(key: String, value: v) -> Field {
  Field(key:, value: String(string.inspect(value)))
}

pub fn info(message: String, fields: List(Field)) -> Nil {
  log(logging.Info, message, fields)
}

pub fn debug(message: String, fields: List(Field)) -> Nil {
  log(logging.Debug, message, fields)
}

pub fn warning(message: String, fields: List(Field)) -> Nil {
  log(logging.Warning, message, fields)
}

pub fn error(message: String, fields: List(Field)) -> Nil {
  log(logging.Error, message, fields)
}

pub fn log(
  level: logging.LogLevel,
  message: String,
  fields: List(Field),
) -> Nil {
  let message = case format(fields, []) {
    "" -> message
    fields -> message <> " " <> fields
  }

  logging.log(level, message)
}

fn format(fields: List(Field), result: List(String)) -> String {
  case fields {
    [] -> string.join(list.reverse(result), " ")

    [Field(key: "", value:), ..rest] ->
      format(rest, [format_value(value), ..result])

    [Field(key:, value:), ..rest] ->
      format(rest, [key_value(key, format_value(value)), ..result])
  }
}

fn key_value(key: String, value: String) -> String {
  key <> "=" <> value
}

fn format_value(value: Value) -> String {
  case value {
    String(string) -> string
    Int(int) -> int.to_string(int)
  }
}
