import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/function
import gleam/json
import gleam/result

// https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow

// HACK: Entra setter ikke 'alg' på nøklene sine
pub fn set_rs256_algorithm(
  data: BitArray,
) -> Result(BitArray, json.DecodeError) {
  let key_decoder = {
    use key_id <- decode.field("kid", decode.string)
    use key_type <- decode.field("kty", decode.string)
    use exponent <- decode.field("e", decode.string)
    use modulus <- decode.field("n", decode.string)

    case key_type {
      "RSA" ->
        decode.success(
          dict.from_list([
            #("kid", key_id),
            #("kty", key_type),
            #("alg", "RS256"),
            #("e", exponent),
            #("n", modulus),
          ]),
        )

      _else -> decode.failure(dict.new(), expected: "kty=RSA")
    }
  }

  use key <- result.try(
    json.parse_bits(data, {
      use keys <- decode.field("keys", decode.list(key_decoder))
      decode.success(dict.from_list([#("keys", keys)]))
    }),
  )

  let encode_key = json.dict(_, function.identity, json.string)

  json.dict(key, function.identity, json.array(_, encode_key))
  |> json.to_string
  |> bit_array.from_string
  |> Ok
}
