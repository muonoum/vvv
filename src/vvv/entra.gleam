import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option
import gleam/result
import vvv/extra/log

// HACK: `ywt/verify_key.set_decoder` krever 'alg', men Entra setter ikke dette
// feltet på nøklene sine
pub fn set_missing_key_algorithm(data: BitArray) -> BitArray {
  try_update(data)
  |> result.try_recover(fn(error) {
    log.warning("Could not update key algorithm", [log.inspect("error", error)])
    Ok(data)
  })
  |> result.unwrap(data)
}

fn try_update(data: BitArray) -> Result(BitArray, json.DecodeError) {
  let key_decoder = {
    use key_id <- decode.field("kid", decode.string)
    use key_type <- decode.field("kty", decode.string)

    case key_type {
      "RSA" -> update_rsa_key(key_id:, key_type:)
      _else -> decode.failure([], expected: "RSA key")
    }
  }

  use key <- result.try(
    json.parse_bits(data, {
      use keys <- decode.field("keys", decode.list(key_decoder))
      decode.success([#("keys", json.array(keys, json.object))])
    }),
  )

  Ok(bit_array.from_string(json.to_string(json.object(key))))
}

fn update_rsa_key(
  key_id key_id: String,
  key_type key_type: String,
) -> decode.Decoder(List(#(String, json.Json))) {
  use exponent <- decode.field("e", decode.string)
  use modulus <- decode.field("n", decode.string)

  use algorithm <- decode.optional_field(
    "alg",
    option.None,
    decode.map(decode.string, option.Some),
  )

  let algorithm = {
    use <- option.lazy_unwrap(algorithm)

    log.warning("Setting missing 'alg' field to 'RS256'", [
      log.string("key-id", key_id),
    ])

    "RS256"
  }

  decode.success([
    #("kid", json.string(key_id)),
    #("kty", json.string(key_type)),
    #("alg", json.string(algorithm)),
    #("e", json.string(exponent)),
    #("n", json.string(modulus)),
  ])
}
