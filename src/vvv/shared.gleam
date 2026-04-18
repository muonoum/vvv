import gleam/bit_array
import gleam/crypto

pub fn random_string(length: Int) -> String {
  crypto.strong_random_bytes(length)
  |> bit_array.base64_url_encode(False)
}

pub fn hashed_bytes(string: String) -> BitArray {
  crypto.hash(crypto.Sha256, <<string:utf8>>)
}

pub fn hashed_string(string: String) -> String {
  bit_array.base64_url_encode(hashed_bytes(string), False)
}
