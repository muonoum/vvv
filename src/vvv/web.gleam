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
import gleam/string_tree.{type StringTree}
import gleam/uri.{type Uri}
import marceau
import simplifile
import vvv/extra
import vvv/extra/log

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

pub fn log_request(
  request: request.Request(a),
  handler: fn() -> response.Response(b),
) -> response.Response(b) {
  let #(duration, response) = extra.time(handler)

  let duration = case duration {
    n if n >= 1000 -> int.to_string(duration / 1000) <> "ms"
    _else -> int.to_string(duration) <> "µs"
  }

  log.info(http.method_to_string(request.method), [
    log.string("duration", duration),
    log.int("status", response.status),
    log.string("path", request.path),
  ])

  response
}

pub fn rescue_crashes(handler: fn() -> Response) -> Response {
  case exception.rescue(handler) {
    Ok(response) -> response

    Error(error) -> {
      log.error("Rescued", [log.inspect("error", error)])
      text_body(response.new(500), "Internal Server Error")
    }
  }
}

pub fn verify_origin(
  request: request.Request(v),
  target_origin: Uri,
  next: fn() -> Response,
) -> Response {
  let origin = case request.get_header(request, "origin") {
    Error(Nil) -> request.get_header(request, "referer")
    Ok(origin) -> Ok(origin)
  }

  case result.try(origin, uri.parse) {
    Ok(origin)
      if target_origin.host == origin.host && target_origin.port == origin.port
    -> next()

    Ok(_origin) -> text_body(response.new(400), "Bad origin")
    Error(Nil) -> text_body(response.new(400), "Missing origin")
  }
}

fn bits_body(response: response.Response(v), bits: BitArray) -> Response {
  response.set_body(response, ewe.BitsData(bits))
}

pub fn text_body(response: response.Response(v), text: String) -> Response {
  response.set_header(response, "content-type", "text/plain")
  |> response.set_body(ewe.TextData(text))
}

pub fn html_body(response: response.Response(v), html: StringTree) -> Response {
  response.set_header(response, "content-type", "text/html; charset=utf-8")
  |> response.set_body(ewe.StringTreeData(html))
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
    Error(Nil) -> text_body(response.new(400), "Bad Request")
    Ok(pairs) -> next(pairs)
  }
}

pub fn string_data(
  request: Request,
  bytes_limit bytes_limit: Int,
  next next: fn(String) -> Response,
) -> Response {
  case ewe.read_body(request, bytes_limit:) {
    Error(_) -> text_body(response.new(400), "Bad Request")

    Ok(request) ->
      case bit_array.to_string(request.body) {
        Error(Nil) -> text_body(response.new(400), "Bad Request")
        Ok(body) -> next(body)
      }
  }
}

pub fn load_assets(base: String) -> Dict(List(String), Asset) {
  dict.from_list({
    use relative_path <- list.filter_map(extra.wildcard(base, "**"))
    let full_path = filepath.join(base, relative_path)
    use <- bool.guard(extra.is_directory(full_path), Error(Nil))
    use #(content_type, hash) <- result.try(read_asset(full_path))
    let asset = Asset(relative_path:, full_path:, content_type:, hash:)
    Ok(#(uri.path_segments(relative_path), asset))
  })
}

fn read_asset(path: String) -> Result(#(String, String), Nil) {
  use bits <- result.try({
    use error <- result.try_recover(simplifile.read_bits(path))
    log.warning("Read asset", [log.inspect("error", error)])
    Error(Nil)
  })

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
  request request: request.Request(v),
  segments segments: List(String),
  next next: fn() -> Response,
) -> Response {
  case dict.get(assets, segments) {
    Error(Nil) -> next()

    Ok(asset) ->
      case request.get_header(request, "if-none-match") {
        Ok(header) if asset.hash == header ->
          response.new(304)
          |> response.prepend_header("etag", asset.hash)
          |> empty_body

        Ok(_header) | Error(Nil) -> {
          case simplifile.read_bits(asset.full_path) {
            Error(error) -> {
              log.error("", [log.inspect("error", error)])
              text_body(response.new(500), "Internal Server Error")
            }

            Ok(bits) ->
              response.new(200)
              |> response.prepend_header("content-type", asset.content_type)
              |> response.prepend_header("etag", asset.hash)
              |> bits_body(bits)
          }
        }
      }
  }
}
