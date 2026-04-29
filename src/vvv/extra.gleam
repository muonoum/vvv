import gleam/bit_array
import gleam/crypto
import gleam/erlang/charlist.{type Charlist}
import gleam/list

pub fn return(wrap: fn(a) -> b, body: fn() -> a) -> b {
  wrap(body())
}

pub fn random_string(length: Int) -> String {
  crypto.strong_random_bytes(length)
  |> bit_array.base64_url_encode(False)
}

pub fn hash_string(string: String) -> String {
  crypto.hash(crypto.Sha256, <<string:utf8>>)
  |> bit_array.base64_url_encode(False)
}

@external(erlang, "filelib", "wildcard")
fn filelib_wildcard(pattern: Charlist, cwd: Charlist) -> List(Charlist)

pub fn wildcard(cwd: String, pattern: String) -> List(String) {
  charlist.from_string(pattern)
  |> filelib_wildcard(charlist.from_string(cwd))
  |> list.map(charlist.to_string)
}

@external(erlang, "filelib", "is_dir")
pub fn is_directory(path: String) -> Bool
