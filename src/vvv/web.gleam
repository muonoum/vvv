import ewe
import exception
import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import logging
import marceau
import simplifile
import vvv/extra

pub type Request =
  request.Request(ewe.Connection)

pub type Response =
  response.Response(ewe.ResponseBody)

pub type Asset {
  Asset(
    relative_path: String,
    full_path: String,
    content_type: String,
    hash: String,
  )
}

@external(erlang, "timer", "tc")
fn time(fun: fn() -> a) -> #(Int, a)

pub fn log(request: Request, handler: fn() -> Response) -> Response {
  let #(elapsed, response) = time(handler)

  let elapsed = case elapsed {
    n if n >= 1000 -> int.to_string(elapsed / 1000) <> "ms"
    _else -> int.to_string(elapsed) <> "µs"
  }

  logging.log(
    logging.Info,
    elapsed
      <> " "
      <> int.to_string(response.status)
      <> " "
      <> http.method_to_string(request.method)
      <> " "
      <> request.path,
  )

  response
}

pub fn rescue(handler: fn() -> Response) -> Response {
  case exception.rescue(handler) {
    Ok(response) -> response

    Error(error) -> {
      logging.log(logging.Error, string.inspect(error))

      response.new(500)
      |> response.set_body(ewe.TextData("Internal Server Error"))
    }
  }
}

pub fn csp_nonce(handler: fn(String) -> Response) -> Response {
  let nonce = extra.random_string(24)

  let header =
    "script-src 'nonce-"
    <> nonce
    <> "' 'strict-dynamic'; object-src 'none'; base-uri 'none'"

  handler(nonce)
  |> response.set_header("content-security-policy", header)
}

pub fn text_body(response: response.Response(v), text: String) -> Response {
  response.set_body(response, ewe.TextData(text))
}

pub fn empty_body(response: response.Response(v)) -> Response {
  response.set_body(response, ewe.Empty)
}

pub fn form_data(
  request: Request,
  bytes_limit bytes_limit: Int,
  next next: fn(List(#(String, String))) -> Response,
) -> Response {
  use body <- string_data(request, bytes_limit:)

  case uri.parse_query(body) {
    Ok(pairs) -> next(pairs)

    Error(Nil) ->
      response.new(400)
      |> text_body("Bad Request")
  }
}

pub fn string_data(
  request: Request,
  bytes_limit bytes_limit: Int,
  next next: fn(String) -> Response,
) -> Response {
  case ewe.read_body(request, bytes_limit:) {
    Error(..) ->
      response.new(400)
      |> text_body("Bad Request")

    Ok(request) ->
      case bit_array.to_string(request.body) {
        Ok(body) -> next(body)

        Error(..) ->
          response.new(400)
          |> text_body("Bad Request")
      }
  }
}

pub fn load_assets(base: String) -> Dict(List(String), Asset) {
  dict.from_list({
    use relative_path <- list.filter_map(extra.wildcard(base, "**"))
    let full_path = filepath.join(base, relative_path)
    use <- bool.guard(extra.is_directory(full_path), Error(Nil))
    use #(content_type, hash) <- result.try(read_path(full_path))
    let asset = Asset(relative_path:, full_path:, content_type:, hash:)
    Ok(#(uri.path_segments(relative_path), asset))
  })
}

fn read_path(path: String) -> Result(#(String, String), Nil) {
  use bits <- result.try(
    simplifile.read_bits(path)
    |> result.try_recover(fn(error) {
      logging.log(logging.Warning, string.inspect(error))
      Error(Nil)
    }),
  )

  let content_type =
    filepath.extension(path)
    |> result.unwrap("")
    |> marceau.extension_to_mime_type

  let hash =
    crypto.hash(crypto.Sha224, bits)
    |> bit_array.base64_url_encode(False)

  Ok(#(content_type, hash))
}

pub fn serve_assets(
  assets: Dict(List(String), Asset),
  request request: Request,
  segments segments: List(String),
  next next: fn() -> response.Response(ewe.ResponseBody),
) -> response.Response(ewe.ResponseBody) {
  case dict.get(assets, segments) {
    Error(Nil) -> next()

    Ok(asset) ->
      case request.get_header(request, "if-none-match") {
        Ok(header) if asset.hash == header ->
          response.new(304)
          |> response.prepend_header("etag", asset.hash)
          |> response.set_body(ewe.Empty)

        Ok(_header) | Error(Nil) -> {
          case simplifile.read_bits(asset.full_path) {
            Error(_error) ->
              response.new(500)
              |> response.set_body(ewe.TextData("Internal Server Error"))

            Ok(bits) ->
              response.new(200)
              |> response.prepend_header("content-type", asset.content_type)
              |> response.prepend_header("etag", asset.hash)
              |> response.set_body(ewe.BitsData(bits))
          }
        }
      }
  }
}
