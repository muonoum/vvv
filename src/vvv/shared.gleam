import gleam/bit_array
import gleam/crypto

pub fn random(length: Int) -> String {
  crypto.strong_random_bytes(length)
  |> bit_array.base64_url_encode(False)
}

pub fn hash(string: String) -> String {
  crypto.hash(crypto.Sha256, <<string:utf8>>)
  |> bit_array.base64_url_encode(False)
}
