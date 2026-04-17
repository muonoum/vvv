import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/function
import gleam/json
import gleam/result

// https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow

// HACK: Entra setter ikke 'alg' på nøklene sine
pub fn update_keys(
  data: BitArray,
  algorithm alg: String,
) -> Result(BitArray, json.DecodeError) {
  let key_decoder = {
    use kid <- decode.field("kid", decode.string)
    use kty <- decode.field("kty", decode.string)
    use e <- decode.field("e", decode.string)
    use n <- decode.field("n", decode.string)

    decode.success(
      dict.from_list([
        #("kid", kid),
        #("kty", kty),
        #("alg", alg),
        #("e", e),
        #("n", n),
      ]),
    )
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
